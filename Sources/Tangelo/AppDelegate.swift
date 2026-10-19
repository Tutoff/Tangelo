import AppKit
import Combine
import SwiftUI
import TangeloCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let settings = AppSettings.shared
    let monitor = DragMonitor()
    let ring = RadialMenuController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var demoRing: RadialMenuController?

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === welcomeWindow { welcomeWindow = nil; demoRing = nil }
        if w === settingsWindow { settingsWindow = nil }
        DispatchQueue.main.async {
            w.contentViewController = nil
            w.contentView = nil
        }
    }
    private var recentMenu = NSMenu(title: "Recent")
    private var enabledItem: NSMenuItem!
    private var hintItem: NSMenuItem!
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        ring.onRun = { [weak self] action, source, point in self?.run(action, source: source, near: point) }
        monitor.onTrigger = { [weak self] point in
            guard let self else { return }
            self.ring.trigger = self.settings.trigger.flags
            self.ring.showForDrag(at: point)
            self.monitor.ringDidShow()
        }
        monitor.onMouseUp = { [weak self] in self?.ring.mouseReleased() }
        monitor.onPoll = { [weak self] flags in self?.ring.modifiersChanged(flags) }
        monitor.isRingVisible = { [weak self] in self?.ring.isVisible ?? false }

        settings.$enabled.sink { [weak self] on in
            self?.monitor.enabled = on
            self?.enabledItem?.state = on ? .on : .off
        }.store(in: &bag)
        settings.$trigger.sink { [weak self] t in
            self?.monitor.trigger = t.flags
            self?.ring.trigger = t.flags
            self?.hintItem?.title = "Hold \(t.symbol) while dragging files"
        }.store(in: &bag)

        monitor.start()
        if settings.isFirstLaunch {
            settings.isFirstLaunch = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showWelcome() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching the app again from Finder/Spotlight opens the guide.
        showWelcome()
        return false
    }

    func run(_ action: Action, source: DropSource, near point: NSPoint) {
        if let tool = action.tool {
            ToolPresenter.shared.open(tool, source: source, near: point)
        } else {
            JobRunner.shared.run(action, source: source, near: point)
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.toolTip = "Tangelo"

        let menu = NSMenu()
        let title = NSMenuItem(title: "Tangelo", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "Tangelo", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(title)
        hintItem = NSMenuItem(title: "Hold \(settings.trigger.symbol) while dragging files", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.addItem(.separator())

        let convert = NSMenuItem(title: "Convert Files…", action: #selector(chooseFiles), keyEquivalent: "o")
        convert.target = self
        menu.addItem(convert)
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())

        enabledItem = NSMenuItem(title: "Ring Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = settings.enabled ? .on : .off
        menu.addItem(enabledItem)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let help = NSMenuItem(title: "How to Use Tangelo", action: #selector(showWelcome), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tangelo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let paths = settings.recents.filter { FileManager.default.fileExists(atPath: $0) }
        if paths.isEmpty {
            let none = NSMenuItem(title: "No recent files", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for p in paths {
            let url = URL(fileURLWithPath: p)
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: p)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = p
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func clearRecents() { settings.recents = [] }

    @objc private func toggleEnabled() { settings.enabled.toggle() }

    @objc private func chooseFiles() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose files to convert or edit"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let items = panel.urls.map { InputItem(url: $0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.ring.trigger = self.settings.trigger.flags
            self.ring.showForClick(items: items, at: NSEvent.mouseLocation)
            self.monitor.ringDidShow()
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Tangelo Settings"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showWelcome() {
        if welcomeWindow == nil {
            let sample = Self.sampleFile()
            let demoItems = [InputItem(url: sample ?? URL(fileURLWithPath: "/tmp/photo.jpg"))]
            let ringImage = RadialMenuController().snapshot(items: demoItems, hover: 3, dark: Theme.isDark(NSApp.effectiveAppearance))
            let demo = RadialMenuController()
            demo.prepareDemo(items: demoItems, hover: 3)
            demoRing = demo
            final class Box { weak var window: NSWindow? }
            let box = Box()
            let view = WelcomeView(ring: ringImage, ringModel: demo.model, sample: sample,
                                   openSettings: { [weak self] in self?.showSettings() },
                                   close: { box.window?.close() })
                .background(ToolBackground())
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.title = "Welcome to Tangelo"
            w.isReleasedWhenClosed = false
            w.delegate = self
            box.window = w
            w.layoutIfNeeded()
            w.center()
            welcomeWindow = w
        }
        NSApp.activate()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    /// A sample photo to try the ring with, kept in Application Support.
    static func sampleFile() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tangelo", isDirectory: true) else { return nil }
        let url = support.appendingPathComponent("Sample Photo.jpg")
        if fm.fileExists(atPath: url.path) { return url }
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        let w = 1600, h = 1100
        guard let ctx = ImageKit.makeContext(width: w, height: h) else { return nil }
        let colors = [CGColor(srgbRed: 1, green: 0.62, blue: 0.27, alpha: 1), CGColor(srgbRed: 0.93, green: 0.29, blue: 0.37, alpha: 1),
                      CGColor(srgbRed: 0.42, green: 0.25, blue: 0.62, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: ImageKit.sRGB, colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 0.95))
        ctx.fillEllipse(in: CGRect(x: 980, y: 520, width: 360, height: 360))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.1, blue: 0.25, alpha: 0.55))
        let hills = CGMutablePath()
        hills.move(to: CGPoint(x: 0, y: 0))
        hills.addLine(to: CGPoint(x: 0, y: 330))
        hills.addCurve(to: CGPoint(x: 1600, y: 280), control1: CGPoint(x: 500, y: 520), control2: CGPoint(x: 1000, y: 120))
        hills.addLine(to: CGPoint(x: 1600, y: 0))
        ctx.addPath(hills)
        ctx.fillPath()
        guard let img = ctx.makeImage() else { return nil }
        try? ImageKit.write(img, to: url, format: .jpg, quality: 0.9, settings: EngineSettings())
        return url
    }

    /// Template menu-bar icon: a citrus slice / radial menu.
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.set()
            let outer = NSBezierPath(ovalIn: NSRect(x: c.x - 7.6, y: c.y - 7.6, width: 15.2, height: 15.2))
            outer.lineWidth = 1.6
            outer.stroke()
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 + .pi / 6
                let p = NSBezierPath()
                p.move(to: NSPoint(x: c.x + cos(a) * 3.4, y: c.y + sin(a) * 3.4))
                p.line(to: NSPoint(x: c.x + cos(a) * 6.9, y: c.y + sin(a) * 6.9))
                p.lineWidth = 1.3
                p.lineCapStyle = .round
                p.stroke()
            }
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.9, y: c.y - 1.9, width: 3.8, height: 3.8)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
