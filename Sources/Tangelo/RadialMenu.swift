import AppKit
import SwiftUI
import TangeloCore
import UniformTypeIdentifiers

/// What the ring hands to the app when the user drops on a wedge.
enum DropSource {
    case files([InputItem])
    case promises(PromiseLoader, [InputItem])
}

/// Receives promised files (Photos, Mail, Safari images) into a temporary folder as soon as they're dropped.
final class PromiseLoader {
    let directory: URL
    private var urls: [URL] = []
    private var errors: [Error] = []
    private var pending: Int
    private var waiters: [CheckedContinuation<[URL], Error>] = []

    init(receivers: [NSFilePromiseReceiver]) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tangelo Drops/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pending = receivers.reduce(0) { $0 + max($1.fileTypes.count, 1) }
        let queue = OperationQueue()
        for r in receivers {
            r.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { [weak self] url, error in
                DispatchQueue.main.async { self?.received(url, error) }
            }
        }
    }

    private func received(_ url: URL, _ error: Error?) {
        if let error { errors.append(error) } else { urls.append(url) }
        pending -= 1
        if pending <= 0 { finish() }
    }

    private func finish() {
        let result: Result<[URL], Error> = urls.isEmpty
            ? .failure(errors.first ?? TangeloError.failed("The dropped item couldn't be read."))
            : .success(urls)
        waiters.forEach { $0.resume(with: result) }
        waiters.removeAll()
    }

    @MainActor
    func wait() async throws -> [URL] {
        if pending <= 0 { return urls }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}

final class RadialPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The ring: a floating, non-activating panel that is a drag destination.
final class RadialMenuController: NSObject, NSWindowDelegate {
    enum Mode { case drag, click }
    enum Hover: Equatable { case none, entry(Int), center, tab(Int) }

    var onRun: ((Action, DropSource, NSPoint) -> Void)?
    var trigger: NSEvent.ModifierFlags = .shift

    private(set) var isVisible = false
    private let panel: RadialPanel
    private let root: RingRootView
    private let ringView: RingView
    private var discBackground: NSView!
    private var tabsBackground: NSView!

    // Content
    private(set) var items: [InputItem] = []
    private var receivers: [NSFilePromiseReceiver] = []
    private(set) var pages: [MenuPage] = []
    private(set) var pageIndex = 0
    private(set) var stack: [(title: String, entries: [MenuEntry])] = []
    private(set) var loaded = false
    private(set) var mode: Mode = .drag
    private(set) var hover: Hover = .none
    private var dropped = false
    /// Last cursor position over the ring (view coordinates), used to re-target after the ring changes.
    private var lastPoint: NSPoint?

    // Animation state read by RingView
    private(set) var layout = RingLayout.empty
    private(set) var previous: RingLayout?
    private(set) var transition: CGFloat = 1
    private(set) var transitionDirection: CGFloat = 1
    private(set) var appear: CGFloat = 1
    private(set) var highlights: [CGFloat] = []
    private(set) var tabHighlights: [CGFloat] = []
    private(set) var centerHighlight: CGFloat = 0
    private(set) var tabFrames: [NSRect] = []

    /// Liquid Glass renderer state (macOS 26+). Older systems use the Core Graphics RingView.
    let model = RingModel()
    let usesGlass: Bool = { if #available(macOS 26.0, *) { return true } else { return false } }()
    private var generation = 0
    /// The SwiftUI glass ring, alive only while the ring is on screen. A hidden NSHostingView keeps its render
    /// graph, Metal surfaces and the glass container's per-wedge bookkeeping (which grows with every show),
    /// so it is built in `present` and released once the ring has faded out.
    private var glassHost: NSView?
    /// How long building the glass host took on the last show (ms), for the self-test.
    private(set) var glassHostBuildMS: Double = 0
    var hasGlassHost: Bool { glassHost != nil }

    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var dwell: Timer?
    private var lastTriggerDown = true
    private var hideWork: DispatchWorkItem?
    private(set) var screenCenter: NSPoint = .zero

    override init() {
        let size = Ring.size
        panel = RadialPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        root = RingRootView.routesWithShapeLayer ? RingRootView(frame: NSRect(origin: .zero, size: size))
                                                 : ShadowRingRootView(frame: NSRect(origin: .zero, size: size))
        ringView = RingView(frame: NSRect(origin: .zero, size: size))
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.delegate = self

        root.controller = self
        ringView.controller = self
        root.registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })

