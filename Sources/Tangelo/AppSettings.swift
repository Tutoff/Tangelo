import AppKit
import Combine
import ServiceManagement
import TangeloCore

enum TriggerKey: String, CaseIterable, Identifiable {
    case shift, control, shiftControl
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .shiftControl: return "⇧⌃ Shift + Control"
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .shiftControl: return [.shift, .control]
        }
    }
    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .control: return "⌃"
        case .shiftControl: return "⇧⌃"
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var trigger: TriggerKey { didSet { d.set(trigger.rawValue, forKey: "trigger") } }
    @Published var quality: Double { didSet { d.set(quality, forKey: "quality") } }
    @Published var pdfDPI: Double { didSet { d.set(pdfDPI, forKey: "pdfDPI") } }
    @Published var keepLocation: Bool { didSet { d.set(keepLocation, forKey: "keepLocation") } }
    @Published var useCustomFolder: Bool { didSet { d.set(useCustomFolder, forKey: "useCustomFolder") } }
    @Published var customFolder: URL? { didSet { d.set(customFolder?.path, forKey: "customFolder") } }
    @Published var revealInFinder: Bool { didSet { d.set(revealInFinder, forKey: "revealInFinder") } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "playSound") } }
    @Published var recents: [String] { didSet { d.set(recents, forKey: "recents") } }
    @Published var launchAtLogin: Bool = false

    private init() {
        d.register(defaults: ["enabled": true, "trigger": TriggerKey.shift.rawValue, "quality": 0.85, "pdfDPI": 200.0,
                              "keepLocation": true, "useCustomFolder": false, "revealInFinder": false, "playSound": true])
        enabled = d.bool(forKey: "enabled")
        trigger = TriggerKey(rawValue: d.string(forKey: "trigger") ?? "") ?? .shift
        quality = d.double(forKey: "quality")
        pdfDPI = d.double(forKey: "pdfDPI")
        keepLocation = d.bool(forKey: "keepLocation")
        useCustomFolder = d.bool(forKey: "useCustomFolder")
        customFolder = d.string(forKey: "customFolder").map { URL(fileURLWithPath: $0) }
        revealInFinder = d.bool(forKey: "revealInFinder")
        playSound = d.bool(forKey: "playSound")
        recents = d.stringArray(forKey: "recents") ?? []
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var engine: EngineSettings {
        var s = EngineSettings()
        s.quality = quality
        s.pdfDPI = pdfDPI
        s.keepLocation = keepLocation
        if useCustomFolder, let f = customFolder { s.outputFolder = f }
        return s
    }

    func addRecent(_ urls: [URL]) {
        var list = recents
        for u in urls.reversed() {
            list.removeAll { $0 == u.path }
            list.insert(u.path, at: 0)
        }
        recents = Array(list.prefix(12))
    }

    /// Registers/unregisters the app as a login item. Returns an error message on failure.
    @discardableResult
    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return error.localizedDescription
        }
    }

    var isFirstLaunch: Bool {
        get { !d.bool(forKey: "welcomed") }
        set { d.set(!newValue, forKey: "welcomed") }
    }
}
