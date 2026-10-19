import AVFoundation
import CoreGraphics
import Foundation

public enum VideoActions {
    static func fileType(forExt ext: String) -> AVFileType? {
        switch ext.lowercased() {
        case "mov", "qt": return .mov
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "3gp": return .mobile3GPP
        default: return nil
        }
    }

    static let x264 = ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]

    // MARK: Convert

    /// target: mp4, mov, m4v, hevc, prores, mkv, webm, avi, gif
    public static func convert(_ item: InputItem, to target: String, ctx: JobContext) async throws {
        let native = await Media.isNativelyReadable(item.url)
        switch target {
        case "gif":
            if ctx.settings.hasFFmpeg {
                let vf = "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=sierra2_4a"
                try await FFmpeg.convert(item, ext: "gif", args: ["-t", "60", "-vf", vf, "-loop", "0"], ctx: ctx)
            } else {
                try await nativeGIF(item, ctx: ctx)
            }
        case "mkv":
            try await FFmpeg.convert(item, ext: "mkv", args: ["-map", "0:v", "-map", "0:a?", "-c", "copy"], ctx: ctx)
        case "webm":
            try await FFmpeg.convert(item, ext: "webm", args: ["-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-deadline", "good",
                                                               "-cpu-used", "5", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"], ctx: ctx)
        case "avi":
            try await FFmpeg.convert(item, ext: "avi", args: ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"], ctx: ctx)
        case "hevc":
            if native {
                try await exportPreset(item, preset: AVAssetExportPresetHEVCHighestQuality, ext: "mp4", suffix: "HEVC", ctx: ctx)
            } else {
                try await FFmpeg.convert(item, ext: "mp4", args: ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1",
                                                                  "-c:a", "aac", "-b:a", "192k"], suffix: "HEVC", ctx: ctx)
            }
        case "prores":
            if native {
                try await exportPreset(item, preset: AVAssetExportPresetAppleProRes422LPCM, ext: "mov", suffix: "ProRes", ctx: ctx)
            } else {
                try await FFmpeg.convert(item, ext: "mov", args: ["-c:v", "prores_videotoolbox", "-profile:v", "standard",
                                                                  "-c:a", "pcm_s16le"], suffix: "ProRes", ctx: ctx)
            }
        default: // mp4, mov, m4v
            guard let type = fileType(forExt: target) else { throw TangeloError.unsupported("Unknown video format.") }
            if native {
                let asset = AVURLAsset(url: item.url)
                let passthrough = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                                           with: asset, outputFileType: type)
                try await exportPreset(item, preset: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality,
                                       ext: target, ctx: ctx)
            } else {
                try await FFmpeg.convert(item, ext: target, args: x264 + (target == "mov" ? [] : ["-movflags", "+faststart"]), ctx: ctx)
            }
        }
    }

    static func exportPreset(_ item: InputItem, preset: String, ext: String, suffix: String? = nil,
                             timeRange: CMTimeRange? = nil, asset: AVAsset? = nil, ctx: JobContext,
                             configure: ((AVAssetExportSession) -> Void)? = nil) async throws {
        let asset = asset ?? AVURLAsset(url: item.url)
        guard let type = fileType(forExt: ext) ?? (ext == "m4a" ? .m4a : nil),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw TangeloError.unsupported("This video can't be exported that way.")
        }
        if let timeRange { session.timeRange = timeRange }
        session.shouldOptimizeForNetworkUse = true
        configure?(session)
        let dest = ctx.destination(for: item.url, ext: ext, suffix: suffix ?? (item.url.pathExtension.lowercased() == ext ? "Converted" : nil))
        try await ctx.produce(dest) { tmp in try await Media.export(session, to: tmp, as: type, ctx: ctx) }
    }

    static func nativeGIF(_ item: InputItem, ctx: JobContext) async throws {
        let asset = AVURLAsset(url: item.url)
        let duration = min(try await asset.load(.duration).seconds, 60)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let tol = CMTime(value: 1, timescale: 24)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let fps = 12.0
        let count = max(1, Int(duration * fps))
        var frames: [CGImage] = []
        for i in 0..<count {
            try ctx.check()
            ctx.report(Double(i) / Double(count) * 0.9)
            if let img = try? await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600)).image { frames.append(img) }
        }
        guard !frames.isEmpty else { throw TangeloError.failed("Couldn't read video frames.") }
        try await ctx.produce(ctx.destination(for: item.url, ext: "gif")) { tmp in
            try ImageKit.writeGIF(frames: frames, delay: 1 / fps, to: tmp)
        }
    }

    // MARK: Tools

    public static func trim(_ item: InputItem, range: CMTimeRange, ctx: JobContext) async throws {
        let ext = item.url.pathExtension.lowercased()
        if await Media.isNativelyReadable(item.url), fileType(forExt: ext) != nil {
            try await exportPreset(item, preset: AVAssetExportPresetPassthrough, ext: ext, suffix: "Trimmed",
                                   timeRange: range, ctx: ctx)
        } else {
            try await ffmpegTrim(item, start: range.start.seconds, duration: range.duration.seconds, video: true, ctx: ctx)
        }
    }

    /// Fast keyframe-aligned stream copy; re-encodes when the copy comes out empty (sparse keyframes).
    static func ffmpegTrim(_ item: InputItem, start: Double, duration: Double, video: Bool, ctx: JobContext) async throws {
        let ext = item.url.pathExtension.isEmpty ? (video ? "mp4" : "m4a") : item.url.pathExtension.lowercased()
        let dest = ctx.destination(for: item.url, ext: ext, suffix: "Trimmed")
        let head = ["-ss", String(format: "%.3f", start), "-i", item.url.path, "-t", String(format: "%.3f", duration)]
        try await ctx.produce(dest) { tmp in
            try await FFmpeg.run(head + ["-map", "0:v?", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero", tmp.path],
                                 input: item.url, ctx: ctx)
            if (await FFmpeg.probeDuration(tmp, ctx: ctx) ?? 0) > 0 { return }
            try? FileManager.default.removeItem(at: tmp)
            let codecs: [String]
            switch ext {
            case "webm": codecs = ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus"]
            case "avi": codecs = ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame"]
            case "mp3", "opus", "ogg", "flac", "wav", "m4a", "aac", "wma", "ac3": codecs = []
            default: codecs = x264
            }
            try await FFmpeg.run(head + codecs + [tmp.path], input: item.url, ctx: ctx)
        }
    }

    static func videoTrackInfo(_ asset: AVAsset) async throws -> (AVAssetTrack, CGSize, CGAffineTransform) {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TangeloError.failed("This file has no video track.")
        }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        return (track, size, transform)
    }

    static func orientedSize(_ size: CGSize, _ t: CGAffineTransform) -> CGSize {
        let r = CGRect(origin: .zero, size: size).applying(t)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    public static func mute(_ item: InputItem, ctx: JobContext) async throws {
        guard await Media.isNativelyReadable(item.url), let _ = fileType(forExt: item.url.pathExtension) else {
            try await FFmpeg.convert(item, ext: item.url.pathExtension, args: ["-an", "-c:v", "copy"], suffix: "Muted", ctx: ctx)
            return
        }
        let asset = AVURLAsset(url: item.url)
        let (track, _, transform) = try await videoTrackInfo(asset)
        let comp = AVMutableComposition()
        let duration = try await asset.load(.duration)
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TangeloError.failed("Couldn't prepare the video.")
        }
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        v.preferredTransform = transform
        try await exportPreset(item, preset: AVAssetExportPresetPassthrough, ext: item.url.pathExtension.lowercased(),
                               suffix: "Muted", asset: comp, ctx: ctx)
    }

    /// Rotates clockwise by quarter turns without re-encoding (metadata transform).
    public static func rotate(_ item: InputItem, quarterTurns: Int, ctx: JobContext) async throws {
        let q = ((quarterTurns % 4) + 4) % 4
        guard await Media.isNativelyReadable(item.url), fileType(forExt: item.url.pathExtension) != nil else {
            let vf = ["", "transpose=1", "transpose=1,transpose=1", "transpose=2"][q]
            let ext = item.format == "mkv" ? "mkv" : "mp4"
            try await FFmpeg.convert(item, ext: ext, args: ["-vf", vf] + x264, suffix: "Rotated", ctx: ctx)
            return
        }
        let asset = AVURLAsset(url: item.url)
        let (track, size, transform) = try await videoTrackInfo(asset)
        let o = orientedSize(size, transform)
        let r: CGAffineTransform
        switch q {
        case 1: r = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: o.height, ty: 0)
        case 2: r = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: o.width, ty: o.height)
        case 3: r = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: o.width)
        default: r = .identity
        }
        let comp = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TangeloError.failed("Couldn't prepare the video.")
        }
        try v.insertTimeRange(range, of: track, at: .zero)
        v.preferredTransform = transform.concatenating(r)
        for a in try await asset.loadTracks(withMediaType: .audio) {
            let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try ca?.insertTimeRange(range, of: a, at: .zero)
        }
        try await exportPreset(item, preset: AVAssetExportPresetPassthrough, ext: item.url.pathExtension.lowercased(),
                               suffix: "Rotated", asset: comp, ctx: ctx)
    }

    /// Scales so the shorter side is `shortSide` pixels (720, 1080...).
    public static func resize(_ item: InputItem, shortSide: Int, ctx: JobContext) async throws {
        if ctx.settings.hasFFmpeg {
            let s = shortSide
            let vf = "scale='if(gt(iw,ih),-2,\(s))':'if(gt(iw,ih),\(s),-2)':flags=lanczos"
            try await FFmpeg.convert(item, ext: "mp4", args: ["-vf", vf, "-c:v", "h264_videotoolbox", "-q:v", "62",
                                                              "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"],
                                     suffix: "\(s)p", ctx: ctx)
            return
        }
        let preset: String
        switch shortSide {
        case ..<500: preset = AVAssetExportPreset640x480
        case ..<600: preset = AVAssetExportPreset960x540
        case ..<800: preset = AVAssetExportPreset1280x720
        case ..<1200: preset = AVAssetExportPreset1920x1080
        default: preset = AVAssetExportPreset3840x2160
        }
        try await exportPreset(item, preset: preset, ext: "mp4", suffix: "\(shortSide)p", ctx: ctx)
    }

    public static func compress(_ item: InputItem, level: CompressLevel, ctx: JobContext) async throws {
        let duration = await Media.duration(of: item.url, ctx: ctx) ?? 0
        let size = item.size > 0 ? item.size : ByteFormat.size(of: item.url)
        if ctx.settings.hasFFmpeg && duration > 0 {
            // Target bitrate from resolution, never above a fraction of the source bitrate.
            var w = 1920.0, h = 1080.0, fps = 30.0
            let asset = AVURLAsset(url: item.url)
            if let (track, natural, t) = try? await videoTrackInfo(asset) {
                let o = orientedSize(natural, t); w = o.width; h = o.height
                fps = Double((try? await track.load(.nominalFrameRate)) ?? 30)
                if fps <= 0 { fps = 30 }
            }
            let maxShort: Double = level == .strong ? 720 : 1080
            let short = min(w, h)
            let scale = short > maxShort ? maxShort / short : 1
            let bpp: Double = level == .light ? 0.09 : (level == .balanced ? 0.055 : 0.035)
            let sourceVideoBitrate = max(Double(size) * 8 / duration - 160_000, 200_000)
            let factor: Double = level == .light ? 0.7 : (level == .balanced ? 0.45 : 0.3)
            let target = Int(min(w * scale * h * scale * min(fps, 60) * bpp, sourceVideoBitrate * factor))
            var args = ["-c:v", "hevc_videotoolbox", "-b:v", "\(target)", "-tag:v", "hvc1",
                        "-c:a", "aac", "-b:a", level == .strong ? "96k" : "128k", "-movflags", "+faststart"]
            if scale < 1 {
                let s = Int(maxShort)
                args = ["-vf", "scale='if(gt(iw,ih),-2,\(s))':'if(gt(iw,ih),\(s),-2)':flags=lanczos"] + args
            }
            let dest = ctx.destination(for: item.url, ext: "mp4", suffix: "Compressed")
            let out = try await ctx.produce(dest) { tmp in
                try await FFmpeg.run(["-i", item.url.path] + args + [tmp.path], input: item.url, ctx: ctx)
            }
            try ImageActions.reportSavings(original: item, output: out, ctx: ctx)
            return
        }
        let preset = level == .light ? AVAssetExportPresetHEVCHighestQuality
            : (level == .balanced ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPreset1280x720)
        let dest = ctx.destination(for: item.url, ext: "mp4", suffix: "Compressed")
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: item.url), presetName: preset) else {
            throw TangeloError.unsupported("This video can't be compressed.")
        }
        session.shouldOptimizeForNetworkUse = true
        let out = try await ctx.produce(dest) { tmp in try await Media.export(session, to: tmp, as: .mp4, ctx: ctx) }
        try ImageActions.reportSavings(original: item, output: out, ctx: ctx)
    }

    public static func snapshot(_ item: InputItem, at seconds: Double? = nil, ctx: JobContext) async throws {
        let duration = await Media.duration(of: item.url, ctx: ctx) ?? 0
        let t = seconds ?? (duration > 2 ? duration / 2 : 0)
        let dest = ctx.destination(for: item.url, ext: "png", suffix: "Frame")
        if await Media.isNativelyReadable(item.url) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            let img = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            try await ctx.produce(dest) { tmp in
                try ImageKit.write(img, to: tmp, format: .png, quality: 1, settings: ctx.settings)
            }
        } else {
            try await ctx.produce(dest) { tmp in
                try await FFmpeg.run(["-ss", String(t), "-i", item.url.path, "-frames:v", "1", tmp.path], ctx: ctx)
            }
        }
    }

    static func speedLabel(_ factor: Double) -> String {
        factor >= 1 ? "\(formatFactor(factor))× Speed" : "\(formatFactor(factor))× Slow"
    }

    /// ffmpeg's atempo filter only takes 0.5…2, so larger changes are chained.
    static func atempo(_ factor: Double) -> String {
        var filters: [String] = []
        var f = factor
        while f > 2 { filters.append("atempo=2.0"); f /= 2 }
        while f < 0.5 { filters.append("atempo=0.5"); f /= 0.5 }
        filters.append(String(format: "atempo=%.4f", f))
        return filters.joined(separator: ",")
    }

    public static func speed(_ item: InputItem, factor: Double, ctx: JobContext) async throws {
        let label = speedLabel(factor)
        // ffmpeg is the robust path (AVFoundation can stall on very short time-scaled clips).
        if ctx.settings.hasFFmpeg {
            let hasAudio = await Media.hasAudioStream(item.url, ctx: ctx)
            let pts = String(format: "%.6f", 1 / factor)
            let graph = hasAudio ? "[0:v]setpts=\(pts)*PTS[v];[0:a]\(atempo(factor))[a]" : "[0:v]setpts=\(pts)*PTS[v]"
            var args = ["-filter_complex", graph, "-map", "[v]"]
            if hasAudio { args += ["-map", "[a]"] }
            let ext = item.format == "mov" ? "mov" : "mp4"
            args += ["-c:v", "h264_videotoolbox", "-q:v", "65", "-c:a", "aac", "-b:a", "192k"] + (ext == "mp4" ? ["-movflags", "+faststart"] : [])
            try await FFmpeg.convert(item, ext: ext, args: args, suffix: label, ctx: ctx)
            return
        }
        guard await Media.isNativelyReadable(item.url) else { throw TangeloError.missingTool("ffmpeg") }
        let asset = AVURLAsset(url: item.url)
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let comp = AVMutableComposition()
        if let (track, _, transform) = try? await videoTrackInfo(asset),
           let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try v.insertTimeRange(range, of: track, at: .zero)
            v.preferredTransform = transform
        }
        for a in try await asset.loadTracks(withMediaType: .audio) {
            try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(range, of: a, at: .zero)
        }
        comp.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor))
        let hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        try await exportPreset(item, preset: hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A,
                               ext: hasVideo ? "mp4" : "m4a", suffix: label, asset: comp, ctx: ctx) { s in
            s.audioTimePitchAlgorithm = .spectral
        }
    }

    static func formatFactor(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%g", d)
    }

    /// Joins clips one after another, scaling each to fit the first clip's frame.
    public static func merge(_ items: [InputItem], ctx: JobContext) async throws {
        guard let first = items.first else { return }
        for item in items where !(await Media.isNativelyReadable(item.url)) {
            throw TangeloError.unsupported("\(item.url.lastPathComponent) can't be merged. Convert it to MP4 first.")
        }
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TangeloError.failed("Couldn't prepare the merge.")
        }
        var renderSize = CGSize.zero
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var anyAudio = false
        for item in items {
            try ctx.check()
            let asset = AVURLAsset(url: item.url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            let (track, natural, transform) = try await videoTrackInfo(asset)
            let oriented = orientedSize(natural, transform)
            if renderSize == .zero { renderSize = CGSize(width: (oriented.width / 2).rounded() * 2, height: (oriented.height / 2).rounded() * 2) }
            try vTrack.insertTimeRange(range, of: track, at: cursor)
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                try aTrack.insertTimeRange(range, of: a, at: cursor)
                anyAudio = true
            }
            let s = min(renderSize.width / oriented.width, renderSize.height / oriented.height)
            let fit = transform
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: (renderSize.width - oriented.width * s) / 2,
                                                 y: (renderSize.height - oriented.height * s) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
            layer.setTransform(fit, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + duration
        }
        if !anyAudio { comp.removeTrack(aTrack) }
        let video = AVMutableVideoComposition()
        video.renderSize = renderSize
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = instructions
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw TangeloError.failed("Couldn't prepare the merge.")
        }
        session.videoComposition = video
        session.shouldOptimizeForNetworkUse = true
        let dest = ctx.destination(named: first.baseName + " Merged", ext: "mp4", near: first.url)
        try await ctx.produce(dest) { tmp in try await Media.export(session, to: tmp, as: .mp4, ctx: ctx) }
    }
}
