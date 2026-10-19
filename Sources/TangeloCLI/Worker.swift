import Darwin
import Foundation
import TangeloCore

/// `tangelo-cli job`: runs one quick action for the menu-bar app in a short-lived process.
///
/// A conversion pulls in frameworks (ImageIO codecs, Vision models, AVFoundation encoders, PDFKit) that keep
/// tens of megabytes resident once loaded. Doing the work here and exiting hands all of it back, so the
/// always-running app stays small. The app side lives in Sources/Tangelo/JobRunner.swift (`JobWorker`).
///
/// Request: one JSON object on stdin
///     {"action": "image.to.webp", "files": ["/abs/path", ...],
///      "settings": {"quality": 0.85, "pdfDPI": 200, "keepLocation": true, "outputFolder": null}}
/// `settings` and each of its keys are optional; "ffmpegPath" / "cwebpPath" override tool discovery.
///
/// Reply: one JSON object per line on stdout
///     {"progress": 0.42, "detail": "2 of 5 saved"}        zero or more, as work proceeds (either key may be absent)
///     {"result": {"outputs": [...], "summary": ..., "clipboard": ..., "failures": [{"name": ..., "message": ...}]}}
///  or {"error": "message", "cancelled": false}             exactly one final line
/// Exit status 0 after a result, 1 after an error. SIGTERM or SIGINT cancels the job, as does the parent process
/// going away; the reply is then {"error": "Cancelled", "cancelled": true}. Only the protocol reaches stdout:
/// fd 1 is pointed at stderr for the life of the job, so stray prints and child tools can't corrupt it.
/// The tools a job runs (ffmpeg, zip...) stay in this process's group (see ProcessRunner), so if it dies without a
/// chance to stop them, the app does.
enum Worker {
    static func run() async -> Int32 {
        // Taken before anything slow, so a parent that quits meanwhile is noticed (see Stopper).
        let parent = getppid()
        let reply = ReplyStream()
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let request: JobRequest
        do {
            request = try JSONDecoder().decode(JobRequest.self, from: input)
        } catch {
            reply.finish(error: "Invalid job request: \(describe(error))", cancelled: false)
            return 1
        }
        guard !request.files.isEmpty else {
            reply.finish(error: "Invalid job request: no files.", cancelled: false)
            return 1
        }

        var settings = EngineSettings()
        if let s = request.settings {
            if let v = s.quality { settings.quality = v }
            if let v = s.pdfDPI { settings.pdfDPI = v }
            if let v = s.keepLocation { settings.keepLocation = v }
            if let v = s.outputFolder { settings.outputFolder = URL(fileURLWithPath: v, isDirectory: true) }
            if let v = s.ffmpegPath { settings.ffmpegPath = v }
            if let v = s.cwebpPath { settings.cwebpPath = v }
        }
        let ctx = JobContext(settings: settings)
        ctx.progressHandler = { fraction, detail in reply.progress(fraction, detail) }
        let stopper = Stopper(ctx: ctx, reply: reply, parent: parent)
        defer { withExtendedLifetime(stopper) {} }

        let items = request.files.map { InputItem(url: URL(fileURLWithPath: $0)) }
        do {
            let result = try await Runner.run(request.action, items: items, ctx: ctx)
            reply.finish(result: result)
            return 0
        } catch {
            var cancelled = ctx.isCancelled
            if case TangeloError.cancelled = error { cancelled = true }
            reply.finish(error: cancelled ? TangeloError.cancelled.localizedDescription : error.localizedDescription,
                         cancelled: cancelled)
            return 1
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        switch e {
        case .keyNotFound(let key, _):
            return "missing \"\(key.stringValue)\"."
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            let path = c.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

// MARK: - Protocol messages

private struct JobRequest: Decodable {
    struct Settings: Decodable {
        var quality: Double?
        var pdfDPI: Double?
        var keepLocation: Bool?
        var outputFolder: String?
        var ffmpegPath: String?
        var cwebpPath: String?
    }
    var action: String
    var files: [String]
    var settings: Settings?
}

private struct ProgressLine: Encodable {
    var progress: Double?
    var detail: String?
}

private struct ErrorLine: Encodable {
    var error: String
    var cancelled: Bool
}

private struct ResultLine: Encodable {
    struct Failure: Encodable {
        var name: String
        var message: String
    }
    struct Body: Encodable {
        var outputs: [String]
        var summary: String?
        var clipboard: String?
        var failures: [Failure]

        enum CodingKeys: String, CodingKey { case outputs, summary, clipboard, failures }
        // Spelled out so an absent summary or clipboard is written as null rather than left out.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(outputs, forKey: .outputs)
            try c.encode(summary, forKey: .summary)
            try c.encode(clipboard, forKey: .clipboard)
            try c.encode(failures, forKey: .failures)
        }
    }
    var result: Body
}

// MARK: - Reply stream

/// The protocol's stdout. It keeps the real stdout for itself and points fd 1 at stderr. Lines are written whole
/// under a lock, progress is thinned to visible changes, and nothing follows the final line.
private final class ReplyStream: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private var closed = false
    private var lastFraction: Double?
    private var lastDetail: String?

    init() {
        fflush(stdout)
        signal(SIGPIPE, SIG_IGN) // a vanished reader must surface as a failed write, not kill the job mid-file
        let copy = dup(STDOUT_FILENO)
        if copy >= 0 {
            _ = fcntl(copy, F_SETFD, FD_CLOEXEC) // child tools (ffmpeg, zip...) must not hold the reply pipe open
            _ = dup2(STDERR_FILENO, STDOUT_FILENO)
            fd = copy
        } else {
            fd = STDOUT_FILENO
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func progress(_ fraction: Double?, _ detail: String?) {
        let f = fraction.flatMap { $0.isFinite ? (min(max($0, 0), 1) * 10_000).rounded() / 10_000 : nil }
        lock.withLock {
            guard !closed else { return }
            let newDetail = detail == lastDetail ? nil : detail
            var moved = false
            if let f { moved = lastFraction.map { abs(f - $0) >= 0.01 || (f == 1) != ($0 == 1) } ?? true }
            guard moved || newDetail != nil else { return }
            if moved { lastFraction = f }
            if let newDetail { lastDetail = newDetail }
            send(ProgressLine(progress: moved ? f : nil, detail: newDetail))
        }
    }

    func finish(result r: RunResult) {
        finish(ResultLine(result: .init(outputs: r.outputs.map(\.path), summary: r.summary, clipboard: r.clipboardText,
                                        failures: r.failures.map { .init(name: $0.name, message: $0.message) })))
    }

    func finish(error message: String, cancelled: Bool) {
        finish(ErrorLine(error: message, cancelled: cancelled))
    }

    private func finish<Line: Encodable>(_ line: Line) {
        lock.withLock {
            guard !closed else { return }
            send(line)
            closed = true
        }
    }

    /// Lock held.
    private func send<Line: Encodable>(_ line: Line) {
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        let ok = data.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return true }
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, base + offset, buf.count - offset)
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
        if !ok { closed = true } // reader gone: nothing more can be delivered
    }
}

// MARK: - Cancellation

/// Cancels the job on SIGTERM / SIGINT or when the parent process exits. Cancellation is cooperative; if the job
/// hasn't wound down a few seconds later, the cancellation is reported anyway and the process exits.
private final class Stopper {
    private var sources: [DispatchSourceProtocol] = []

    init(ctx: JobContext, reply: ReplyStream, parent: pid_t) {
        let stop: @Sendable () -> Void = {
            ctx.cancel()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                reply.finish(error: TangeloError.cancelled.localizedDescription, cancelled: true)
                _exit(1)
            }
        }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN) // delivered through the dispatch source instead of killing the process
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler(handler: stop)
            source.resume()
            sources.append(source)
        }
        let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        watch.setEventHandler(handler: stop)
        watch.resume()
        sources.append(watch)
        // The parent may have exited before the watch existed (an exited pid never fires), even before this process
        // got as far as `run` (it is then reparented to launchd, pid 1, which never launches jobs itself). Without
        // this the job would run to the end for nobody.
        if parent == 1 || getppid() != parent { stop() }
    }
}