        let c = Ring.center
        let discRect = NSRect(x: c.x - Ring.radius, y: c.y - Ring.radius, width: Ring.radius * 2, height: Ring.radius * 2)
        let tabsRect = NSRect(x: 0, y: 2, width: 100, height: Ring.tabHeight)
        if usesGlass {
            // The SwiftUI ring draws the glass (see attachGlassHost); these only keep the frames for snapshots.
            discBackground = NSView(frame: discRect)
            tabsBackground = NSView(frame: tabsRect)
            root.installRoutingShape()
        } else {
            discBackground = makeGlass(frame: discRect, radius: Ring.radius)
            tabsBackground = makeGlass(frame: tabsRect, radius: Ring.tabHeight / 2)
            root.addSubview(discBackground)
            root.addSubview(tabsBackground)
            root.addSubview(ringView)
            ringView.autoresizingMask = [.width, .height]
        }
        tabsBackground.isHidden = true
        panel.contentView = root
    }

    private func attachGlassHost() {
        guard usesGlass, glassHost == nil else { return }
        if #available(macOS 26.0, *) {
            let start = CACurrentMediaTime()
            let host = NSHostingView(rootView: GlassRingView(model: model, flattenLabels: true))
            host.frame = root.bounds
            host.autoresizingMask = [.width, .height]
            root.addSubview(host)
            glassHost = host
            glassHostBuildMS = (CACurrentMediaTime() - start) * 1000
        }
    }

    private func detachGlassHost() {
        glassHost?.removeFromSuperview()
        glassHost = nil
    }

    /// Pushes the current state into the SwiftUI glass ring.
    private func syncModel(layoutChanged: Bool = false, animated: Bool = true) {
        guard usesGlass else { return }
        let apply = {
            if layoutChanged {
                self.generation += 1
                self.model.setLayout(self.layout, generation: self.generation)
                self.model.tabs = self.pages.count > 1 ? self.pages.map(\.title) : []
                self.model.tabFrames = self.tabFrames
                self.model.page = self.pageIndex
            }
            if case .entry(let i) = self.hover { self.model.hovered = i } else { self.model.hovered = nil }
            if case .tab(let t) = self.hover { self.model.hoveredTab = t } else { self.model.hoveredTab = nil }
            self.model.centerActive = self.hover == .center && !self.stack.isEmpty
            self.model.centerText = self.centerText
        }
        if animated && layoutChanged { withAnimation(.smooth(duration: 0.32)) { apply() } } else { apply() }
    }

    private func makeGlass(frame: NSRect, radius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: frame)
            g.cornerRadius = radius
            g.style = .regular
            g.tintColor = Theme.tangerine.withAlphaComponent(0.06)
            return g
        }
        let v = NSVisualEffectView(frame: frame)
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.masksToBounds = true
        return v
    }

    // MARK: Showing / hiding

    var currentEntries: [MenuEntry] {
        if let top = stack.last { return top.entries }
        return pages.indices.contains(pageIndex) ? pages[pageIndex].entries : []
    }

    private func reset() {
        hideWork?.cancel()
        dwell?.invalidate()
        items = []; receivers = []; pages = []; pageIndex = 0; stack = []
        loaded = false; dropped = false; hover = .none; lastPoint = nil
        layout = .empty; previous = nil; transition = 1; highlights = []; tabHighlights = []; centerHighlight = 0
        let hadTabs = !tabFrames.isEmpty
        tabFrames = []
        tabsBackground.isHidden = true
        if hadTabs { routingChanged() }
    }

    /// The tab bar moved or went away: update the drag-routing area (shape layer, or the CG root's own fill).
    private func routingChanged() {
        if usesGlass { root.refreshRouting() } else { root.needsDisplay = true }
    }

    func showForDrag(at point: NSPoint) {
        reset()
        mode = .drag
        lastTriggerDown = true
        present(at: point)
    }

    func showForClick(items: [InputItem], at point: NSPoint) {
        reset()
        mode = .click
        // A trigger key still held from choosing the files is not a tap.
        lastTriggerDown = NSEvent.modifierFlags.contains(trigger)
        self.items = items
        loaded = true
        pages = Catalog.pages(for: items, settings: AppSettings.shared.engine)
        rebuild(animated: false)
        present(at: point)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(root)
    }

    private func present(at point: NSPoint) {
        let size = Ring.size
        var origin = NSPoint(x: point.x - Ring.center.x, y: point.y - Ring.center.y)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX - Ring.margin + 6), f.maxX - size.width + Ring.margin - 6)
            origin.y = min(max(origin.y, f.minY - Ring.margin + 6), f.maxY - size.height + Ring.margin - 6)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        screenCenter = NSPoint(x: origin.x + Ring.center.x, y: origin.y + Ring.center.y)
        appear = 0
        isVisible = true
        panel.alphaValue = 0
        model.shown = false
        syncModel(layoutChanged: true, animated: false)
        attachGlassHost()
        panel.orderFrontRegardless()
        startDisplayLink()
        // Next turn, so SwiftUI first renders the hidden state and then springs in. Skipped if the ring was
        // hidden again in the meantime (it would otherwise stay "shown" while off screen).
        if usesGlass { DispatchQueue.main.async { [weak self] in if let self, self.isVisible { self.model.shown = true } } }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        ringView.needsDisplay = true
    }

    func hide(animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        model.shown = false
        dwell?.invalidate()
        hideWork?.cancel()
        let finish = { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.stopDisplayLink()
            self.detachGlassHost()
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 0
            }, completionHandler: finish)
        } else {
            finish()
        }
    }

    /// Mouse released somewhere (from the drag monitor). Give a drop a moment to arrive first.
    func mouseReleased() {
        guard isVisible, mode == .drag, !dropped else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.dropped else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Tap the trigger key again to flip through pages.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let down = flags.contains(trigger)
        if down && !lastTriggerDown && isVisible && loaded { nextPage() }
        lastTriggerDown = down
    }

    func windowDidResignKey(_ notification: Notification) {
        if mode == .click { hide() }
    }

    // MARK: Content

    private func load(from pb: NSPasteboard) {
        guard !loaded else { return }
        loaded = true
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            items = urls.map { InputItem(url: $0) }
        } else if let recv = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !recv.isEmpty {
            receivers = recv
            items = recv.flatMap { r -> [InputItem] in
                (r.fileTypes.isEmpty ? ["public.data"] : r.fileTypes).map { t in
                    let type = UTType(t) ?? .data
                    let name = "Dropped Item.\(type.preferredFilenameExtension ?? "dat")"
                    return InputItem(url: FileManager.default.temporaryDirectory.appendingPathComponent(name), type: type)
                }
            }
        }
        pages = Catalog.pages(for: items, settings: AppSettings.shared.engine)
        pageIndex = 0
        stack = []
        rebuild(animated: true)
    }

    private func rebuild(animated: Bool) {
        let entries = currentEntries
        previous = animated && !layout.entries.isEmpty ? layout : nil
        layout = RingLayout.make(entries)
        highlights = Array(repeating: 0, count: entries.count)
        transition = animated ? 0 : 1
        layoutTabs()
        ringView.needsDisplay = true
        syncModel(layoutChanged: true, animated: animated)
    }

    private func layoutTabs() {
        guard pages.count > 1 else {
            let hadTabs = !tabFrames.isEmpty
            tabFrames = []
            tabsBackground.isHidden = true
            if hadTabs { routingChanged() } // drop the old tab bar from the drag-routing area
            return
        }
        let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let widths = pages.map { ($0.title as NSString).size(withAttributes: [.font: font, .kern: 0.6]).width + 22 }
        let total = widths.reduce(0, +) + 8
        var x = Ring.center.x - total / 2 + 4
        tabFrames = widths.map { w in
            defer { x += w }
            return NSRect(x: x, y: 5, width: w, height: Ring.tabHeight - 6)
        }
        tabsBackground.frame = NSRect(x: Ring.center.x - total / 2, y: 2, width: total, height: Ring.tabHeight)
        tabsBackground.isHidden = false
        routingChanged()
        if tabHighlights.count != pages.count { tabHighlights = pages.indices.map { $0 == pageIndex ? 1 : 0 } }
    }

    private func setPage(_ index: Int) {
        guard pages.indices.contains(index), index != pageIndex || !stack.isEmpty else { return }
        transitionDirection = index >= pageIndex ? 1 : -1
        pageIndex = index
        stack = []
        rebuild(animated: true)
        retarget()
    }

    private func nextPage() {
        guard pages.count > 1 else { return }
        setPage((pageIndex + 1) % pages.count)
    }

    private func push(_ title: String, _ entries: [MenuEntry]) {
        stack.append((title, entries))
        transitionDirection = 1
        rebuild(animated: true)
        retarget()
    }

    private func pop() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        transitionDirection = -1
        rebuild(animated: true)
        retarget()
    }

    /// The wedges under the cursor changed (new page or sub-ring): hover whatever is there now,
    /// so a drop without further mouse movement still lands on the visible wedge.
    private func retarget() {
        // A dwell armed for the old wedges must not fire on the new ones (e.g. a group's push
        // re-opening its own sub-ring a second time).
        dwell?.invalidate()
        dwell = nil
        hover = .none
        if let p = lastPoint { setHover(target(at: p)) }
        if hover == .none {
            // setHover had nothing to change: still drop the old highlight from both renderers.
            ringView.needsDisplay = true
            syncModel()
        }
    }

    private func track(_ p: NSPoint) {
        lastPoint = p
        setHover(target(at: p))
    }

    // MARK: Hover

    private func target(at p: NSPoint) -> Hover {
        let c = Ring.center
        let v = CGPoint(x: p.x - c.x, y: p.y - c.y)
        if hypot(v.x, v.y) < Ring.inner - 6 { return .center }
        if let i = layout.hitTest(v) { return .entry(i) }
        // The tab under the pointer wins; the slop around the tabs only catches near misses
        // (adjacent tabs touch, so the slop of one overlaps the edge of the next).
        if let t = tabFrames.firstIndex(where: { $0.contains(p) })
            ?? tabFrames.firstIndex(where: { $0.insetBy(dx: -2, dy: -4).contains(p) }) { return .tab(t) }
        return .none
    }

    private func setHover(_ new: Hover) {
        guard new != hover else { return }
        hover = new
        dwell?.invalidate()
        dwell = nil
        switch new {
        case .entry(let i):
            if layout.entries.indices.contains(i), case .group(let title, _, let children, _) = layout.entries[i] {
                dwell = after(0.45) { [weak self] in self?.push(title, children.map { .action($0) }) }
            }
        case .center:
            if !stack.isEmpty { dwell = after(0.55) { [weak self] in self?.pop() } }
        case .tab(let t):
            if t != pageIndex || !stack.isEmpty { dwell = after(0.12) { [weak self] in self?.setPage(t) } }
        case .none:
            break
        }
        ringView.needsDisplay = true
        syncModel()
    }

    private func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: seconds, repeats: false) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    var dropAction: Action? {
        guard case .entry(let i) = hover, layout.entries.indices.contains(i) else { return nil }
        switch layout.entries[i] {
        case .action(let a): return a
        case .group(_, _, _, let primary): return primary
        }
    }

    // MARK: Drag destination (forwarded by RingRootView)

    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropAction != nil else { return [] }
        let mask = sender.draggingSourceOperationMask
        for op: NSDragOperation in [.copy, .generic, .link, .move] where mask.contains(op) { return op }
        return []
    }

    func dragEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hideWork?.cancel()
        load(from: sender.draggingPasteboard)
        track(root.convert(sender.draggingLocation, from: nil))
        return operation(sender)
    }

    func dragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        track(root.convert(sender.draggingLocation, from: nil))
        return operation(sender)
    }

    func dragExited() {
        lastPoint = nil
        setHover(.none)
    }

    var canDrop: Bool { dropAction != nil }

    /// Re-targets from the actual drop point so stale hover state can never swallow a drop.
    func prepareDrop(_ sender: NSDraggingInfo) -> Bool {
        track(root.convert(sender.draggingLocation, from: nil))
        return dropAction != nil
    }

    func performDrop(_ sender: NSDraggingInfo) -> Bool {
        track(root.convert(sender.draggingLocation, from: nil))
        guard let action = dropAction else { return false }
        dropped = true
        let source: DropSource = receivers.isEmpty ? .files(items) : .promises(PromiseLoader(receivers: receivers), items)
        let point = screenCenter
        hide()
        DispatchQueue.main.async { self.onRun?(action, source, point) }
        return true
    }

    func dragEnded() {
        if mode == .drag && !dropped { hide() }
    }

    // MARK: Click mode (forwarded by RingRootView)

    func mouseMoved(to p: NSPoint) { if mode == .click { track(p) } }

    func mouseClicked(at p: NSPoint) {
        guard mode == .click else { return }
        // Remember where the pointer is (it may not have moved since the ring appeared), so a sub-ring
        // or page that opens under it hovers the wedge there, exactly like in drag mode.
        track(p)
        switch hover {
        case .entry(let i):
            if case .group(let title, _, let children, _) = layout.entries[i] {
                push(title, children.map { .action($0) })
            } else if let action = dropAction {
                dropped = true
                let point = screenCenter
                let items = self.items
                hide()
                DispatchQueue.main.async { self.onRun?(action, .files(items), point) }
            }
        case .center:
            if stack.isEmpty { hide() } else { pop() }
        case .tab(let i): setPage(i)
        case .none: hide()
        }
    }

    func keyDown(_ e: NSEvent) {
        switch e.keyCode {
        case 53: if stack.isEmpty { hide() } else { pop() }   // esc
        case 48, 124: nextPage()                               // tab, →
        case 123: if pages.count > 1 { setPage((pageIndex - 1 + pages.count) % pages.count) } // ←
        default: break
        }
    }

    // MARK: Animation

    private func startDisplayLink() {
        guard !usesGlass, displayLink == nil else { return }
        let link = ringView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = 0
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTick == 0 ? 1.0 / 60 : min(link.timestamp - lastTick, 1.0 / 20)
        lastTick = link.timestamp
        var dirty = false
        if appear < 1 {
            appear = min(1, appear + CGFloat(dt / 0.24))
            root.needsDisplay = true // the shadow scales with the disc
            dirty = true
        }
        if transition < 1 {
            transition = min(1, transition + CGFloat(dt / 0.22))
            if transition >= 1 { previous = nil }
            dirty = true
        }
        let k = min(1, CGFloat(dt) * 20)
        for i in highlights.indices {
            let goal: CGFloat = hover == .entry(i) ? 1 : 0
            let d = goal - highlights[i]
            if abs(d) > 0.002 { highlights[i] += d * k; dirty = true } else if highlights[i] != goal { highlights[i] = goal; dirty = true }
        }
        for i in tabHighlights.indices {
            let goal: CGFloat = i == pageIndex ? 1 : 0
            let d = goal - tabHighlights[i]
            if abs(d) > 0.002 { tabHighlights[i] += d * k; dirty = true } else if tabHighlights[i] != goal { tabHighlights[i] = goal; dirty = true }
        }
        let cGoal: CGFloat = (hover == .center && !stack.isEmpty) ? 1 : 0
        if abs(cGoal - centerHighlight) > 0.002 { centerHighlight += (cGoal - centerHighlight) * k; dirty = true }
        if dirty { ringView.needsDisplay = true }
    }

    var appearScale: CGFloat {
        let t = appear
        let c1: CGFloat = 1.5, c3 = c1 + 1
        let eased = 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2) // ease-out-back
        return 0.84 + 0.16 * eased
    }

    /// Text for the center pill.
    var centerText: String {
        if !loaded { return "…" }
        switch hover {
        case .entry(let i) where layout.entries.indices.contains(i):
            if case .group = layout.entries[i] { return layout.entries[i].title + " ›" }
            return layout.entries[i].title
        case .center where !stack.isEmpty: return "‹ BACK"
        case .tab(let t) where pages.indices.contains(t): return pages[t].title
        default: break
        }
        if let top = stack.last { return top.title }
        if items.isEmpty { return "NO FILES" }
        if items.count == 1 {
            if items[0].kind == .folder { return "1 FOLDER" }
            return items[0].size > 0 ? ByteFormat.string(items[0].size).uppercased() : "1 FILE"
        }
        let folders = items.reduce(0) { $0 + ($1.kind == .folder ? 1 : 0) }
        if folders == items.count { return "\(items.count) FOLDERS" }
        return folders > 0 ? "\(items.count) ITEMS" : "\(items.count) FILES"
    }
}

