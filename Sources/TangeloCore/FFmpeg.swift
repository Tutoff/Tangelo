import AVFoundation
import Foundation

/// Optional ffmpeg backend for formats Apple's frameworks can't write (MP3, WebM, MKV, Opus...)
/// or read (MKV, WebM, AVI, FLV, WMV...).
public enum FFmpeg {
    public static func run(_ args: [String], input: URL? = nil, ctx: JobContext) async throws {
        guard let ffmpeg = ctx.settings.ffmpegPath else { throw TangeloError.missingTool("ffmpeg") }
        let duration: Double? = input == nil ? nil : await Media.duration(of: input!, ctx: ctx)
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + args
        try await ProcessRunner.checked(ffmpeg, full, ctx: ctx) { line in
            guard let d = duration, d > 0 else { return }
            if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                if let us = Double(line.split(separator: "=").last ?? "") { ctx.report(us / 1_000_000 / d) }
            }
        }
    }

    /// Converts `item` to `ext` with the given codec arguments, writing next to the original.
    public static func convert(_ item: InputItem, ext: String, args: [String], suffix: String? = nil, ctx: JobContext) async throws {
        let dest = ctx.destination(for: item.url, ext: ext, suffix: suffix)
        try await ctx.produce(dest) { tmp in
            try await run(["-i", item.url.path] + args + [tmp.path], input: item.url, ctx: ctx)
        }
    }

    public static func probeDuration(_ url: URL, ctx: JobContext) async -> Double? {
        guard let ffmpeg = ctx.settings.ffmpegPath else { return nil }
        let ffprobe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        guard FileManager.default.isExecutableFile(atPath: ffprobe),
              let r = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]),
              r.status == 0 else { return nil }
        return Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum Media {
    /// Duration in seconds via AVFoundation, falling back to ffprobe.
    public static func duration(of url: URL, ctx: JobContext? = nil) async -> Double? {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0 { return d.seconds }
        if let ctx { return await FFmpeg.probeDuration(url, ctx: ctx) }
        return nil
    }

    /// True when AVFoundation can decode the file (otherwise we need ffmpeg).
    public static func isNativelyReadable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let readable = try? await asset.load(.isReadable), readable else { return false }
        let tracks = (try? await asset.load(.tracks)) ?? []
        for t in tracks {
            if let fmts = try? await t.load(.formatDescriptions), !fmts.isEmpty,
               let playable = try? await t.load(.isPlayable), playable { return true }
        }
        return false
    }

    public static func hasVideo(_ url: URL) async -> Bool {
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    /// Audio-track check that also works for files only ffmpeg can read.
    public static func hasAudioStream(_ url: URL, ctx: JobContext) async -> Bool {
        if await isNativelyReadable(url) { return await hasAudio(url) }
        guard let ffmpeg = ctx.settings.ffmpegPath else { return true }
        let ffprobe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        guard FileManager.default.isExecutableFile(atPath: ffprobe),
              let r = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                                                             "-of", "csv=p=0", url.path]) else { return true }
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func hasAudio(_ url: URL) async -> Bool {
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)) ?? []
        return !tracks.isEmpty
    }

    /// Runs an export session with progress and Task-based cancellation.
    /// Runs an export with a watchdog: AVFoundation occasionally never finishes (e.g. very short
    /// time-scaled clips), so an export whose progress stops moving is cancelled instead of hanging.
    public static func export(_ session: AVAssetExportSession, to url: URL, as type: AVFileType, ctx: JobContext,
                              stallTimeout: TimeInterval = 30) async throws {
        let watch = ExportWatch()
        let progress = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state {
                    ctx.report(p.fractionCompleted)
                    watch.saw(p.fractionCompleted)
                }
            }
        }
        defer { progress.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let exportTask = Task {
                do {
                    try await session.export(to: url, as: type)
                    watch.finish { cont.resume() }
                } catch {
                    let mapped: Error = (Task.isCancelled || ctx.isCancelled) ? TangeloError.cancelled
                        : TangeloError.failed("Export failed: \(error.localizedDescription)")
                    watch.finish { cont.resume(throwing: mapped) }
                }
            }
            Task {
                while !watch.isFinished {
                    try? await Task.sleep(for: .milliseconds(250))
                    let reason: Error? = ctx.isCancelled ? TangeloError.cancelled
                        : (watch.secondsSinceProgress > stallTimeout ? ExportStalled() : nil)
                    if let reason {
                        session.cancelExport()
                        exportTask.cancel()
                        watch.finish { cont.resume(throwing: reason) }
                    }
                }
            }
        }
    }
}

/// Thrown when AVFoundation stops making progress; callers may fall back to ffmpeg.
public struct ExportStalled: LocalizedError {
    public var errorDescription: String? { "macOS stopped responding while exporting this file." }
}

private final class ExportWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1
    private var lastChange = Date()
    private var done = false

    func saw(_ fraction: Double) {
        lock.withLock {
            if fraction > last + 0.0001 { last = fraction; lastChange = Date() }
        }
    }

    var secondsSinceProgress: TimeInterval { lock.withLock { Date().timeIntervalSince(lastChange) } }
    var isFinished: Bool { lock.withLock { done } }

    /// Runs `resume` exactly once, whichever side (export or watchdog) gets there first.
    func finish(_ resume: () -> Void) {
        let first: Bool = lock.withLock {
            if done { return false }
            done = true
            return true
        }
        if first { resume() }
    }
}
