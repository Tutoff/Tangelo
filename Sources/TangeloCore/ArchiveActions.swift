import Foundation

public enum ArchiveActions {
    /// Zips one item like Finder's "Compress", or several into "Archive.zip".
    public static func zip(_ items: [InputItem], ctx: JobContext) async throws {
        guard let first = items.first else { return }
        if items.count == 1 {
            let dest = ctx.destination(named: first.url.lastPathComponent, ext: "zip", near: first.url)
            try await ctx.produce(dest) { tmp in
                try await ProcessRunner.checked("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.url.path, tmp.path], ctx: ctx)
            }
            return
        }
        let staging = try stage(items)
        defer { try? FileManager.default.removeItem(at: staging) }
        let names = try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
        let dest = ctx.destination(named: "Archive", ext: "zip", near: first.url)
        try await ctx.produce(dest) { tmp in
            try await ProcessRunner.checked("/usr/bin/zip", ["-q", "-r", "-X", tmp.path] + names + ["-x", "*.DS_Store"],
                                            currentDirectory: staging, ctx: ctx)
        }
    }

    public static func tarGz(_ items: [InputItem], ctx: JobContext) async throws {
        guard let first = items.first else { return }
        let staging = try stage(items)
        defer { try? FileManager.default.removeItem(at: staging) }
        let names = try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
        let base = items.count == 1 ? first.url.lastPathComponent : "Archive"
        let dest = ctx.destination(named: base, ext: "tar.gz", near: first.url)
        try await ctx.produce(dest) { tmp in
            // -h follows the staging symlinks so real files are archived.
            try await ProcessRunner.checked("/usr/bin/tar", ["-czhf", tmp.path, "--exclude", ".DS_Store"] + names,
                                            currentDirectory: staging, ctx: ctx)
        }
    }

    /// Symlinks every item into one temporary folder (unique names) so tools can archive them together.
    static func stage(_ items: [InputItem]) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("tangelo-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var used = Set<String>()
        for item in items {
            var name = item.url.lastPathComponent
            var n = 2
            while used.contains(name) {
                name = "\(item.url.deletingPathExtension().lastPathComponent) \(n)" + (item.url.pathExtension.isEmpty ? "" : ".\(item.url.pathExtension)")
                n += 1
            }
            used.insert(name)
            try fm.createSymbolicLink(at: staging.appendingPathComponent(name), withDestinationURL: item.url)
        }
        return staging
    }

    /// Extracts next to the archive. A single top-level folder is not wrapped in another folder.
    public static func extract(_ item: InputItem, ctx: JobContext) async throws {
        let fm = FileManager.default
        let outDir = ctx.outputDirectory(for: item.url)
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: outDir, create: true)
        defer { try? fm.removeItem(at: work) }
        if item.format == "zip" {
            try await ProcessRunner.checked("/usr/bin/ditto", ["-x", "-k", item.url.path, work.path], ctx: ctx)
        } else {
            try await ProcessRunner.checked("/usr/bin/tar", ["-xf", item.url.path, "-C", work.path], ctx: ctx)
        }
        let contents = try fm.contentsOfDirectory(atPath: work.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        guard !contents.isEmpty else { throw TangeloError.failed("The archive is empty.") }
        var base = item.url.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        if contents.count == 1 {
            let only = work.appendingPathComponent(contents[0])
            let ext = only.pathExtension
            let dest = Naming.unique(in: outDir, base: only.deletingPathExtension().lastPathComponent, ext: ext)
            try fm.moveItem(at: only, to: dest)
            Naming.release(dest)
            ctx.add(output: dest)
        } else {
            let dest = Naming.unique(in: outDir, base: base, ext: "")
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for name in contents { try fm.moveItem(at: work.appendingPathComponent(name), to: dest.appendingPathComponent(name)) }
            Naming.release(dest)
            ctx.add(output: dest)
        }
    }
}