// MARK: - Views

/// The panel's content view: the drag destination and event target for the whole ring. It draws nothing itself:
/// on macOS 26 a RoutingShapeView under the glass takes the drags; before that, ShadowRingRootView draws.
class RingRootView: NSView {
    weak var controller: RadialMenuController?
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.dragExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.prepareDrop(sender) ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.performDrop(sender) ?? false }
    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.dragEnded() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    /// Every point inside the panel belongs to the ring (glass subviews must not swallow clicks or drags).
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseMoved(with event: NSEvent) { controller?.mouseMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { controller?.mouseClicked(at: convert(event.locationInWindow, from: nil)) }
    override func keyDown(with event: NSEvent) { controller?.keyDown(event) }

    // MARK: Drag routing

    /// macOS 26: SwiftUI draws the glass, and an invisible shape (disc + tab bar) under it makes the window server
    /// route drags over the gaps between the glass wedges to the ring. It lives in a layer-hosting subview: the
    /// render server draws it, so the app keeps no full-panel bitmap for it, shown or hidden.
    static let routesWithShapeLayer: Bool = { if #available(macOS 26.0, *) { return true } else { return false } }()
    static let routingFill = NSColor(white: 1, alpha: 0.02)
    private(set) var routing: RoutingShapeView?

    func installRoutingShape() {
        guard routing == nil else { return }
        let v = RoutingShapeView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        addSubview(v, positioned: .below, relativeTo: nil)
        routing = v
        refreshRouting()
    }

    /// Call when the tabs change.
    func refreshRouting() {
        routing?.setPath(routingPath(discRadius: Ring.reach))
    }

    /// The area that must take drags: the whole disc (as far as wedges hit-test) plus the tab bar.
    func routingPath(discRadius r: CGFloat) -> CGPath {
        let c = Ring.center
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        if let frames = controller?.tabFrames, let first = frames.first {
            let f = frames.reduce(first) { $0.union($1) }.insetBy(dx: -6, dy: -3) // hugs the glass tab bar
            path.addRoundedRect(in: f, cornerWidth: f.height / 2, cornerHeight: f.height / 2)
        }
        return path
    }
}

/// A layer-hosting view whose own CAShapeLayer is the invisible drag-routing fill.
final class RoutingShapeView: NSView {
    let shape = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        shape.fillColor = RingRootView.routingFill.cgColor
        layer = shape // set before wantsLayer: we own this layer, AppKit never draws into it
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("RoutingShapeView is built in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setPath(_ path: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
    }
}

/// The Core Graphics ring's root view (before macOS 26). A separate class so the glass ring's root doesn't
/// override draw(_:): AppKit gives any view that does a full-panel bitmap backing store.
final class ShadowRingRootView: RingRootView {
    /// Soft drop shadow around the disc (drawn outside it only, so the glass stays clear).
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let controller else { return }
        let c = Ring.center
        let s = controller.appearScale
        let r = Ring.radius * s
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.addEllipse(in: disc.insetBy(dx: 1, dy: 1))
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: NSColor(white: 0, alpha: 0.28).cgColor)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        // Invisible fill so the window server routes drags over the whole disc (gaps included) to the ring.
        ctx.setFillColor(NSColor(white: 1, alpha: 0.02).cgColor)
        ctx.fillEllipse(in: disc)
        for f in controller.tabFrames.isEmpty ? [] : [controller.tabFrames.reduce(controller.tabFrames[0]) { $0.union($1) }.insetBy(dx: -6, dy: -3)] {
            ctx.addPath(CGPath(roundedRect: f, cornerWidth: f.height / 2, cornerHeight: f.height / 2, transform: nil))
            ctx.fillPath()
        }
    }
}

