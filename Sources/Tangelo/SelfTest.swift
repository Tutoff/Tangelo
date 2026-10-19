import AppKit
import TangeloCore

/// A scripted drag session used to test the ring without real mouse events.
final class MockDrag: NSObject, NSDraggingInfo {
    var location: NSPoint
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard, location: NSPoint) {
        self.pasteboard = pasteboard
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .move] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 42 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// Drives one ring the way a user does: Shift-drag in, hover, dwell, tap Shift, drop, or click and press keys.
@MainActor
final class RingDriver {
    let ring: RadialMenuController
    let files: [URL]
    let pasteboard: NSPasteboard
    let drag: MockDrag
    let screenPoint: NSPoint
    /// What the ring handed to the app (`onRun`) since the last `open()` / `openClick()`. onRun is dispatched
    /// asynchronously, so reading this first lets queued main-thread work run (only checks pay for that pass).
    var runs: [(action: Action, source: DropSource)] {
        SelfTest.flush()
        return log
    }
    private var log: [(action: Action, source: DropSource)] = []

    init(ring: RadialMenuController, files: [URL]) {
        self.ring = ring
        self.files = files
        pasteboard = NSPasteboard(name: NSPasteboard.Name("tangelo.selftest.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { $0 as NSURL })
        drag = MockDrag(pasteboard: pasteboard, location: Ring.center)
        // Open the ring away from the real pointer: click mode tracks real mouse moves over the panel.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let mouse = NSEvent.mouseLocation
        screenPoint = NSPoint(x: mouse.x < screen.midX ? screen.maxX - Ring.size.width : screen.minX + Ring.size.width,
                              y: mouse.y < screen.midY ? screen.maxY - Ring.size.height : screen.minY + Ring.size.height)
        ring.trigger = .shift
        ring.onRun = { [weak self] action, source, _ in self?.log.append((action, source)) }
    }

    func finish() {
        ring.hide(animated: false)
        ring.onRun = nil
        pasteboard.releaseGlobally()
    }

    /// Shift + drag: the ring opens under the cursor and the drag enters it at the center.
    @discardableResult func open() -> NSDragOperation {
        log.removeAll()
        ring.showForDrag(at: screenPoint)
        drag.location = Ring.center
        return ring.dragEntered(drag)
    }

    @discardableResult func move(_ p: NSPoint) -> NSDragOperation {
        drag.location = p
        return ring.dragUpdated(drag)
    }

    /// Lets go of the mouse where the drag is, in AppKit's order: prepare → perform → ended.
    @discardableResult func release() -> (prepared: Bool, performed: Bool) {
        let prepared = ring.prepareDrop(drag)
        let performed = prepared && ring.performDrop(drag)
        ring.dragEnded()
        return (prepared, performed)
    }

    /// Releases and presses the trigger key again (what the drag monitor reports on each poll).
    func tapTrigger() {
        ring.modifiersChanged([])
        ring.modifiersChanged(ring.trigger)
    }

    /// Flips pages with trigger taps (instant, no dwell).
    func goToPage(_ p: Int) {
        for _ in 0..<ring.pages.count where ring.pageIndex != p { tapTrigger() }
    }

    /// "Convert Files…" from the menu bar: the ring opens for clicking.
    func openClick() {
        log.removeAll()
        ring.showForClick(items: files.map { InputItem(url: $0) }, at: screenPoint)
    }

    func click(_ p: NSPoint) {
        ring.mouseClicked(at: p)
    }

    func clickPage(_ p: Int) {
        if ring.pageIndex != p, ring.tabFrames.indices.contains(p) { click(tabPoint(p)) }
    }

    func key(_ code: UInt16) {
        let chars: String
        switch code {
        case 53: chars = "\u{1b}"
        case 48: chars = "\t"
        case 123: chars = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        case 124: chars = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        default: chars = ""
        }
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        ring.keyDown(e)
    }

    func wedgePoint(_ i: Int) -> NSPoint { SelfTest.wedgePoint(ring, i) }
    func tabPoint(_ t: Int) -> NSPoint { NSPoint(x: ring.tabFrames[t].midX, y: ring.tabFrames[t].midY) }
}

/// Tangelo --self-test <fixtures folder>  every scenario × page × wedge × group, drag and click mode
/// Tangelo --self-test file…              the quick scripted drag, then the same sweep for those files
@MainActor
enum SelfTest {
    static var failures = 0
    static var passed = 0
    /// Inside `section`, passing checks are only counted; failures always print.
    static var quiet = false
    /// Ring behaviors that don't depend on the files (timing paths) run once per process, in the first scenario that can.
    static var covered: Set<String> = []
    static func once(_ key: String) -> Bool { covered.insert(key).inserted }

    // The ring's dwell times: group wedge → sub-ring, center → back, tab → page.
    static let groupDwell: TimeInterval = 0.45
    static let centerDwell: TimeInterval = 0.55
    static let tabDwell: TimeInterval = 0.12

    static func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else { failures += 1 }
        if !ok { print("FAIL \(what())") } else if !quiet { print("ok   \(what())") }
    }

    /// Runs a group of checks and prints one line for it.
    static func section(_ title: String, _ body: () -> Void) {
        let (p0, f0, wasQuiet, t0) = (passed, failures, quiet, CACurrentMediaTime())
        quiet = true
        autoreleasepool { body() }
        quiet = wasQuiet
        let p = passed - p0, f = failures - f0
        let time = String(format: "%.1f s", CACurrentMediaTime() - t0)
        print(f == 0 ? "ok   \(title) — \(p) checks, \(time)" : "FAIL \(title) — \(f) of \(p + f) checks failed, \(time)")
    }

    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Lets everything already queued on the main thread run (onRun is dispatched asynchronously). Polls the run
    /// loop without sleeping, so it doesn't wait for a frame; `spin` and `wait` let the ring render.
    static func flush() {
        var drained = false
        DispatchQueue.main.async { drained = true }
        let deadline = Date().addingTimeInterval(2)
        while !drained && Date() < deadline { _ = CFRunLoopRunInMode(.defaultMode, 0, true) }
    }

    /// Spins until `condition` holds or `timeout` passes.
    @discardableResult
    static func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { spin(0.004) }
        return condition()
    }

    // MARK: Geometry and expectations

    static var rMid: CGFloat { (Ring.inner + Ring.outer) / 2 }

    static func wedgePoint(_ ring: RadialMenuController, _ index: Int) -> NSPoint {
        point(angle: ring.layout.wedges[index].midAngle, radius: rMid)
    }

    static func point(angle: CGFloat, radius: CGFloat) -> NSPoint {
        NSPoint(x: Ring.center.x + cos(angle) * radius, y: Ring.center.y + sin(angle) * radius)
    }

