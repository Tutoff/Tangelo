import AppKit
import SwiftUI
import TangeloCore

let app = NSApplication.shared
let args = CommandLine.arguments

// Debug: render the ring offscreen.  Tangelo --render-ring out.png [--page N] [--hover N] [--dark] file...
if let i = args.firstIndex(of: "--render-ring"), i + 1 < args.count {
    let out = URL(fileURLWithPath: args[i + 1])
    var page = 0, hover: Int? = nil, files: [String] = []
    var j = i + 2
    while j < args.count {
        switch args[j] {
        case "--page": page = Int(args[j + 1]) ?? 0; j += 2
        case "--hover": hover = Int(args[j + 1]); j += 2
        case "--dark": j += 1
        default: files.append(args[j]); j += 1
        }
    }
    let image = RadialMenuController().snapshot(items: files.map { InputItem(url: URL(fileURLWithPath: $0)) },
                                                page: page, hover: hover, dark: args.contains("--dark"))
    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out)
    }
    exit(0)
}

// Debug: render a tool window offscreen.  Tangelo --render-tool crop|addBackground|... file out.png
if let i = args.firstIndex(of: "--render-tool"), i + 3 < args.count, let tool = ToolKind(rawValue: args[i + 1]) {
    let file = URL(fileURLWithPath: args[i + 2]), out = URL(fileURLWithPath: args[i + 3])
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        ToolPresenter.shared.present(tool, item: InputItem(url: file))
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        let window = NSApp.windows.first(where: { $0.title.contains("—") })
        if let window, let view = window.contentView {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                do { try rep.representation(using: .png, properties: [:])?.write(to: out); print("wrote", out.path) }
                catch { print("write failed:", error) }
            } else { print("no bitmap rep for", view.bounds) }
        }
    }
    exit(0)
}

// Debug: render the Liquid Glass ring in a real window and capture it.  Tangelo --render-glass out.png [--page N] [--hover N] file...
if let i = args.firstIndex(of: "--render-glass"), i + 1 < args.count {
    app.setActivationPolicy(.accessory)
    var page = 0, hover: Int? = nil, files: [String] = []
    var j = i + 2
    while j < args.count {
        switch args[j] {
        case "--page": page = Int(args[j + 1]) ?? 0; j += 2
        case "--hover": hover = Int(args[j + 1]); j += 2
        case "--solid": j += 1
        default: files.append(args[j]); j += 1
        }
    }
    MainActor.assumeIsolated {
        let ring = RadialMenuController()
        ring.model.debugSolid = args.contains("--solid")
        ring.debugShow(items: files.map { InputItem(url: URL(fileURLWithPath: $0)) }, page: page, hover: hover)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        if let view = ring.debugContentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        }
    }
    exit(0)
}

// Debug: render the welcome window offscreen.  Tangelo --render-welcome out.png
if let i = args.firstIndex(of: "--render-welcome"), i + 1 < args.count {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let d = AppDelegate()
        d.showWelcome()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        if let view = NSApp.windows.first(where: { $0.title == "Welcome to Tangelo" })?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        }
    }
    exit(0)
}

// Debug: memory profile of a typical session.  Tangelo --mem-test <fixtures folder>
if let i = args.firstIndex(of: "--mem-test"), i + 1 < args.count {
    app.setActivationPolicy(.accessory)
    let code = MainActor.assumeIsolated { MemTest.run(fixtures: URL(fileURLWithPath: args[i + 1])) }
    exit(code)
}

if let i = args.firstIndex(of: "--leak-test"), i + 1 < args.count {
    app.setActivationPolicy(.accessory)
    let code = MainActor.assumeIsolated { LeakTest.run(fixtures: URL(fileURLWithPath: args[i + 1])) }
    exit(code)
}

// Debug: scripted drag test of the ring.  Tangelo --self-test file...
if let i = args.firstIndex(of: "--self-test") {
    let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
    app.setActivationPolicy(.accessory)
    let code = MainActor.assumeIsolated { SelfTest.run(files: files) }
    exit(code)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