final class RingView: NSView {
    weak var controller: RadialMenuController?
    override var isOpaque: Bool { false }

    // Let the root view receive drags and clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = Theme.isDark(effectiveAppearance)
        let center = Ring.center
        let scale = c.appearScale

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)

        // Rim highlight on the glass edge.
        ctx.setStrokeColor(Theme.rim(dark).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: -Ring.radius + 0.5, y: -Ring.radius + 0.5, width: Ring.radius * 2 - 1, height: Ring.radius * 2 - 1))

        let spin: CGFloat = 0.22 * c.transitionDirection
        if let prev = c.previous {
            drawWedges(prev, highlights: [], alpha: 1 - c.transition, rotation: -spin * c.transition, dark: dark)
        }
        drawWedges(c.layout, highlights: c.highlights, alpha: c.previous == nil ? 1 : c.transition,
                   rotation: c.previous == nil ? 0 : spin * (1 - c.transition), dark: dark)
        drawCenter(c, dark: dark)
        ctx.restoreGState()

        drawTabs(c, dark: dark)
    }

    private func drawWedges(_ layout: RingLayout, highlights: [CGFloat], alpha: CGFloat, rotation: CGFloat, dark: Bool) {
        guard alpha > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let base = Theme.wedge(dark)
        for (i, w) in layout.wedges.enumerated() {
            let h = i < highlights.count ? highlights[i] : 0
            let pop = 4.5 * h
            let angle = w.midAngle + rotation
            var t = CGAffineTransform(translationX: cos(angle) * pop, y: sin(angle) * pop).rotated(by: rotation)
            guard let path = w.path.copy(using: &t) else { continue }

            ctx.saveGState()
            ctx.setAlpha(alpha)
            if h > 0.01 {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10 * h, color: Theme.tangerineDeep.withAlphaComponent(0.45 * h).cgColor)
                ctx.addPath(path)
                ctx.setFillColor(RingDraw.blend(base, Theme.tangerine, h).cgColor)
                ctx.fillPath()
                ctx.restoreGState()
                // Glossy top-down gradient on the selected wedge.
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                let colors = [NSColor(white: 1, alpha: 0.22 * h).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: Ring.outer), end: CGPoint(x: 0, y: -Ring.outer), options: [])
                }
                ctx.restoreGState()
            } else {
                ctx.addPath(path)
                ctx.setFillColor(base.cgColor)
                ctx.fillPath()
            }
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(white: 1, alpha: (dark ? 0.07 : 0.55) * (1 - h)).cgColor)
            ctx.setLineWidth(0.8)
            ctx.strokePath()

            let lc = CGPoint(x: cos(angle) * (hypot(w.labelCenter.x, w.labelCenter.y) + pop),
                             y: sin(angle) * (hypot(w.labelCenter.x, w.labelCenter.y) + pop))
            let textColor = RingDraw.blend(Theme.wedgeText(dark), .white, h)
            if let icon = w.icon {
                let lineBlock = w.fontSize * 1.18 * CGFloat(w.lines.count)
                RingDraw.icon(icon, color: textColor, center: CGPoint(x: lc.x, y: lc.y + lineBlock / 2 + 3))
                RingDraw.label(w.lines, size: w.fontSize, color: textColor, at: CGPoint(x: lc.x, y: lc.y - 9))
            } else {
                RingDraw.label(w.lines, size: w.fontSize, color: textColor, at: lc)
            }
            if w.isGroup {
                ctx.setFillColor(textColor.withAlphaComponent(0.55).cgColor)
                let dotY = lc.y - (w.icon != nil ? 9 : 0) - w.fontSize * 1.18 * CGFloat(w.lines.count) / 2 - 6
                for d in -1...1 {
                    ctx.fillEllipse(in: CGRect(x: lc.x + CGFloat(d) * 5 - 1.4, y: dotY - 1.4, width: 2.8, height: 2.8))
                }
            }
            ctx.restoreGState()
        }
    }

    private func drawCenter(_ c: RadialMenuController, dark: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let core = Ring.core
        ctx.setFillColor(Theme.centerFill(dark).cgColor)
        ctx.fillEllipse(in: CGRect(x: -core, y: -core, width: core * 2, height: core * 2))
        ctx.setStrokeColor(NSColor(white: 1, alpha: dark ? 0.12 : 0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: -core + 0.5, y: -core + 0.5, width: core * 2 - 1, height: core * 2 - 1))

        let text = c.centerText
        let font = NSFont.systemFont(ofSize: text.count > 9 ? 10.5 : 12.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: 0.5,
                                                    .foregroundColor: RingDraw.blend(Theme.wedgeText(dark), .white, c.centerHighlight)]
        let size = (text as NSString).size(withAttributes: attrs)
        let pw = min(max(size.width + 26, 70), core * 2 - 6), ph: CGFloat = 30
        let pill = CGRect(x: -pw / 2, y: -ph / 2, width: pw, height: ph)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: ph / 2, cornerHeight: ph / 2, transform: nil))
        ctx.setFillColor(RingDraw.blend(Theme.wedge(dark), Theme.tangerine, c.centerHighlight).cgColor)
        ctx.fillPath()
        let drawWidth = min(size.width, pw - 12)
        (text as NSString).draw(in: CGRect(x: -drawWidth / 2, y: -size.height / 2, width: drawWidth, height: size.height), withAttributes: attrs)
    }

    private func drawTabs(_ c: RadialMenuController, dark: Bool) {
        guard c.tabFrames.count == c.pages.count, c.pages.count > 1, let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (i, frame) in c.tabFrames.enumerated() {
            let h = i < c.tabHighlights.count ? c.tabHighlights[i] : 0
            let hovered = c.hover == .tab(i)
            if h > 0.01 || hovered {
                let fill = hovered && h < 0.5 ? Theme.wedge(dark) : Theme.tangerine.withAlphaComponent(max(h, 0.2))
                ctx.addPath(CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil))
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()
            }
            let color = RingDraw.blend(Theme.wedgeText(dark), .white, h)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: color, .kern: 0.6]
            let s = (c.pages[i].title as NSString).size(withAttributes: attrs)
            (c.pages[i].title as NSString).draw(at: CGPoint(x: frame.midX - s.width / 2, y: frame.midY - s.height / 2), withAttributes: attrs)
        }
    }
}