    /// The wedges (of `count`, clockwise from the top) whose slice holds `angle`: two when it lies on a boundary.
    static func wedgesAt(angle: CGFloat, count: Int) -> [Int] {
        let span = 2 * CGFloat.pi / CGFloat(count)
        return (0..<count).filter { angleDistance(angle, .pi / 2 - CGFloat($0) * span) <= span / 2 + 0.0005 }
    }

    static func hoveredIndex(_ ring: RadialMenuController) -> Int? {
        if case .entry(let i) = ring.hover { return i }
        return nil
    }

    static func angleDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs((a - b).truncatingRemainder(dividingBy: 2 * .pi))
        return min(d, 2 * .pi - d)
    }

    /// The action a drop on this wedge runs (a group runs its primary action).
    static func entryID(_ e: MenuEntry) -> String {
        switch e {
        case .action(let a): return a.id
        case .group(_, _, _, let primary): return primary.id
        }
    }

    /// What the center pill reads while the wedge is hovered.
    static func entryText(_ e: MenuEntry) -> String {
        if case .group = e { return e.title + " ›" }
        return e.title
    }

    /// The center pill when nothing is hovered.
    static func infoText(_ items: [InputItem]) -> String {
        if items.count == 1 {
            if items[0].kind == .folder { return "1 FOLDER" }
            return items[0].size > 0 ? ByteFormat.string(items[0].size).uppercased() : "1 FILE"
        }
        if items.allSatisfy({ $0.kind == .folder }) { return "\(items.count) FOLDERS" }
        return items.contains { $0.kind == .folder } ? "\(items.count) ITEMS" : "\(items.count) FILES"
    }

    static func standardPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func droppedPaths(_ source: DropSource) -> [String] {
        switch source {
        case .files(let items), .promises(_, let items): return items.map { standardPath($0.url) }
        }
    }

    /// The SwiftUI glass ring shows exactly what the controller decided.
    static func modelInSync(_ ring: RadialMenuController) -> Bool {
        guard ring.usesGlass else { return true }
        let m = ring.model
        var hovered: Int?
        var tab: Int?
        if case .entry(let i) = ring.hover { hovered = i }
        if case .tab(let t) = ring.hover { tab = t }
        return m.wedges.count == ring.layout.entries.count
            && m.wedges.map(\.lines) == ring.layout.wedges.map(\.lines)
            && m.wedges.map(\.symbol) == ring.layout.entries.map(\.symbol)
            && m.hovered == hovered && m.hoveredTab == tab
            && m.centerText == ring.centerText
            && m.centerActive == (ring.hover == .center && !ring.stack.isEmpty)
            && m.page == ring.pageIndex
            && m.tabs == (ring.pages.count > 1 ? ring.pages.map(\.title) : [])
            && m.tabFrames == ring.tabFrames
    }

    /// The shape that makes the window server hand drags to the ring (glass ring; nil for the Core Graphics ring).
    static func routingPath(_ ring: RadialMenuController) -> CGPath? {
        guard RingRootView.routesWithShapeLayer, let root = ring.debugContentView as? RingRootView else { return nil }
        return root.routing?.shape.path ?? CGMutablePath() // what is actually installed (empty = routes nothing)
    }

    /// Where a hover state contradicts the geometry at `p` (nil when consistent).
    static func sweepProblem(_ ring: RadialMenuController, _ p: NSPoint, _ op: NSDragOperation, routing: CGPath?) -> String? {
        let v = CGPoint(x: p.x - Ring.center.x, y: p.y - Ring.center.y)
        let r = hypot(v.x, v.y)
        let at = "(\(Int(p.x)), \(Int(p.y))) r=\(Int(r))"
        // Real drags only reach the ring where the routing shape is: every wedge and center point must be inside it,
        // and every point inside a tab (the slop around the tabs only catches near misses).
        let mustRoute: Bool
        switch ring.hover {
        case .entry, .center: mustRoute = true
        case .tab(let t): mustRoute = ring.tabFrames.indices.contains(t) && ring.tabFrames[t].insetBy(dx: 0.5, dy: 0.5).contains(p)
        case .none: mustRoute = false
        }
        if mustRoute, let routing, !routing.contains(p) { return "\(at): \(ring.hover) is hit-tested but real drags there never reach the ring" }
        let insideTab = ring.tabFrames.firstIndex { $0.contains(p) }
        let nearTab = ring.tabFrames.indices.filter { ring.tabFrames[$0].insetBy(dx: -3, dy: -5).contains(p) }
        if (op == .copy) != (ring.dropAction != nil) { return "\(at): drag operation \(op.rawValue) but drop action \(ring.dropAction?.id ?? "nil")" }
        switch ring.hover {
        case .entry(let i):
            guard ring.layout.entries.indices.contains(i) else { return "\(at): hovered wedge \(i) doesn't exist" }
            if ring.dropAction?.id != entryID(ring.layout.entries[i]) { return "\(at): drop \(ring.dropAction?.id ?? "nil") isn't wedge \(i)" }
            if r < Ring.core || r > Ring.radius + 12 { return "\(at): wedge \(i) hovered away from the ring" }
            let n = ring.layout.entries.count
            if n > 1, angleDistance(atan2(v.y, v.x), ring.layout.wedges[i].midAngle) > .pi / CGFloat(n) + 0.002 {
                return "\(at): wedge \(i) hovered outside its slice"
            }
        case .center:
            if r >= Ring.inner { return "\(at): center hovered outside the core" }
        case .tab(let t):
            if !nearTab.contains(t) { return "\(at): tab \(t) hovered away from it" }
            if let insideTab, insideTab != t { return "\(at): inside tab \(insideTab) but tab \(t) hovered" }
            if ring.dropAction != nil { return "\(at): a tab offers a drop" }
        case .none:
            if r <= Ring.radius { return "\(at): nothing hovered inside the disc" }
            if let insideTab { return "\(at): inside tab \(insideTab) but nothing hovered" }
        }
        return nil
    }

    // MARK: Entry point

    struct Scenario {
        let name: String
        let files: [URL]
        init(_ name: String, _ files: [URL]) { self.name = name; self.files = files }
    }

    static let fixtureNames = ["photo.jpg", "screenshot.png", "report.pdf", "clip.mp4", "tone.wav", "song.mp3",
                               "notes.md", "people.csv", "items.json", "bundle.zip"]

    static func run(files: [URL]) -> Int32 {
        // The checks wait on the ring's dwell timers: keep App Nap from throttling them (screen asleep, app hidden).
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Tangelo ring self-test")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var isDir: ObjCBool = false
        if files.count == 1, FileManager.default.fileExists(atPath: files[0].path, isDirectory: &isDir), isDir.boolValue,
           fixtureNames.contains(where: { FileManager.default.fileExists(atPath: files[0].appendingPathComponent($0).path) }) {
            return runFixtures(folder: files[0])
        }
        guard !files.isEmpty else {
            print("usage: Tangelo --self-test <fixtures folder> | file…")
            return 2
        }
        return runFiles(files)
    }

    /// Every scenario built from a fixtures folder (photo.jpg, report.pdf, clip.mp4, … ).
    static func runFixtures(folder: URL) -> Int32 {
        let fm = FileManager.default
        let f = { (name: String) in folder.appendingPathComponent(name) }
        let temp = fm.temporaryDirectory.appendingPathComponent("tangelo-selftest-\(UUID().uuidString)", isDirectory: true)
        let dropFolder = temp.appendingPathComponent("Sample Folder", isDirectory: true)
        try? fm.createDirectory(at: dropFolder, withIntermediateDirectories: true)
        for name in ["notes.md", "people.csv"] { try? fm.copyItem(at: f(name), to: dropFolder.appendingPathComponent(name)) }
        defer { try? fm.removeItem(at: temp) }

        let scenarios = [
            Scenario("single image", [f("photo.jpg")]),
            Scenario("2 images", [f("photo.jpg"), f("screenshot.png")]),
            Scenario("PDF", [f("report.pdf")]),
            Scenario("video", [f("clip.mp4")]),
            Scenario("audio", [f("tone.wav")]),
            Scenario("document (md)", [f("notes.md")]),
            Scenario("data (csv)", [f("people.csv")]),
            Scenario("data (json)", [f("items.json")]),
            Scenario("archive (zip)", [f("bundle.zip")]),
            Scenario("folder", [dropFolder]),
            Scenario("mixed (image + pdf)", [f("photo.jpg"), f("report.pdf")]),
            Scenario("mixed unrelated (image + mp3)", [f("photo.jpg"), f("song.mp3")]),
        ]
        let only = ProcessInfo.processInfo.environment["TANGELO_SELFTEST_ONLY"]
        let ring = RadialMenuController()
        let started = CACurrentMediaTime()
        var summary: [(name: String, passed: Int, failed: Int, seconds: Double)] = []
        for s in scenarios {
            if let only, !s.name.localizedCaseInsensitiveContains(only) { continue }
            let missing = s.files.filter { !fm.fileExists(atPath: $0.path) }
            if !missing.isEmpty {
                print("\nskip \(s.name): missing \(missing.map(\.lastPathComponent).joined(separator: ", "))")
                continue
            }
            let (p0, f0, t0) = (passed, failures, CACurrentMediaTime())
            runScenario(s, ring: ring)
            summary.append((s.name, passed - p0, failures - f0, CACurrentMediaTime() - t0))
        }

        if only == nil, let files = scenarios.first?.files {
            let (p0, f0, t0) = (passed, failures, CACurrentMediaTime())
            runLifecycle(ring: ring, files: files)
            summary.append(("glass ring lifecycle", passed - p0, failures - f0, CACurrentMediaTime() - t0))
        }

        print("\n== summary")
        for row in summary {
            let name = row.name.padding(toLength: max(32, row.name.count), withPad: " ", startingAt: 0)
            print((row.failed == 0 ? "ok   " : "FAIL ") + name + String(format: "%5d checks  %3d failed  %5.1f s", row.passed + row.failed, row.failed, row.seconds))
        }
        print(String(format: "%d scenarios, %d checks, %d failed, %.1f s", summary.count, passed + failures, failures,
                     CACurrentMediaTime() - started))
        print(failures == 0 ? "\nAll ring checks passed." : "\n\(failures) ring check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    // MARK: One scenario

    static func runScenario(_ s: Scenario, ring: RadialMenuController) {
        let d = RingDriver(ring: ring, files: s.files)
        defer { d.finish() }
        let tag = s.name
        let items = s.files.map { InputItem(url: $0) }
        let pages = Catalog.pages(for: items, settings: AppSettings.shared.engine)
        let info = infoText(items)
        let filePaths = s.files.map(standardPath)
        print("\n== \(tag): \(s.files.map(\.lastPathComponent).joined(separator: " + ")) → "
              + pages.map { "\($0.title) (\($0.entries.count))" }.joined(separator: " · "))
        guard !pages.isEmpty, pages.allSatisfy({ !$0.entries.isEmpty }) else {
            check(false, "\(tag): the catalog offers pages with wedges")
            return
        }
        func pageIDs(_ p: Int) -> [String] { pages[p].entries.map(entryID) }
        func layoutIDs() -> [String] { ring.layout.entries.map(entryID) }
        /// The ring handed exactly `expected` and every dropped file to the app, then closed.
        func ranOK(_ expected: String, _ what: String) {
            let runs = d.runs
            check(runs.count == 1 && runs.first?.action.id == expected, "\(what): runs \(expected) (got \(runs.map(\.action.id)))")
            if let source = runs.first?.source {
                var isFiles = false
                if case .files = source { isFiles = true }
                check(isFiles && droppedPaths(source) == filePaths, "\(what): hands over all \(filePaths.count) dropped item(s) (got \(droppedPaths(source).map { ($0 as NSString).lastPathComponent }))")
            }
            check(!ring.isVisible, "\(what): ring hides")
        }

        // A. Opening: the drag is read, pages and tabs are built, the center shows what's being dragged.
        section("\(tag) · opens, reads the drag, builds \(pages.count) page(s)") {
            let op = d.open()
            check(ring.isVisible && ring.mode == .drag, "\(tag): ring appears in drag mode")
            check(op == [], "\(tag): entering at the center offers no drop")
            check(ring.loaded, "\(tag): drag pasteboard read")
            check(ring.items.map { standardPath($0.url) } == filePaths, "\(tag): items are the dragged files (\(ring.items.map(\.url.lastPathComponent)))")
            check(ring.pages.map(\.title) == pages.map(\.title), "\(tag): pages \(ring.pages.map(\.title))")
            for (pi, page) in pages.enumerated() {
                check(ring.pages.indices.contains(pi) && ring.pages[pi].entries.map(entryID) == pageIDs(pi), "\(tag): \(page.title) entries")
            }
            check(ring.pageIndex == 0 && ring.stack.isEmpty && layoutIDs() == pageIDs(0), "\(tag): first page shown")
            check(ring.layout.wedges.count == ring.layout.entries.count, "\(tag): one wedge per entry")
            check(ring.hover == .center && ring.dropAction == nil && !ring.canDrop, "\(tag): center hovered, nothing to drop")
            check(ring.centerText == info, "\(tag): center reads \(info) (got \(ring.centerText))")
            if pages.count > 1 {
                check(ring.tabFrames.count == pages.count, "\(tag): \(pages.count) tabs")
                check(ring.tabFrames.allSatisfy { $0.minX >= 0 && $0.maxX <= Ring.size.width && $0.maxY < Ring.center.y - Ring.radius },
                      "\(tag): tabs sit inside the panel, under the disc")
                check(zip(ring.tabFrames, ring.tabFrames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 }, "\(tag): tabs don't overlap")
            } else {
                check(ring.tabFrames.isEmpty, "\(tag): a single page has no tabs")
            }
            check(modelInSync(ring), "\(tag): glass model matches the ring")
            if ring.usesGlass { check(wait(0.3) { ring.model.shown }, "\(tag): glass ring animates in") }
            for p in pages.indices {
                let image = RadialMenuController().snapshot(items: items, page: p)
                check(image.size == Ring.size, "\(tag): offscreen render of page \(p)")
            }
        }

        // B. Every page via tab hover; every wedge, its edges, the gaps, outside the disc and a full sweep.
        for (pi, page) in pages.enumerated() {
            let n = page.entries.count
            section("\(tag) · \(page.title)\(pages.count > 1 ? " via tab hover" : ""): \(n) wedge(s), edges, gaps, outside, sweep") {
                if pages.count > 1 {
                    d.move(d.tabPoint(pi))
                    check(ring.hover == .tab(pi) && ring.dropAction == nil, "\(tag): \(page.title) tab hovered, tabs offer no drop")
                    check(ring.centerText == page.title, "\(tag): center names the hovered tab (got \(ring.centerText))")
                    check(modelInSync(ring), "\(tag): glass model shows the hovered tab")
                    if pi == ring.pageIndex { spin(tabDwell + 0.08) } else { wait(tabDwell + 0.6) { ring.pageIndex == pi } }
                    check(ring.pageIndex == pi, "\(tag): hovering the \(page.title) tab shows it")
                }
                check(ring.stack.isEmpty && layoutIDs() == pageIDs(pi), "\(tag): \(page.title) wedges shown (\(ring.layout.entries.map(\.title)))")
                check(modelInSync(ring), "\(tag) · \(page.title): glass model in sync")
                let span = 2 * CGFloat.pi / CGFloat(n)
                for (i, e) in page.entries.enumerated() where ring.layout.wedges.indices.contains(i) {
                    let w = ring.layout.wedges[i]
                    let name = "\(tag) · \(page.title) · \(e.title)"
                    check(angleDistance(w.midAngle, .pi / 2 - CGFloat(i) * span) < 0.0001, "\(name): wedge \(i) sits clockwise from the top")
                    check(w.path.contains(CGPoint(x: cos(w.midAngle) * rMid, y: sin(w.midAngle) * rMid)), "\(name): its hover point is inside the drawn wedge")
                    let op = d.move(d.wedgePoint(i))
                    check(op == .copy && ring.canDrop, "\(name): offers a copy drop")
                    check(ring.hover == .entry(i), "\(name): hovered")
                    check(ring.dropAction?.id == entryID(e), "\(name): drop runs \(entryID(e)) (got \(ring.dropAction?.id ?? "nil"))")
                    check(ring.centerText == entryText(e), "\(name): center reads \(entryText(e)) (got \(ring.centerText))")
                    check(modelInSync(ring), "\(name): glass model highlights it")
                    let spots: [(String, CGFloat, CGFloat)] = [
                        ("inner edge", Ring.inner + 1, 0), ("outer edge", Ring.outer - 1, 0), ("rim", Ring.radius - 1, 0),
                        ("leading side", rMid, span * 0.45), ("trailing side", rMid, -span * 0.45),
                    ]
                    for (spot, r, da) in spots {
                        d.move(point(angle: w.midAngle + da, radius: r))
                        check(ring.dropAction?.id == entryID(e), "\(name): \(spot) → \(ring.dropAction?.id ?? "nil")")
                    }
                    d.move(point(angle: w.midAngle, radius: Ring.radius + 6))
                    check(ring.dropAction == nil || ring.dropAction?.id == entryID(e), "\(name): just outside the disc → this wedge or nothing")
                    d.move(point(angle: w.midAngle, radius: (Ring.core + Ring.inner) / 2))
                    check(ring.hover == .center || ring.dropAction?.id == entryID(e), "\(name): between the core and the wedge → center or this wedge")
                    if n > 1 {
                        let j = (i + 1) % n
                        let next = page.entries[j]
                        let gapAngle = w.midAngle - span / 2
                        for r in [Ring.inner + 3, rMid, Ring.outer - 3, Ring.radius + 4] {
                            d.move(point(angle: gapAngle, radius: r))
                            let got = ring.dropAction?.id
                            check(got == entryID(e) || got == entryID(next), "\(name): gap to \(next.title) at r=\(Int(r)) → \(got ?? "nil")")
                        }
                        let g = CGPoint(x: cos(gapAngle) * rMid, y: sin(gapAngle) * rMid)
                        check(!w.path.contains(g) && !ring.layout.wedges[j].path.contains(g), "\(name): visible gap before \(next.title)")
                    }
                }
                // Well outside the disc (but not on a tab) nothing is hovered.
                var a: CGFloat = 0
                while a < 2 * .pi - 0.01 {
                    let p = point(angle: a, radius: Ring.radius + 24)
                    let degrees = Int((a * 180 / .pi).rounded())
                    a += .pi / 8
                    if ring.tabFrames.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(p) }) { continue }
                    let op = d.move(p)
                    check(op == [] && ring.dropAction == nil && ring.hover == HoverNone, "\(tag) · \(page.title): far outside at \(degrees)° → nothing")
                }
                for p in [NSPoint(x: -20, y: -20), NSPoint(x: Ring.size.width + 30, y: Ring.center.y), NSPoint(x: Ring.center.x, y: Ring.size.height + 40)] {
                    let op = d.move(p)
                    check(op == [] && ring.dropAction == nil, "\(tag) · \(page.title): outside the panel at (\(Int(p.x)), \(Int(p.y))) → nothing")
                }
                // Sweep the whole panel: the hover state agrees with the geometry everywhere.
                let size = Ring.size
                let routing = routingPath(ring)
                var problems: [String] = []
                var count = 0
                var y: CGFloat = 2
                while y < size.height {
                    var x: CGFloat = 2
                    while x < size.width {
                        let p = NSPoint(x: x, y: y)
                        if let problem = sweepProblem(ring, p, d.move(p), routing: routing) { problems.append(problem) }
                        count += 1
                        x += 9
                    }
                    y += 9
                }
                check(problems.isEmpty, "\(tag) · \(page.title): sweep of \(count) points → \(problems.count) inconsistent\(problems.first.map { ", first \($0)" } ?? "")")
                check(ring.pageIndex == pi && ring.stack.isEmpty, "\(tag) · \(page.title): sweeping over wedges and tabs switches nothing")
                check(modelInSync(ring), "\(tag) · \(page.title): glass model in sync after the sweep")
                let hasGroups = pages.contains { $0.entries.contains { if case .group = $0 { return true } else { return false } } }
                if pi == pages.count - 1 && hasGroups {
                    // Nothing that was hovered on the way keeps a dwell running: park in the core and wait.
                    d.move(Ring.center)
                    spin(groupDwell + 0.2)
                    check(ring.pageIndex == pi && ring.stack.isEmpty && layoutIDs() == pageIDs(pi), "\(tag): passing over wedges and tabs opens nothing later")
                }
            }
        }

        // C. Groups: dwell opens exactly the children, each child hit-tests, the center dwell pops back,
        //    a drop right after the dwell runs the child under the cursor.
        var firstGroup = true
        for (pi, page) in pages.enumerated() {
            for (gi, entry) in page.entries.enumerated() {
                guard case .group(let title, _, let children, let primary) = entry else { continue }
                let name = "\(tag) · \(page.title) › \(title)"
                let childIDs = children.map(\.id)
                var gp = NSPoint.zero
                var under: [Int] = []   // children under the group's hover point once the sub-ring opens (2 on a gap)
                var k = 0               // the one the ring picked
                section("\(name): dwell opens \(children.count) children, center dwell goes back, drop after dwell") {
                    d.open()
                    d.goToPage(pi)
                    check(ring.pageIndex == pi, "\(name): on \(page.title)")
                    gp = d.wedgePoint(gi)
                    under = wedgesAt(angle: ring.layout.wedges[gi].midAngle, count: children.count)
                    d.move(gp)
                    check(ring.dropAction?.id == primary.id && ring.centerText == title + " ›", "\(name): hovering the group offers \(primary.id)")
                    let opened = wait(groupDwell + 0.6) { !ring.stack.isEmpty }
                    check(opened && ring.stack.count == 1 && ring.stack.last?.title == title, "\(name): dwell opens the sub-ring")
                    check(layoutIDs() == childIDs, "\(name): sub-ring holds exactly its children (\(ring.layout.entries.map(\.title)))")
                    check(ring.pageIndex == pi, "\(name): page unchanged")
                    k = hoveredIndex(ring) ?? -1
                    check(under.contains(k) && ring.dropAction?.id == children[max(k, 0)].id && ring.centerText == children[max(k, 0)].title,
                          "\(name): the child under the cursor (\(under.map { children[$0].title })) is hovered at once (got \(ring.dropAction?.id ?? "nil"), \(ring.centerText))")
                    check(modelInSync(ring), "\(name): glass model shows the sub-ring")
                    for (ci, c) in children.enumerated() where ring.layout.wedges.indices.contains(ci) {
                        let op = d.move(d.wedgePoint(ci))
                        check(op == .copy && ring.hover == .entry(ci) && ring.dropAction?.id == c.id && ring.centerText == c.title,
                              "\(name) › \(c.title): hit-tests to \(c.id) (got \(ring.dropAction?.id ?? "nil"), \(ring.centerText))")
                        for r in [Ring.inner + 1, Ring.outer - 1] {
                            d.move(point(angle: ring.layout.wedges[ci].midAngle, radius: r))
                            check(ring.dropAction?.id == c.id, "\(name) › \(c.title): edge at r=\(Int(r))")
                        }
                        check(modelInSync(ring), "\(name) › \(c.title): glass model in sync")
                    }
                    d.move(Ring.center)
                    check(ring.hover == .center && ring.centerText == "‹ BACK" && ring.dropAction == nil && modelInSync(ring),
                          "\(name): the center offers ‹ BACK, no drop")
                    let passOver = once("pass over the center")
                    if passOver {
                        d.move(d.wedgePoint(children.count - 1))
                        spin(centerDwell + 0.2)
                        check(ring.stack.count == 1 && layoutIDs() == childIDs, "\(name): passing over the center stays; children open nothing")
                    }
                    d.move(Ring.center)
                    let back = wait(centerDwell + 0.6) { ring.stack.isEmpty }
                    check(back && layoutIDs() == pageIDs(pi) && ring.pageIndex == pi, "\(name): dwelling on the center goes back to \(page.title)")
                    check(ring.hover == .center && ring.centerText == info && modelInSync(ring), "\(name): back on the page, the center reads \(info) (got \(ring.centerText))")
                    if passOver {
                        spin(centerDwell + 0.1)
                        check(ring.stack.isEmpty && ring.pageIndex == pi && layoutIDs() == pageIDs(pi), "\(name): staying in the center does nothing more")
                    }
                    d.move(gp)
                    check(wait(groupDwell + 0.6) { !ring.stack.isEmpty }, "\(name): opens again")
                    let picked = hoveredIndex(ring) ?? -1
                    check(under.contains(picked), "\(name): reopened on the child under the cursor")
                    let r = d.release()
                    check(r.prepared && r.performed, "\(name): a drop right after the dwell (no move) is accepted")
                    ranOK(children[max(picked, 0)].id, "\(name): drop right after the dwell runs the highlighted \(children[max(picked, 0)].title)")
                }
                section("\(name): drop on the group itself\(firstGroup ? ", and on a child after moving" : "")") {
                    d.open()
                    d.goToPage(pi)
                    d.move(d.wedgePoint(gi))
                    var r = d.release()
                    check(r.prepared && r.performed, "\(name): a drop without waiting is accepted")
                    ranOK(primary.id, "\(name): drop without waiting")
                    if firstGroup {
                        let ci = (0..<children.count).reversed().first { !under.contains($0) } ?? 0
                        d.open()
                        d.goToPage(pi)
                        d.move(d.wedgePoint(gi))
                        wait(groupDwell + 0.6) { !ring.stack.isEmpty }
                        d.move(d.wedgePoint(ci))
                        r = d.release()
                        check(r.prepared && r.performed, "\(name) › \(children[ci].title): drop accepted")
                        ranOK(children[ci].id, "\(name) › \(children[ci].title): drop after moving")
                    }
                    if pages.count > 1 && once("tab and Shift inside a sub-ring") {
                        // Hovering the current tab from inside a sub-ring leaves it.
                        d.open()
                        d.goToPage(pi)
                        d.move(d.wedgePoint(gi))
                        wait(groupDwell + 0.6) { !ring.stack.isEmpty }
                        d.move(d.tabPoint(pi))
                        check(ring.hover == .tab(pi) && ring.centerText == page.title && modelInSync(ring), "\(name): \(page.title) tab hovered from the sub-ring")
                        let left = wait(tabDwell + 0.6) { ring.stack.isEmpty }
                        check(left && ring.pageIndex == pi && layoutIDs() == pageIDs(pi), "\(name): hovering the \(page.title) tab leaves the sub-ring")
                        // Tapping Shift inside a sub-ring flips to the next page and re-targets the wedge under the cursor.
                        d.move(gp)
                        wait(groupDwell + 0.6) { !ring.stack.isEmpty }
                        d.tapTrigger()
                        let next = (pi + 1) % pages.count
                        check(ring.stack.isEmpty && ring.pageIndex == next && layoutIDs() == pageIDs(next), "\(name): tapping Shift in the sub-ring flips to \(pages[next].title)")
                        let below = wedgesAt(angle: atan2(gp.y - Ring.center.y, gp.x - Ring.center.x), count: pages[next].entries.count)
                        check(below.contains(hoveredIndex(ring) ?? -1) && modelInSync(ring),
                              "\(name): after the flip the wedge under the cursor (\(below.map { pages[next].entries[$0].title })) is hovered (got \(ring.dropAction?.id ?? "nil"))")
                        ring.hide(animated: false)
                    }
                }
                firstGroup = false
            }
        }

        // D. Drop on every wedge of every page: onRun gets that action and all the files, and the ring hides.
        section("\(tag) · drop on each of \(pages.reduce(0) { $0 + $1.entries.count }) wedges runs it with all files") {
            for (pi, page) in pages.enumerated() {
                for (i, e) in page.entries.enumerated() {
                    let name = "\(tag) · drop · \(page.title) · \(e.title)"
                    d.open()
                    d.goToPage(pi)
                    d.move(d.wedgePoint(i))
                    let r = d.release()
                    check(r.prepared && r.performed, "\(name): accepted")
                    ranOK(entryID(e), name)
                    if ring.usesGlass { check(!ring.model.shown, "\(name): glass ring animates out") }
                }
            }
        }

        // E. Tapping the trigger key cycles pages; holding it flips once; the wedge under the cursor follows.
        section("\(tag) · tapping Shift cycles \(pages.count) page(s)") {
            d.open()
            let park = point(angle: .pi / 2, radius: rMid) // over wedge 0 on every page
            d.move(park)
            for tap in 1...(pages.count + 1) {
                let expect = (ring.pageIndex + 1) % pages.count
                d.tapTrigger()
                check(ring.pageIndex == expect && ring.stack.isEmpty && layoutIDs() == pageIDs(expect), "\(tag): Shift tap \(tap) → \(pages[expect].title)")
                check(ring.hover == .entry(0) && ring.dropAction?.id == entryID(pages[expect].entries[0]),
                      "\(tag): Shift tap \(tap): the wedge under the cursor is \(pages[expect].entries[0].title) (got \(ring.dropAction?.id ?? "nil"))")
                check(modelInSync(ring), "\(tag): Shift tap \(tap): glass model in sync")
            }
            let held = ring.pageIndex
            ring.modifiersChanged([])
            for _ in 0..<5 { ring.modifiersChanged(.shift) }
            check(ring.pageIndex == (held + 1) % pages.count, "\(tag): holding Shift flips only once")
            let other = ring.pageIndex
            ring.modifiersChanged([.shift, .option])
            ring.modifiersChanged([.shift, .command])
            ring.modifiersChanged(.shift)
            check(ring.pageIndex == other, "\(tag): other modifiers alongside Shift don't flip")
            let expected = entryID(pages[ring.pageIndex].entries[0])
            let r = d.release()
            check(r.prepared && r.performed, "\(tag): drop after cycling accepted")
            ranOK(expected, "\(tag): drop after cycling lands on the visible page")
        }

        // F. Cancel paths.
        section("\(tag) · center, outside and tab drops do nothing; leaving cancels; re-entering resumes") {
            d.open()
            d.move(Ring.center)
            check(!ring.prepareDrop(d.drag), "\(tag): the center refuses the drop")
            check(!ring.performDrop(d.drag), "\(tag): performDrop in the center does nothing")
            flush()
            check(d.runs.isEmpty && ring.isVisible, "\(tag): nothing runs from the center")
            ring.dragEnded()
            check(!ring.isVisible && d.runs.isEmpty, "\(tag): the ring closes when the cancelled drag ends")

            var spots: [(String, NSPoint)] = [("far outside the disc", NSPoint(x: 6, y: Ring.size.height - 6)),
                                               ("just outside the disc", point(angle: .pi / 4, radius: Ring.radius + 20))]
            if pages.count > 1 { spots.append(("on a tab", NSPoint(x: ring.tabFrames.last!.midX, y: ring.tabFrames.last!.midY))) }
            for (what, p) in spots {
                d.open()
                d.move(p)
                let r = d.release()
                check(!r.prepared && !r.performed && d.runs.isEmpty && !ring.isVisible, "\(tag): a drop \(what) runs nothing and closes the ring")
            }

            d.open()
            d.move(d.wedgePoint(0))
            ring.dragExited()
            check(ring.hover == HoverNone && ring.dropAction == nil && modelInSync(ring), "\(tag): leaving the ring clears the hover")
            if once("release elsewhere") {
                ring.mouseReleased()
                check(wait(1.0) { !ring.isVisible } && d.runs.isEmpty, "\(tag): letting go elsewhere closes the ring, runs nothing")
            }

            d.open()
            d.goToPage(pages.count - 1)
            let last = ring.pageIndex
            d.move(d.wedgePoint(0))
            ring.dragExited()
            let pendingClose = once("re-enter cancels a pending close")
            if pendingClose { ring.mouseReleased() } // a button-up report racing the drag coming back
            d.drag.location = d.wedgePoint(0)
            let op = ring.dragEntered(d.drag)
            check(op == .copy && ring.pageIndex == last && ring.items.count == s.files.count, "\(tag): re-entering keeps the page and the files")
            if pendingClose {
                spin(0.45)
                check(ring.isVisible, "\(tag): re-entering cancels the pending close")
            }
            var r = d.release()
            check(r.performed, "\(tag): drop after re-entering accepted")
            ranOK(entryID(pages[last].entries[0]), "\(tag): drop after re-entering")

            if pages.count > 1 {
                d.open()
                d.move(d.tabPoint(1))
                d.move(d.wedgePoint(0))
                spin(tabDwell + 0.1)
                check(ring.pageIndex == 0, "\(tag): brushing past a tab doesn't switch pages")
                r = d.release()
                ranOK(entryID(pages[0].entries[0]), "\(tag): drop after brushing past a tab stays on \(pages[0].title)")
            }
        }

        // G. Click mode (menu bar → Convert Files…).
        section("\(tag) · click mode: every wedge runs, groups open, Esc pops and hides") {
            d.openClick()
            check(ring.isVisible && ring.mode == .click && ring.loaded, "\(tag): click ring opens")
            check(ring.pages.map(\.title) == pages.map(\.title) && layoutIDs() == pageIDs(0), "\(tag): click ring has the same pages")
            check(ring.centerText == info && modelInSync(ring), "\(tag): click ring center reads \(info)")
            if pages.count > 1 {
                for pi in pages.indices.reversed() {
                    d.click(d.tabPoint(pi))
                    check(ring.isVisible && ring.pageIndex == pi && layoutIDs() == pageIDs(pi) && d.runs.isEmpty, "\(tag): clicking the \(pages[pi].title) tab shows it")
                }
                for press in 1...pages.count {
                    d.key(48)
                    check(ring.pageIndex == press % pages.count, "\(tag): Tab key \(press) → \(pages[press % pages.count].title)")
                }
                d.key(124)
                check(ring.pageIndex == 1 % pages.count, "\(tag): → goes to the next page")
                d.key(123)
                check(ring.pageIndex == 0 && ring.isVisible, "\(tag): ← goes back")
            } else {
                d.key(48)
                d.key(124)
                d.key(123)
                check(ring.pageIndex == 0 && ring.isVisible && layoutIDs() == pageIDs(0), "\(tag): page keys do nothing on a single page")
            }
            for (pi, page) in pages.enumerated() {
                for (i, e) in page.entries.enumerated() {
                    let name = "\(tag) · click · \(page.title) · \(e.title)"
                    d.openClick()
                    d.clickPage(pi)
                    switch e {
                    case .action(let a):
                        ring.mouseMoved(to: d.wedgePoint(i))
                        check(ring.hover == .entry(i) && ring.dropAction?.id == a.id && ring.centerText == a.title && modelInSync(ring), "\(name): hover")
                        d.click(d.wedgePoint(i))
                        ranOK(a.id, name)
                    case .group(let title, _, let children, _):
                        // Clicked straight away: the pointer hasn't moved since the ring appeared.
                        let angle = ring.layout.wedges[i].midAngle
                        d.click(d.wedgePoint(i))
                        check(ring.isVisible && ring.stack.count == 1 && ring.stack.last?.title == title && layoutIDs() == children.map(\.id),
                              "\(name): click opens the sub-ring (\(ring.layout.entries.map(\.title)))")
                        let under = wedgesAt(angle: angle, count: children.count)
                        let k = hoveredIndex(ring) ?? -1
                        check(under.contains(k) && ring.centerText == children[max(k, 0)].title && modelInSync(ring),
                              "\(name): the child under the pointer (\(under.map { children[$0].title })) is hovered (got \(ring.centerText))")
                        if once("click-opened sub-ring stays single") {
                            spin(groupDwell + 0.2)
                            check(ring.stack.count == 1 && layoutIDs() == children.map(\.id), "\(name): no second sub-ring opens by itself")
                        }
                        d.key(53)
                        check(ring.isVisible && ring.stack.isEmpty && ring.pageIndex == pi && layoutIDs() == pageIDs(pi) && d.runs.isEmpty, "\(name): Esc goes back")
                        d.click(d.wedgePoint(i))
                        d.click(Ring.center)
                        check(ring.isVisible && ring.stack.isEmpty && ring.pageIndex == pi && d.runs.isEmpty, "\(name): clicking the center goes back")
                        for (ci, c) in children.enumerated() {
                            d.openClick()
                            d.clickPage(pi)
                            d.click(d.wedgePoint(i))
                            ring.mouseMoved(to: d.wedgePoint(ci))
                            check(ring.dropAction?.id == c.id && ring.centerText == c.title, "\(name) › \(c.title): hover")
                            d.click(d.wedgePoint(ci))
                            ranOK(c.id, "\(name) › \(c.title)")
                        }
                    }
                }
            }
            d.openClick()
            d.key(53)
            check(!ring.isVisible && d.runs.isEmpty, "\(tag): Esc closes the click ring")
            d.openClick()
            d.click(Ring.center)
            check(!ring.isVisible && d.runs.isEmpty, "\(tag): clicking the center closes the click ring")
            d.openClick()
            d.click(NSPoint(x: 6, y: Ring.size.height - 6))
            check(!ring.isVisible && d.runs.isEmpty, "\(tag): clicking outside closes the click ring")
        }
    }

    static let HoverNone = RadialMenuController.Hover.none

    // MARK: Glass ring lifecycle

    /// The SwiftUI glass ring exists only while the ring is on screen, the drag-routing shape is right,
    /// and showing the ring again and again doesn't grow the heap.
    static func runLifecycle(ring: RadialMenuController, files: [URL]) {
        print("\n== glass ring lifecycle")
        let d = RingDriver(ring: ring, files: files)
        defer { d.finish() }
        section("lifecycle · glass ring built on show, freed after hide; drag routing; steady heap over 20 shows") {
            guard ring.usesGlass else {
                check(!ring.hasGlassHost, "Core Graphics ring: no glass host")
                return
            }
            weak var host: NSView?
            autoreleasepool {
                d.open()
                flush()
                check(ring.hasGlassHost && ring.isVisible, "the glass ring is built when the ring shows")
                host = ring.debugContentView?.subviews.last
                let hostType = host.map { String(describing: type(of: $0)) } ?? "nothing"
                check(hostType.contains("NSHostingView") && hostType.contains("GlassRingView"), "it is the SwiftUI glass ring (got \(hostType))")
                check(ring.glassHostBuildMS < 16, String(format: "building it took %.2f ms (under a 60 Hz frame)", ring.glassHostBuildMS))
                if let root = ring.debugContentView as? RingRootView, let routing = root.routing {
                    check(routing.shape.path == root.routingPath(discRadius: Ring.reach), "the drag-routing shape covers the disc and the tab bar")
                    check((routing.shape.fillColor?.alpha ?? 0) > 0 && routing.layer === routing.shape && routing.shape.contents == nil,
                          "it is an (invisible) shape fill with no bitmap")
                    check(root.layer?.contents == nil, "the root view keeps no bitmap backing store")
                    check(root.subviews.first === routing && root.subviews.last === host, "the routing shape sits under the glass ring")
                } else {
                    check(false, "the glass ring has a drag-routing shape")
                }
                d.move(d.wedgePoint(0))
                ring.hide() // animated, as after a drop
                check(ring.hasGlassHost, "the glass ring stays while the ring fades out")
            }
            check(wait(1.0) { !ring.hasGlassHost }, "the glass ring is dropped once the ring has faded out")
            spin(0.1)
            check(host == nil, "…and deallocated")
            check(!ring.model.shown, "the model is left hidden")

            // Showing again works from scratch, and the heap stays level.
            let cycle = { (i: Int) in
                autoreleasepool {
                    d.open()
                    flush()
                    d.move(point(angle: CGFloat(i), radius: rMid))
                    spin(0.1)
                    ring.hide(animated: false)
                    flush()
                }
            }
            for i in 0..<3 { cycle(i) }
            check(!ring.hasGlassHost && d.runs.isEmpty, "more shows leave nothing behind")
            let before = MemoryRelief.mallocMB().inUse
            for i in 0..<20 { cycle(i) }
            spin(0.3)
            let grown = MemoryRelief.mallocMB().inUse - before
            check(grown < 2.5, String(format: "20 more shows grow the heap by %.2f MB (< 2.5 MB; it used to grow ~0.3 MB per show)", grown))
        }
    }

    // MARK: Quick scripted drag (file list form)

    static func runFiles(_ files: [URL]) -> Int32 {
        let ring = RadialMenuController()
        ring.trigger = .shift
        var ran: (Action, DropSource)?
        ring.onRun = { action, source, _ in ran = (action, source) }

        let pb = NSPasteboard(name: NSPasteboard.Name("tangelo.selftest.\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(files.map { $0 as NSURL })

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        ring.showForDrag(at: NSPoint(x: screen.midX, y: screen.midY))
        spin(0.15)
        check(ring.isVisible, "ring appears on trigger")

        let drag = MockDrag(pasteboard: pb, location: Ring.center)
        check(ring.dragEntered(drag) == [], "drag enters at the center → no drop (cancel zone)")
        check(ring.loaded && ring.items.count == files.count, "files are read from the drag pasteboard (\(ring.items.count))")
        check(!ring.pages.isEmpty, "pages built: \(ring.pages.map(\.title).joined(separator: ", "))")
        check(ring.centerText == infoText(files.map { InputItem(url: $0) }), "center shows file info (\(ring.centerText))")

        let probe = min(1, ring.layout.entries.count - 1)
        drag.location = wedgePoint(ring, probe)
        let op = ring.dragUpdated(drag)
        let expected = ring.dropAction
        check(op == .copy, "hovering a wedge offers a copy drop")
        check(ring.centerText == entryText(ring.layout.entries[probe]), "center echoes the hovered wedge (\(ring.centerText))")

        // Hover the TOOLS tab → page switches.
        if ring.tabFrames.count > 2 {
            drag.location = NSPoint(x: ring.tabFrames[2].midX, y: ring.tabFrames[2].midY)
            _ = ring.dragUpdated(drag)
            spin(0.35)
            check(ring.pageIndex == 2, "hovering the \(ring.pages[2].title) tab switches page")
        }

        // Dwell on a group wedge → sub-ring opens; dwell on the center → back.
        if let g = ring.layout.entries.firstIndex(where: { if case .group = $0 { return true } else { return false } }) {
            let title = ring.layout.entries[g].title
            drag.location = wedgePoint(ring, g)
            _ = ring.dragUpdated(drag)
            spin(0.75)
            check(ring.stack.count == 1, "dwelling on \(title) opens its sub-ring (\(ring.layout.entries.map(\.title).joined(separator: ", ")))")
            drag.location = Ring.center
            _ = ring.dragUpdated(drag)
            spin(0.9)
            check(ring.stack.isEmpty, "dwelling on the center goes back")
        }

        // Regression: dwell on a group until its sub-ring opens, then release without moving the mouse.
        if let g = ring.layout.entries.firstIndex(where: { if case .group = $0 { return true } else { return false } }) {
            ran = nil
            let groupTitle = ring.layout.entries[g].title
            drag.location = wedgePoint(ring, g)
            _ = ring.dragUpdated(drag)
            spin(0.75)
            let childUnderCursor = ring.stack.isEmpty ? nil : ring.dropAction
            let accepted = ring.performDrop(drag)
            spin(0.3)
            check(accepted && ran != nil && ran?.0.id == childUnderCursor?.id,
                  "drop right after \(groupTitle)'s sub-ring opens runs \(childUnderCursor?.id ?? "nothing") (got \(ran?.0.id ?? "nothing"))")
            ring.showForDrag(at: NSPoint(x: screen.midX, y: screen.midY))
            spin(0.15)
            drag.location = Ring.center
            _ = ring.dragEntered(drag)
            if ring.tabFrames.count > 2 {
                drag.location = NSPoint(x: ring.tabFrames[2].midX, y: ring.tabFrames[2].midY)
                _ = ring.dragUpdated(drag)
                spin(0.35)
            }
        }

        // Tap the trigger key again → next page.
        let before = ring.pageIndex
        ring.modifiersChanged([])
        ring.modifiersChanged(.shift)
        check(ring.pageIndex == (before + 1) % ring.pages.count, "tapping Shift flips to the next page")

        // Back to page 0, drop on the probed wedge.
        if let t = ring.tabFrames.first {
            drag.location = NSPoint(x: t.midX, y: t.midY)
            _ = ring.dragUpdated(drag)
            spin(0.35)
        }
        drag.location = wedgePoint(ring, probe)
        _ = ring.dragUpdated(drag)
        check(ring.canDrop, "drop allowed over a wedge")
        ran = nil
        check(ring.performDrop(drag), "drop accepted")
        spin(0.4)
        check(ran?.0.id == expected?.id, "drop runs \(expected?.id ?? "?") (got \(ran?.0.id ?? "nothing"))")
        if case .files(let items)? = ran?.1 { check(items.count == files.count, "dropped files are passed along") }
        check(!ring.isVisible, "ring hides after the drop")

        // Click mode (menu bar "Convert Files…").
        ran = nil
        ring.showForClick(items: files.map { InputItem(url: $0) }, at: NSPoint(x: screen.midX, y: screen.midY))
        spin(0.2)
        ring.mouseMoved(to: wedgePoint(ring, 0))
        let clickExpected = ring.dropAction
        ring.mouseClicked(at: wedgePoint(ring, 0))
        spin(0.3)
        if case .group = ring.layout.entries.first ?? .action(Action("", "")), ring.isVisible {
            check(ring.stack.count == 1, "click mode opens \(ring.stack.last?.title ?? "?")")
        } else {
            check(ran?.0.id == clickExpected?.id && ran != nil, "click mode runs \(clickExpected?.id ?? "?")")
        }
        ring.hide(animated: false)
        ring.onRun = nil
        pb.releaseGlobally()

        // The full sweep for these files.
        let sweepRing = RadialMenuController()
        runScenario(Scenario("files", files), ring: sweepRing)
        runLifecycle(ring: sweepRing, files: files)
        print(failures == 0 ? "\nAll ring checks passed." : "\n\(failures) ring check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
