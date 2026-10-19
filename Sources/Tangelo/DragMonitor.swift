import AppKit

/// Detects "the user is dragging files while holding the trigger key" anywhere on screen.
///
/// Uses global mouse monitors (no Accessibility permission needed) plus the drag pasteboard's
/// change count: a new drag session bumps it. File contents are only read once the drag
/// enters Tangelo's own window.
final class DragMonitor {
    var onTrigger: ((NSPoint) -> Void)?
    var onMouseUp: (() -> Void)?
    /// Called on every poll while the ring is visible (modifier tracking for page switching).
    var onPoll: ((NSEvent.ModifierFlags) -> Void)?
    var isRingVisible: () -> Bool = { false }

    private var monitors: [Any] = []
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var changeCountAtMouseDown = 0
    private var triggeredThisDrag = false
    private var timer: Timer?
    private var mouseIsDown = false

    var trigger: NSEvent.ModifierFlags = .shift
    var enabled = true

    func start() {
        stop()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in self?.mouseDown() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in self?.poll() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in self?.poll() }) {
            monitors.append(m)
        }
        // Drags that start inside Tangelo's own windows (e.g. the sample photo in the welcome window).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in self?.mouseDown(); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] e in self?.poll(); return e }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func mouseDown() {
        changeCountAtMouseDown = dragPasteboard.changeCount
        triggeredThisDrag = false
        mouseIsDown = true
        startPolling()
    }

    private func startPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let flags = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])
        if isRingVisible() { onPoll?(flags) }

        if !buttonDown {
            if mouseIsDown {
                mouseIsDown = false
                onMouseUp?()
            }
            if !isRingVisible() { stopPolling() }
            return
        }
        guard enabled, !triggeredThisDrag, !isRingVisible() else { return }
        // A new drag session started since the button went down?
        guard dragPasteboard.changeCount != changeCountAtMouseDown else { return }
        guard flags.contains(trigger) else { return }
        guard draggingFiles() else { return }
        triggeredThisDrag = true
        onTrigger?(NSEvent.mouseLocation)
    }

    /// Checks only the pasteboard's type list (not its contents).
    private func draggingFiles() -> Bool {
        guard let types = dragPasteboard.types else { return false }
        let fileTypes: Set<String> = [
            NSPasteboard.PasteboardType.fileURL.rawValue, "NSFilenamesPboardType",
            "com.apple.pasteboard.promised-file-url", "com.apple.NSFilePromiseItemMetaData",
            "Apple files promise pasteboard type", "com.apple.pasteboard.promised-file-content-type",
        ]
        return types.contains { fileTypes.contains($0.rawValue) }
    }

    /// Keeps polling while the ring is open (it may stay open after the drag ends in click mode).
    func ringDidShow() { startPolling() }
}