// MARK: - Debug presentation (used by --render-glass)

extension RadialMenuController {
    func debugShow(items: [InputItem], page: Int, hover hoverIndex: Int?) {
        showForClick(items: items, at: NSPoint(x: (NSScreen.main?.frame.midX ?? 700), y: (NSScreen.main?.frame.midY ?? 450)))
        if page > 0 { for _ in 0..<page { keyDown(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!) } }
        if let h = hoverIndex, layout.wedges.indices.contains(h) {
            let w = layout.wedges[h]
            let r = (Ring.inner + Ring.outer) / 2
            mouseMoved(to: NSPoint(x: Ring.center.x + cos(w.midAngle) * r, y: Ring.center.y + sin(w.midAngle) * r))
        }
    }

    var debugContentView: NSView? { panel.contentView }

    /// Fills `model` with a static demo (welcome window) without showing the panel.
    func prepareDemo(items: [InputItem], hover hoverIndex: Int?) {
        reset()
        self.items = items
        loaded = true
        pages = Catalog.pages(for: items, settings: AppSettings.shared.engine)
        rebuild(animated: false)
        if let h = hoverIndex, layout.entries.indices.contains(h) { hover = .entry(h) }
        syncModel()
        model.shown = true
    }
}

// MARK: - Offscreen rendering (welcome illustration, screenshots for docs and tests)

