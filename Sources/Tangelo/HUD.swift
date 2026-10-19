import AppKit
import SwiftUI

/// The little "Converting to JPG · 1 of 1 saved" panel.
final class HUDModel: ObservableObject {
    enum Phase { case running, done, failed }
    @Published var title: String
    @Published var subtitle: String
    @Published var progress: Double? = nil
    @Published var phase: Phase = .running
    @Published var outputs: [URL] = []
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button {
                    model.phase == .running ? model.onCancel?() : model.onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.09)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(model.phase == .running ? "Cancel" : "Close")

                switch model.phase {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 15))
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 14))
                case .running:
                    EmptyView()
                }

                Text(model.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.phase == .done && !model.outputs.isEmpty {
                    Button("Show") {
                        NSWorkspace.shared.activateFileViewerSelecting(model.outputs)
                        model.onClose?()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                }
            }
            Text(model.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 30)
            if model.phase == .running {
                ProgressTrack(value: model.progress)
                    .frame(height: 5)
                    .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 330, alignment: .leading)
        .modifier(GlassCard(cornerRadius: 20))
        .onHover { model.onHover?($0) }
    }
}

struct ProgressTrack: View {
    let value: Double?
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if let value {
                    Capsule()
                        .fill(LinearGradient(colors: [Color(nsColor: Theme.tangerineLight), Theme.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(5, geo.size.width * value))
                        .animation(.easeOut(duration: 0.25), value: value)
                } else {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { phase = 0.7 }
                        }
                }
            }
            .clipShape(Capsule())
        }
    }
}

/// Liquid Glass on macOS 26, frosted material before that.
struct GlassCard: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
        }
    }
}

/// Hosting view whose controls work on the first click even though the panel never becomes key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HUDController {
    let model: HUDModel
    let panel: NSPanel
    private var dismissWork: DispatchWorkItem?
    private var hovering = false
    var onGone: ((HUDController) -> Void)?

    init(model: HUDModel) {
        self.model = model
        let host = FirstClickHostingView(rootView: HUDView(model: model).padding(16))
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = host
        model.onClose = { [weak self] in self?.dismiss() }
        model.onHover = { [weak self] inside in
            guard let self else { return }
            self.hovering = inside
            if inside {
                // The pointer arrived after the job finished: hold the countdown that `finish` started.
                self.dismissWork?.cancel()
                self.dismissWork = nil
            } else {
                self.scheduleDismissIfFinished()
            }
        }
    }

    var size: NSSize { panel.contentView?.fittingSize ?? panel.frame.size }

    func show(at origin: NSPoint) {
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func move(to origin: NSPoint) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    func finish(phase: HUDModel.Phase, title: String, subtitle: String, outputs: [URL]) {
        model.phase = phase
        model.title = title
        model.subtitle = subtitle
        model.outputs = outputs
        model.progress = 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.setContentSize(self.size)
            self.scheduleDismissIfFinished()
        }
    }

    private func scheduleDismissIfFinished() {
        guard model.phase != .running, !hovering else { return }
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (model.phase == .failed ? 7 : 3.2), execute: work)
    }

    func dismiss() {
        dismissWork?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.contentView = nil
            self.panel.close()
            self.onGone?(self)
        })
    }
}

/// Stacks HUDs near where the ring was used.
final class HUDManager {
    static let shared = HUDManager()
    private var huds: [(HUDController, NSPoint)] = []

    func present(_ model: HUDModel, near point: NSPoint) -> HUDController {
        let hud = HUDController(model: model)
        hud.onGone = { [weak self] h in
            self?.huds.removeAll { $0.0 === h }
            self?.relayout()
        }
        huds.append((hud, point))
        hud.show(at: origin(for: hud, index: huds.count - 1, anchor: point))
        return hud
    }

    private func origin(for hud: HUDController, index: Int, anchor: NSPoint) -> NSPoint {
        let size = hud.size
        var y = anchor.y - size.height / 2
        for i in 0..<index { y -= huds[i].0.size.height - 20 }
        var o = NSPoint(x: anchor.x - size.width / 2, y: y)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            o.x = min(max(o.x, f.minX), f.maxX - size.width)
            o.y = min(max(o.y, f.minY), f.maxY - size.height)
        }
        return o
    }

    private func relayout() {
        for (i, entry) in huds.enumerated() {
            entry.0.move(to: origin(for: entry.0, index: i, anchor: huds.first?.1 ?? entry.1))
        }
    }
}
