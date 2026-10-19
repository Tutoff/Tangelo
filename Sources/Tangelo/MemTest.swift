import AppKit
import TangeloCore

/// Drives the real app objects through a typical session and prints the memory footprint after each phase.
/// Tangelo --mem-test <folder with sample files>
@MainActor
enum MemTest {
    static func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    static func run(fixtures: URL) -> Int32 {
        UserDefaults.standard.set(true, forKey: "welcomed")
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("tangelo-mem-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Inputs live in a temp folder, which would send results to ~/Downloads: keep them in the test folder.
        let settings = AppSettings.shared
        let savedUseFolder = settings.useCustomFolder, savedFolder = settings.customFolder
        let outputs = work.appendingPathComponent("outputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        settings.customFolder = outputs
        settings.useCustomFolder = true
        defer {
            settings.useCustomFolder = savedUseFolder
            settings.customFolder = savedFolder
        }
        let point = NSPoint(x: NSScreen.main?.frame.midX ?? 700, y: NSScreen.main?.frame.midY ?? 450)
        var rows: [(String, Double)] = []

        func mark(_ phase: String) {
            spin(2.0) // let the post-job memory relief run
            let mb = MemoryRelief.footprintMB()
            rows.append((phase, mb))
            let heap = MemoryRelief.mallocMB()
            print(String(format: "%-44@ %7.1f MB   (heap in use %.1f / reserved %.1f)", phase as NSString, mb, heap.inUse, heap.allocated))
        }
        func copy(_ name: String) -> InputItem? {
            let src = fixtures.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { return nil }
            let dir = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: src, to: dst)
            return InputItem(url: dst)
        }
        func job(_ id: String, _ names: [String]) { autoreleasepool { jobInPool(id, names) } }
        func jobInPool(_ id: String, _ names: [String]) {
            let items = names.compactMap(copy)
            guard !items.isEmpty, let action = Catalog.find(id, in: Catalog.pages(for: items)) else { print("  (skipped \(id))"); return }
            JobRunner.shared.run(action, source: .files(items), near: point)
            let deadline = Date().addingTimeInterval(180)
            while JobRunner.shared.activeJobs > 0 && Date() < deadline { spin(0.1) }
        }

        mark("launched, idle")

        let pb = NSPasteboard(name: NSPasteboard.Name("tangelo.memtest"))
        pb.clearContents()
        pb.writeObjects([fixtures.appendingPathComponent("photo.jpg") as NSURL])
        for i in 0..<20 { autoreleasepool {
            delegate.ring.showForDrag(at: point)
            let drag = MockDrag(pasteboard: pb, location: Ring.center)
            _ = delegate.ring.dragEntered(drag)
            drag.location = NSPoint(x: Ring.center.x + 100 * cos(Double(i)), y: Ring.center.y + 100 * sin(Double(i)))
            _ = delegate.ring.dragUpdated(drag)
            spin(0.15)
            delegate.ring.hide(animated: false)
        } }
        mark("ring shown 20×")

        job("image.to.heic", ["photo.jpg"])
        job("image.to.webp", ["photo.jpg"])
        job("image.compress.balanced", ["screenshot.png"])
        job("image.rotate.1", ["photo.heic"])
        job("image.to.tiff", ["photo.jpg", "photo.heic", "screenshot.png", "oriented.jpg"])
        mark("after 8 image conversions")

        job("image.ocr.txt", ["screenshot.png"])
        job("image.removebg", ["photo.jpg"])
        mark("after text recognition + remove background")

        job("pdf.to.png", ["report.pdf"])
        job("pdf.compress.balanced", ["report.pdf"])
        job("pdf.ocr", ["scan.pdf"])
        mark("after PDF jobs")

        job("video.to.hevc", ["clip.mp4"])
        job("video.compress.balanced", ["clip.mp4"])
        job("audio.to.mp3", ["tone.wav"])
        job("audio.normalize", ["tone.wav"])
        mark("after video + audio jobs")

        job("doc.to.pdf", ["notes.md"])
        job("data.to.xlsx", ["people.csv"])
        mark("after document + data jobs")

        let tools: [ToolKind] = [.crop, .addBackground, .annotate, .redact, .edit, .metadata, .resize]
        for round in 1...2 {
            for t in tools { autoreleasepool {
                guard let item = copy(t == .metadata ? "photo.jpg" : "screenshot.png") else { return }
                ToolPresenter.shared.present(t, item: item)
                spin(1.2)
                NSApp.windows.filter { $0.title.contains("—") }.forEach { $0.close() }
                spin(0.3)
            } }
            mark(round == 1 ? "after opening/closing 7 tool windows" : "…the same 7 windows again")
        }

        autoreleasepool {
            delegate.showWelcome()
            spin(1.0)
            NSApp.windows.filter { $0.title == "Welcome to Tangelo" }.forEach { $0.close() }
            delegate.showSettings()
            spin(0.8)
            NSApp.windows.filter { $0.title == "Tangelo Settings" }.forEach { $0.close() }
        }
        mark("after welcome + settings windows")

        spin(8)
        mark("idle again (10 s later)")
        print("windows still alive: \(NSApp.windows.count) → \(NSApp.windows.map { "\(type(of: $0)) '\($0.title)' visible=\($0.isVisible)" })")
        if ProcessInfo.processInfo.environment["TANGELO_MEM_HOLD"] != nil { print("holding for inspection…"); spin(25) }

        try? FileManager.default.removeItem(at: work)
        let peak = rows.map(\.1).max() ?? 0
        print(String(format: "\npeak between phases %.1f MB, final idle %.1f MB", peak, rows.last?.1 ?? 0))
        return 0
    }
}

/// Tangelo --leak-test <fixtures>: opens and closes each window type and checks it is really freed.
@MainActor
enum LeakTest {
    static func run(fixtures: URL) -> Int32 {
        func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let shot = InputItem(url: fixtures.appendingPathComponent("screenshot.png"))
        let photo = InputItem(url: fixtures.appendingPathComponent("photo.jpg"))
        var leaks = 0
        for tool in [ToolKind.resize, .crop, .addBackground, .annotate, .redact, .edit, .metadata] {
            let before = MemoryRelief.footprintMB()
            weak var window: NSWindow?
            weak var controller: NSViewController?
            autoreleasepool {
                ToolPresenter.shared.present(tool, item: tool == .metadata ? photo : shot)
                spin(1.2)
                window = NSApp.windows.first { $0.title.contains("—") && $0.isVisible }
                controller = window?.contentViewController
                window?.close()
            }
            spin(1.5)
            malloc_zone_pressure_relief(nil, 0)
            let after = MemoryRelief.footprintMB()
            let alive = window != nil, cAlive = controller != nil
            if alive || cAlive { leaks += 1 }
            print(String(format: "%-14@ window freed: %@  content freed: %@  memory %+.1f MB", "\(tool)" as NSString,
                         alive ? "NO" : "yes", cAlive ? "NO" : "yes", after - before))
        }
        // Repeat opens: a real leak keeps climbing, caches level off.
        for tool in [ToolKind.resize, .addBackground, .crop, .edit, .annotate, .redact] {
            var line = "\(tool) heap after each open:"
            for _ in 0..<6 {
                autoreleasepool {
                    ToolPresenter.shared.present(tool, item: shot)
                    spin(0.8)
                    NSApp.windows.filter { $0.title.contains("—") }.forEach { $0.close() }
                }
                spin(0.6)
                line += String(format: " %.1f", MemoryRelief.mallocMB().inUse)
            }
            print(line)
        }
        // HUD panel lifecycle
        weak var hudPanel: NSPanel?
        autoreleasepool {
            let model = HUDModel(title: "Test", subtitle: "…")
            let hud = HUDManager.shared.present(model, near: NSPoint(x: 500, y: 500))
            hudPanel = hud.panel
            hud.finish(phase: .done, title: "Saved", subtitle: "x", outputs: [])
            hud.dismiss()
        }
        spin(1.5)
        print("HUD panel freed: \(hudPanel == nil ? "yes" : "NO")")
        if hudPanel != nil { leaks += 1 }
        print(leaks == 0 ? "No leaked windows." : "\(leaks) leaked window(s).")
        return leaks == 0 ? 0 : 1
    }
}