extension RadialMenuController {
    func snapshot(items: [InputItem], page: Int = 0, hover hoverIndex: Int? = nil, dark: Bool = false, scale: CGFloat = 2) -> NSImage {
        reset()
        self.items = items
        loaded = true
        pages = Catalog.pages(for: items, settings: AppSettings.shared.engine)
        pageIndex = max(0, min(page, pages.count - 1))
        rebuild(animated: false)
        appear = 1
        if let h = hoverIndex, highlights.indices.contains(h) {
            hover = .entry(h)
            highlights[h] = 1
        }
        tabHighlights = pages.indices.map { $0 == pageIndex ? 1 : 0 }

        let size = Ring.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        ringView.appearance = appearance
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            let ctx = NSGraphicsContext.current!.cgContext
            // Stand-in for the live glass: a soft frosted disc with a shadow.
            let c = Ring.center
            let disc = CGRect(x: c.x - Ring.radius, y: c.y - Ring.radius, width: Ring.radius * 2, height: Ring.radius * 2)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: NSColor(white: 0, alpha: 0.25).cgColor)
            ctx.setFillColor((dark ? NSColor(srgbRed: 0.16, green: 0.13, blue: 0.12, alpha: 0.92) : NSColor(srgbRed: 1, green: 0.97, blue: 0.94, alpha: 0.9)).cgColor)
            ctx.fillEllipse(in: disc)
            ctx.restoreGState()
            if pages.count > 1 {
                let f = tabsBackground.frame
                ctx.addPath(CGPath(roundedRect: f, cornerWidth: f.height / 2, cornerHeight: f.height / 2, transform: nil))
                ctx.setFillColor((dark ? NSColor(white: 0.18, alpha: 0.92) : NSColor(white: 1, alpha: 0.9)).cgColor)
                ctx.fillPath()
            }
            ringView.draw(ringView.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
