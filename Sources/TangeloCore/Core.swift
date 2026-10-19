import Foundation
import UniformTypeIdentifiers

// MARK: - Files

public enum FileKind: String, Sendable, Codable {
    case image, pdf, video, audio, document, data, archive, folder, other
}

/// A file (or folder) the user dropped on the ring.
public struct InputItem: Sendable, Hashable {
    public let url: URL
    public let type: UTType
    public let kind: FileKind
    /// Canonical lowercase format key, e.g. "jpg", "mp4", "docx".
    public let format: String
    public let size: Int64

    public init(url: URL) {
        let rv = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey, .isPackageKey])
        let isFolder = (rv?.isDirectory ?? false) && !(rv?.isPackage ?? false)
        let type = rv?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        self.init(url: url, type: type, size: Int64(rv?.fileSize ?? 0), isFolder: isFolder)
    }

    public init(url: URL, type: UTType, size: Int64 = 0, isFolder: Bool = false) {
        self.url = url
        self.type = type
        self.size = size
        let format = Classifier.formatKey(ext: url.pathExtension, type: type)
        self.format = format
        self.kind = Classifier.classify(type: type, format: format, isFolder: isFolder)
    }

    public var baseName: String { url.deletingPathExtension().lastPathComponent }
}

public enum Classifier {
    static let aliases: [String: String] = [
        "jpeg": "jpg", "jpe": "jpg", "jfif": "jpg", "tif": "tiff", "htm": "html", "xhtml": "html",
        "aif": "aiff", "aifc": "aiff", "markdown": "md", "mdown": "md", "mkd": "md",
        "heif": "heic", "hif": "heic", "jpf": "jp2", "j2k": "jp2", "jpx": "jp2", "m4b": "m4a",
        "oga": "ogg", "text": "txt", "mpeg": "mpg", "qt": "mov", "tgz": "tgz",
    ]

    public static func formatKey(ext: String, type: UTType) -> String {
        let e = ext.lowercased()
        if let a = aliases[e] { return a }
        if !e.isEmpty { return e }
        if let pe = type.preferredFilenameExtension?.lowercased() { return aliases[pe] ?? pe }
        return "bin"
    }

    static let dataFormats: Set<String> = ["csv", "tsv", "json", "xlsx"]
    static let docFormats: Set<String> = ["txt", "rtf", "rtfd", "html", "docx", "doc", "odt", "md", "webarchive"]
    static let audioFormats: Set<String> = ["mp3", "m4a", "wav", "aiff", "flac", "ogg", "opus", "caf", "aac", "wma", "amr", "ac3", "m4r"]
    static let videoFormats: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "wmv", "mpg", "3gp", "mts", "m2ts", "ogv"]
    static let archiveFormats: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar"]

    public static func classify(type: UTType, format: String, isFolder: Bool) -> FileKind {
        if isFolder { return .folder }
        if format == "pdf" || type.conforms(to: .pdf) { return .pdf }
        if dataFormats.contains(format) { return .data }
        if docFormats.contains(format) { return .document }
        if format == "svg" || type.conforms(to: .image) { return .image }
        if audioFormats.contains(format) || type.conforms(to: .audio) { return .audio }
        if videoFormats.contains(format) || type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if archiveFormats.contains(format) || type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .plainText) || type.conforms(to: .rtf) || type.conforms(to: .html) { return .document }
        return .other
    }
}

// MARK: - Errors

