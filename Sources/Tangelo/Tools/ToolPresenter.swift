import AppKit
import SwiftUI
import TangeloCore

/// Opens the interactive tool windows (Crop, Add BG, Annotate, Redact, Edit, Metadata, Resize, Trim, PDF passwords).
@MainActor
final class ToolPresenter: NSObject, NSWindowDelegate {
    static let shared = ToolPresenter()
    private var windows: [NSWindow] = []

    func open(_ tool: ToolKind, source: DropSource, near point: NSPoint) {
        Task { @MainActor in
            do {
                let items = try await JobRunner.shared.resolve(source)
                guard let item = items.first else { return }
                present(tool, item: item)
            } catch {
                let model = HUDModel(title: "Couldn't open", subtitle: error.localizedDescription)
                HUDManager.shared.present(model, near: point).finish(phase: .failed, title: "Couldn't open", subtitle: error.localizedDescription, outputs: [])
            }
        }
    }

    private final class WindowBox { weak var window: NSWindow? }

    func present(_ tool: ToolKind, item: InputItem) {
        let box = WindowBox()
        let close: () -> Void = { box.window?.close() }
        let name = item.url.lastPathComponent
        let content: AnyView
        let title: String
        switch tool {
        case .crop: title = "Crop Image"; content = AnyView(CropToolView(item: item, close: close))
        case .addBackground: title = "Add Background"; content = AnyView(BackgroundToolView(item: item, close: close))
        case .annotate: title = "Annotate"; content = AnyView(AnnotateToolView(item: item, close: close))
        case .redact: title = "Redact"; content = AnyView(RedactToolView(item: item, close: close))
        case .edit: title = "Edit Image"; content = AnyView(EditToolView(item: item, close: close))
        case .metadata: title = "Metadata"; content = AnyView(MetadataToolView(item: item, close: close))
        case .resize: title = "Resize"; content = AnyView(ResizeToolView(item: item, close: close))
        case .trim: title = "Trim"; content = AnyView(TrimToolView(item: item, close: close))
        case .pdfProtect: title = "Protect PDF"; content = AnyView(PasswordToolView(item: item, mode: .protect, close: close))
        case .pdfUnlock: title = "Unlock PDF"; content = AnyView(PasswordToolView(item: item, mode: .unlock, close: close))
        }
        // The hosting controller sizes the window to the SwiftUI content's ideal size.
        let controller = NSHostingController(rootView: content.background(ToolBackground()))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        box.window = window
        window.title = "\(title) — \(name)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.layoutIfNeeded()
        window.center()
        window.level = .floating
        windows.append(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === w }
        // Release the SwiftUI hierarchy (preview images, Core Image caches) right away.
        DispatchQueue.main.async {
            w.contentViewController = nil
            w.contentView = nil
            EditToolView.ciContext.clearCaches()
        }
    }

    /// Center of the frontmost tool window, for placing the HUD.
    static func hudAnchor() -> NSPoint {
        if let f = NSApp.keyWindow?.frame { return NSPoint(x: f.midX, y: f.midY) }
        let m = NSEvent.mouseLocation
        return m
    }
}

// MARK: - Shared helpers

/// A preview-sized copy of an image plus its full pixel size.
/// Load with `PreviewImage.decode` (Theme.swift), which bypasses CoreGraphics' image-data cache.
struct PreviewImage {
    let cg: CGImage
    let fullSize: CGSize
    /// preview pixels per full-resolution pixel
    var scale: CGFloat { CGFloat(cg.width) / fullSize.width }
    var nsImage: NSImage { NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
    /// SwiftUI image backed directly by the CGImage (avoids NSImage rendition caching).
    var image: Image { Image(decorative: cg, scale: 1) }
}

extension CGImage {
    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }
}

/// Fits an image of `size` into `box`, returning the drawn rect.
func aspectFit(_ size: CGSize, in box: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else { return .zero }
    let s = min(box.width / size.width, box.height / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
}

struct LoadingView: View {
    var body: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
