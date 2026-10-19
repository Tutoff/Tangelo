import AVFoundation
import Foundation

public enum AudioActions {
    /// Targets Core Audio can encode on every Mac.
    static let nativeTargets: Set<String> = ["m4a", "alac", "wav", "aiff", "caf", "flac", "aac", "m4r"]
    /// Targets that need ffmpeg (ffmpeg codec arguments).
    static let ffmpegTargets: [String: [String]] = [
        "mp3": ["-c:a", "libmp3lame", "-q:a", "2"],
        "opus": ["-c:a", "libopus", "-b:a", "128k"],
        "ogg": ["-c:a", "libopus", "-b:a", "128k"],
        "ac3": ["-c:a", "ac3", "-b:a", "384k"],
        "wma": ["-c:a", "wmav2", "-b:a", "192k"],
    ]

    static func settings(for target: String, bitrate: Int = 256_000, bitDepth: Int = 16) -> [String: Any] {
        switch target {
        case "m4a", "aac", "m4r":
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: bitrate]
        case "alac":
            return [AVFormatIDKey: kAudioFormatAppleLossless, AVEncoderBitDepthHintKey: bitDepth]
        case "flac":
            return [AVFormatIDKey: kAudioFormatFLAC, AVEncoderBitDepthHintKey: bitDepth]
        case "aiff":
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: bitDepth, AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsNonInterleaved: false]
        default: // wav, caf
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: bitDepth, AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        }
    }

    static func fileExt(for target: String) -> String { target == "alac" ? "m4a" : target }

    /// A URL AVAudioFile can read: the file itself, or a temporary decoded copy (video/MKV/OGG sources).
    static func readableAudio(_ item: InputItem, ctx: JobContext) async throws -> (URL, () -> Void) {
        if (try? AVAudioFile(forReading: item.url)) != nil { return (item.url, {}) }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("tangelo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let cleanup = { try? FileManager.default.removeItem(at: tmpDir); return () }
        do {
            if await Media.isNativelyReadable(item.url), await Media.hasAudio(item.url),
               let session = AVAssetExportSession(asset: AVURLAsset(url: item.url), presetName: AVAssetExportPresetAppleM4A) {
                let tmp = tmpDir.appendingPathComponent("audio.m4a")
                try await Media.export(session, to: tmp, as: .m4a, ctx: ctx)
                return (tmp, cleanup)
            }
            if ctx.settings.hasFFmpeg {
                let tmp = tmpDir.appendingPathComponent("audio.flac")
                try await FFmpeg.run(["-i", item.url.path, "-vn", "-c:a", "flac", tmp.path], input: item.url, ctx: ctx)
                return (tmp, cleanup)
            }
        } catch {
            cleanup()
            throw error
        }
        cleanup()
        if !(await Media.hasAudio(item.url)) && !ctx.settings.hasFFmpeg {
            throw TangeloError.failed("\(item.url.lastPathComponent) has no audio track.")
        }
        throw TangeloError.missingTool("ffmpeg")
    }

    // MARK: Convert

    public static func convert(_ item: InputItem, to target: String, ctx: JobContext) async throws {
        if item.kind == .video, !(await Media.hasAudioStream(item.url, ctx: ctx)) {
            throw TangeloError.failed("\(item.url.lastPathComponent) has no audio track.")
        }
        if let args = ffmpegTargets[target] {
            try await FFmpeg.convert(item, ext: target, args: ["-vn"] + args, ctx: ctx)
            return
        }
        guard nativeTargets.contains(target) else { throw TangeloError.unsupported("Unknown audio format.") }
        let (src, cleanup) = try await readableAudio(item, ctx: ctx)
        defer { cleanup() }
        let ext = fileExt(for: target)
        var suffix: String? = nil
        if item.url.pathExtension.lowercased() == ext { suffix = target == "alac" ? "Lossless" : "Converted" }
        let depth = sourceBitDepth(src)
        let dest = ctx.destination(for: item.url, ext: ext, suffix: suffix)
        try await ctx.produce(dest) { tmp in
            if target == "m4r" {
                let m4a = tmp.deletingPathExtension().appendingPathExtension("m4a")
                try encode(from: src, to: m4a, settings: settings(for: "m4a"), range: (0, 40), ctx: ctx)
                try FileManager.default.moveItem(at: m4a, to: tmp)
            } else {
                try encode(from: src, to: tmp, settings: settings(for: target, bitDepth: depth), ctx: ctx)
            }
        }
    }

    static func sourceBitDepth(_ url: URL) -> Int {
        guard let f = try? AVAudioFile(forReading: url) else { return 16 }
        let bits = f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 16
        return bits >= 24 ? 24 : 16
    }

    /// The source's own format, when Core Audio can write it.
    static func sameFormatTarget(_ item: InputItem) -> String? {
        switch item.format {
        case "wav", "aiff", "caf", "flac", "aac": return item.format
        case "m4a":
            if let f = try? AVAudioFile(forReading: item.url),
               (f.fileFormat.settings[AVFormatIDKey] as? UInt32) == kAudioFormatAppleLossless { return "alac" }
            return "m4a"
        default: return nil
        }
    }

    // MARK: Core encoder

    /// Streams `src` into a new file, optionally trimming, applying gain, downmixing or reversing.
    static func encode(from src: URL, to dst: URL, settings base: [String: Any], range: (Double, Double)? = nil,
                       gain: Float = 1, mono: Bool = false, reverse: Bool = false, ctx: JobContext) throws {
        let input = try AVAudioFile(forReading: src)
        let inFormat = input.processingFormat
        var sampleRate = inFormat.sampleRate
        var channels = inFormat.channelCount
        let formatID = base[AVFormatIDKey] as? UInt32 ?? kAudioFormatLinearPCM
        if formatID == kAudioFormatMPEG4AAC {
            sampleRate = min(sampleRate, 48_000)
            channels = min(channels, 2)
        }
        if mono { channels = 1 }
        var settings = base
        settings[AVSampleRateKey] = sampleRate
        settings[AVNumberOfChannelsKey] = channels
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: dst, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw TangeloError.failed("Couldn't create the audio file: \(error.localizedDescription)")
        }
        let outFormat = output.processingFormat

        let sr = inFormat.sampleRate
        let start = AVAudioFramePosition(max(0, (range?.0 ?? 0) * sr))
        var end = input.length
        if let r = range { end = min(end, AVAudioFramePosition(r.1 * sr)) }
        guard end > start else { throw TangeloError.failed("Nothing to export in that range.") }
        let total = Double(end - start)

        var converter: AVAudioConverter? = nil
        if outFormat.sampleRate != inFormat.sampleRate || outFormat.channelCount != inFormat.channelCount {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converter?.downmix = true
        }

        func write(_ buf: AVAudioPCMBuffer, last: Bool) throws {
            if gain != 1, let data = buf.floatChannelData {
                for c in 0..<Int(buf.format.channelCount) {
                    let p = data[c]
                    for i in 0..<Int(buf.frameLength) { p[i] = max(-1, min(1, p[i] * gain)) }
                }
            }
            guard let converter else { try output.write(from: buf); return }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 4096
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = last ? .endOfStream : .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return buf
            }
            if status == .error { throw TangeloError.failed(error?.localizedDescription ?? "Audio conversion failed.") }
            if out.frameLength > 0 { try output.write(from: out) }
        }

        if reverse {
            let frames = AVAudioFrameCount(end - start)
            guard Double(frames) / sr < 60 * 45 else { throw TangeloError.failed("Reverse works on clips up to 45 minutes.") }
            guard let all = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { throw TangeloError.failed("Out of memory.") }
            input.framePosition = start
            try input.read(into: all, frameCount: frames)
            if let data = all.floatChannelData {
                for c in 0..<Int(inFormat.channelCount) {
                    let p = data[c]
                    var i = 0, j = Int(all.frameLength) - 1
                    while i < j { let t = p[i]; p[i] = p[j]; p[j] = t; i += 1; j -= 1 }
                }
            }
            try write(all, last: true)
            return
        }

        let chunk: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { throw TangeloError.failed("Out of memory.") }
        input.framePosition = start
        while input.framePosition < end {
            try ctx.check()
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), end - input.framePosition))
            try input.read(into: buf, frameCount: n)
            if buf.frameLength == 0 { break }
            let last = input.framePosition >= end
            try write(buf, last: last)
            ctx.report(Double(input.framePosition - start) / total)
        }
    }

    /// Runs `body` writing in the source's format (or M4A when the source format can't be written natively).
    static func process(_ item: InputItem, suffix: String, ctx: JobContext,
                        ffmpegArgs: [String]?,
                        body: @escaping (URL, URL, [String: Any]) throws -> Void) async throws {
        if sameFormatTarget(item) == nil, let ffmpegArgs, ctx.settings.hasFFmpeg, ffmpegTargets[item.format] != nil {
            try await FFmpeg.convert(item, ext: item.format, args: ["-vn"] + ffmpegArgs + ffmpegTargets[item.format]!, suffix: suffix, ctx: ctx)
            return
        }
        let target = sameFormatTarget(item) ?? "m4a"
        let (src, cleanup) = try await readableAudio(item, ctx: ctx)
        defer { cleanup() }
        let dest = ctx.destination(for: item.url, ext: fileExt(for: target), suffix: suffix)
        let s = settings(for: target, bitDepth: sourceBitDepth(src))
        try await ctx.produce(dest) { tmp in try body(src, tmp, s) }
    }

    // MARK: Tools

    public static func trim(_ item: InputItem, start: Double, end: Double, ctx: JobContext) async throws {
        if item.kind == .video {
            try await VideoActions.trim(item, range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                                 end: CMTime(seconds: end, preferredTimescale: 600)), ctx: ctx)
            return
        }
        if sameFormatTarget(item) == nil, ctx.settings.hasFFmpeg {
            try await VideoActions.ffmpegTrim(item, start: start, duration: end - start, video: false, ctx: ctx)
            return
        }
        try await process(item, suffix: "Trimmed", ctx: ctx, ffmpegArgs: nil) { src, dst, s in
            try encode(from: src, to: dst, settings: s, range: (start, end), ctx: ctx)
        }
    }

    public static func normalize(_ item: InputItem, ctx: JobContext) async throws {
        try await process(item, suffix: "Normalized", ctx: ctx, ffmpegArgs: ["-af", "loudnorm=I=-14:TP=-1:LRA=11"]) { src, dst, s in
            let peak = try peakLevel(src, ctx: ctx)
            guard peak > 0.0001 else { throw TangeloError.failed("This audio is silent.") }
            let gain = Float(0.891) / peak // -1 dBFS
            try encode(from: src, to: dst, settings: s, gain: gain, ctx: ctx)
        }
    }

    static func peakLevel(_ url: URL, ctx: JobContext) throws -> Float {
        let f = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65_536) else { return 0 }
        var peak: Float = 0
        while f.framePosition < f.length {
            try ctx.check()
            try f.read(into: buf)
            if buf.frameLength == 0 { break }
            guard let data = buf.floatChannelData else { break }
            for c in 0..<Int(buf.format.channelCount) {
                let p = data[c]
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(p[i])) }
            }
        }
        return peak
    }

    public static func mono(_ item: InputItem, ctx: JobContext) async throws {
        try await process(item, suffix: "Mono", ctx: ctx, ffmpegArgs: ["-ac", "1"]) { src, dst, s in
            try encode(from: src, to: dst, settings: s, mono: true, ctx: ctx)
        }
    }

    public static func reverse(_ item: InputItem, ctx: JobContext) async throws {
        try await process(item, suffix: "Reversed", ctx: ctx, ffmpegArgs: ["-af", "areverse"]) { src, dst, s in
            try encode(from: src, to: dst, settings: s, reverse: true, ctx: ctx)
        }
    }

    public static func compress(_ item: InputItem, level: CompressLevel, ctx: JobContext) async throws {
        let dest: URL
        let out: URL
        if item.format == "mp3", ctx.settings.hasFFmpeg {
            let q = level == .light ? "4" : (level == .balanced ? "6" : "8")
            dest = ctx.destination(for: item.url, ext: "mp3", suffix: "Compressed")
            out = try await ctx.produce(dest) { tmp in
                try await FFmpeg.run(["-i", item.url.path, "-vn", "-c:a", "libmp3lame", "-q:a", q, tmp.path], input: item.url, ctx: ctx)
            }
        } else {
            let bitrate = level == .light ? 160_000 : (level == .balanced ? 112_000 : 64_000)
            let (src, cleanup) = try await readableAudio(item, ctx: ctx)
            defer { cleanup() }
            dest = ctx.destination(for: item.url, ext: "m4a", suffix: "Compressed")
            out = try await ctx.produce(dest) { tmp in
                try encode(from: src, to: tmp, settings: settings(for: "m4a", bitrate: bitrate), mono: level == .strong, ctx: ctx)
            }
        }
        try ImageActions.reportSavings(original: item, output: out, ctx: ctx)
    }

    /// ffmpeg codec arguments that keep an audio file in its own format.
    static func ffmpegSameFormat(_ item: InputItem) -> (ext: String, codec: [String]) {
        switch item.format {
        case "wav": return ("wav", ["-c:a", "pcm_s16le"])
        case "aiff": return ("aiff", ["-c:a", "pcm_s16be"])
        case "caf": return ("caf", ["-c:a", "pcm_s16le"])
        case "flac": return ("flac", ["-c:a", "flac"])
        case "m4a", "aac", "m4r": return (item.format, ["-c:a", "aac", "-b:a", "256k"])
        default:
            if let codec = ffmpegTargets[item.format] { return (item.format, codec) }
            return ("m4a", ["-c:a", "aac", "-b:a", "256k"])
        }
    }

    public static func speed(_ item: InputItem, factor: Double, ctx: JobContext) async throws {
        if ctx.settings.hasFFmpeg {
            let (ext, codec) = ffmpegSameFormat(item)
            try await FFmpeg.convert(item, ext: ext, args: ["-vn", "-af", VideoActions.atempo(factor)] + codec,
                                     suffix: VideoActions.speedLabel(factor), ctx: ctx)
            return
        }
        guard await Media.isNativelyReadable(item.url) else { throw TangeloError.missingTool("ffmpeg") }
        try await VideoActions.speed(item, factor: factor, ctx: ctx)
    }

    public static func merge(_ items: [InputItem], ctx: JobContext) async throws {
        guard let first = items.first else { return }
        var allNative = true
        for item in items where !(await Media.isNativelyReadable(item.url)) { allNative = false }
        let dest = ctx.destination(named: first.baseName + " Merged", ext: "m4a", near: first.url)
        if allNative {
            let comp = AVMutableComposition()
            guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TangeloError.failed("Couldn't prepare the merge.")
            }
            var cursor = CMTime.zero
            for item in items {
                let asset = AVURLAsset(url: item.url)
                let duration = try await asset.load(.duration)
                if let a = try await asset.loadTracks(withMediaType: .audio).first {
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: a, at: cursor)
                }
                cursor = cursor + duration
            }
            guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
                throw TangeloError.failed("Couldn't prepare the merge.")
            }
            try await ctx.produce(dest) { tmp in try await Media.export(session, to: tmp, as: .m4a, ctx: ctx) }
            return
        }
        var args: [String] = []
        for item in items { args += ["-i", item.url.path] }
        let inputs = (0..<items.count).map { "[\($0):a]" }.joined()
        args += ["-filter_complex", "\(inputs)concat=n=\(items.count):v=0:a=1[out]", "-map", "[out]", "-c:a", "aac", "-b:a", "256k"]
        try await ctx.produce(dest) { tmp in try await FFmpeg.run(args + [tmp.path], ctx: ctx) }
    }
}