public enum TangeloError: LocalizedError, Sendable {
    case unsupported(String)
    case failed(String)
    case missingTool(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .failed(let s): return s
        case .missingTool(let t): return "This needs \(t). Install it with Homebrew: brew install \(t)"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Settings

public enum CompressLevel: String, Sendable, CaseIterable, Codable {
    case light, balanced, strong
    public var title: String { rawValue.capitalized }
}

public struct EngineSettings: Sendable {
    /// Lossy image quality, 0...1.
    public var quality: Double = 0.85
    /// Resolution used when rendering PDF pages to images.
    public var pdfDPI: Double = 200
    public var keepLocation: Bool = true
    /// nil = save next to the original file.
    public var outputFolder: URL? = nil
    public var ffmpegPath: String? = ExternalTools.find("ffmpeg")
    public var cwebpPath: String? = ExternalTools.find("cwebp")

    public init() {}

    public var hasFFmpeg: Bool { ffmpegPath != nil }
}

public enum ExternalTools {
    public static func find(_ name: String) -> String? {
        var candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map(String.init)
        }
        for dir in candidates {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

// MARK: - Job context

/// Carries settings, progress, cancellation and produced outputs for one run of an action.
public final class JobContext: @unchecked Sendable {
    public let settings: EngineSettings
    private let lock = NSLock()
    private var _cancelled = false
    private var cancelHandlers: [@Sendable () -> Void] = []
    private var _outputs: [URL] = []
    private var _summary: String?
    public var progressHandler: (@Sendable (Double?, String?) -> Void)?

    public init(settings: EngineSettings = EngineSettings()) {
        self.settings = settings
    }

    public var isCancelled: Bool { lock.withLock { _cancelled } }

    public func cancel() {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            _cancelled = true
            defer { cancelHandlers = [] }
            return cancelHandlers
        }
        handlers.forEach { $0() }
    }

    /// Registers work to stop when the job is cancelled (runs immediately if already cancelled).
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if _cancelled { return true }
            cancelHandlers.append(handler)
            return false
        }
        if runNow { handler() }
    }

    public func check() throws {
        if isCancelled { throw TangeloError.cancelled }
    }

    public func report(_ fraction: Double?, _ detail: String? = nil) {
        progressHandler?(fraction.map { min(max($0, 0), 1) }, detail)
    }

    public var outputs: [URL] { lock.withLock { _outputs } }
    public var summary: String? {
        get { lock.withLock { _summary } }
        set { lock.withLock { _summary = newValue } }
    }

    public func add(output: URL) { lock.withLock { _outputs.append(output) } }
    public func remove(output: URL) { lock.withLock { _outputs.removeAll { $0 == output } } }

    // MARK: Output naming

    public func outputDirectory(for input: URL) -> URL {
        if let folder = settings.outputFolder { return folder }
        let dir = input.deletingLastPathComponent()
        if !Naming.isTemporary(dir) && FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// "Photo.heic" + "jpg" -> "Photo.jpg"; with a suffix -> "Photo Cropped.jpg". Never overwrites.
    public func destination(for input: URL, ext: String, suffix: String? = nil) -> URL {
        var name = input.deletingPathExtension().lastPathComponent
        if let suffix, !suffix.isEmpty { name += " " + suffix }
        return Naming.unique(in: outputDirectory(for: input), base: name, ext: ext)
    }

    public func destination(named base: String, ext: String, near input: URL) -> URL {
        Naming.unique(in: outputDirectory(for: input), base: base, ext: ext)
    }

    /// Runs `body` against a temporary file next to `dest`, then moves it into place.
    /// Partial files never appear in the user's folder.
    @discardableResult
    public func produce(_ dest: URL, _ body: (URL) async throws -> Void) async throws -> URL {
        let fm = FileManager.default
        let tmpDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                appropriateFor: dest.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: tmpDir) }
        let tmp = tmpDir.appendingPathComponent(dest.lastPathComponent)
        try await body(tmp)
        try check()
        guard fm.fileExists(atPath: tmp.path) else { throw TangeloError.failed("No output was produced.") }
        var final = dest
        if fm.fileExists(atPath: final.path) {
            final = Naming.unique(in: dest.deletingLastPathComponent(),
                                  base: dest.deletingPathExtension().lastPathComponent,
                                  ext: dest.pathExtension)
        }
        try fm.moveItem(at: tmp, to: final)
        Naming.release(dest)
        add(output: final)
        return final
    }

    /// Creates a fresh, uniquely named output folder (e.g. "Report (JPG)").
    public func makeFolder(near input: URL, name: String) throws -> URL {
        let url = Naming.unique(in: outputDirectory(for: input), base: name, ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Naming.release(url)
        add(output: url)
        return url
    }
}

public enum Naming {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reserved = Set<String>()

    /// Finder-style unique name: "Name.ext", "Name 2.ext", "Name 3.ext"...
    /// Names handed out are reserved until released, so parallel jobs never collide.
    public static func unique(in dir: URL, base: String, ext: String) -> URL {
        lock.withLock {
            let fm = FileManager.default
            var n = 1
            while true {
                let name = n == 1 ? base : "\(base) \(n)"
                let url = ext.isEmpty ? dir.appendingPathComponent(name, isDirectory: true)
                                      : dir.appendingPathComponent(name).appendingPathExtension(ext)
                if !fm.fileExists(atPath: url.path) && !reserved.contains(url.path) {
                    reserved.insert(url.path)
                    return url
                }
                n += 1
            }
        }
    }

    public static func release(_ url: URL) {
        _ = lock.withLock { reserved.remove(url.path) }
    }

    public static func isTemporary(_ dir: URL) -> Bool {
        let p = dir.resolvingSymlinksInPath().path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return p.hasPrefix(tmp) || p.contains("/TemporaryItems/")
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    public static func savings(from before: Int64, to after: Int64) -> String {
        guard before > 0 else { return string(after) }
        let pct = Int(((1 - Double(after) / Double(before)) * 100).rounded())
        return "\(string(before)) → \(string(after))" + (pct > 0 ? " (−\(pct)%)" : "")
    }
}
