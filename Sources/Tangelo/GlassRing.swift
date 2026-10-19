import SwiftUI
import TangeloCore

/// What the Liquid Glass ring shows. The controller owns it; hit-testing stays in AppKit.
final class RingModel: ObservableObject {
    struct Wedge: Identifiable {
        let id: String           // changes with the layout so labels cross-fade
        let slot: Int            // stable glass identity → segments morph between pages
        let lines: [String]
        let fontSize: CGFloat
        let symbol: String?
        let isGroup: Bool
        let path: CGPath         // disc-centered, y up
        let midAngle: CGFloat
        let labelCenter: CGPoint // disc-centered, y up
    }

    @Published var wedges: [Wedge] = []
    @Published var hovered: Int?
    @Published var centerText = ""
    @Published var centerActive = false
    @Published var tabs: [String] = []
    @Published var tabFrames: [CGRect] = []   // ring-view coordinates, y up
    @Published var page = 0
    @Published var hoveredTab: Int?
    @Published var shown = false
    /// Debug: draw the glass shapes as solid fills (offscreen captures can't show real glass).
    var debugSolid = false

    func setLayout(_ layout: RingLayout, generation: Int) {
        wedges = layout.wedges.enumerated().map { i, w in
            Wedge(id: "\(generation)-\(i)", slot: i, lines: w.lines, fontSize: w.fontSize, symbol: layout.entries[i].symbol,
                  isGroup: w.isGroup, path: w.path, midAngle: w.midAngle, labelCenter: w.labelCenter)
        }
    }
}

/// Swift shape for one precomputed wedge path (flipped into SwiftUI's y-down space).
/// CGPath is immutable, so sharing it across threads is safe.
struct WedgeShape: Shape, @unchecked Sendable {
    let path: CGPath
    func path(in rect: CGRect) -> Path {
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: 1, y: -1)
        return Path(path.copy(using: &t) ?? path)
    }
}

@available(macOS 26.0, *)
extension View {
    /// Liquid Glass, or a flat stand-in when debugging layout offscreen.
    @ViewBuilder
    func ringGlass(_ glass: Glass, tint: Color, in shape: some Shape, solid: Bool) -> some View {
        if solid { self.background(shape.fill(tint.opacity(0.9))) } else { self.glassEffect(glass, in: shape) }
    }
}

@available(macOS 26.0, *)
struct GlassRingView: View {
    @ObservedObject var model: RingModel
    /// Draw the labels in one offscreen pass (the ring panel). Drawn directly, text that moves through the
    /// ring's page, hover and appear animations leaves glyph bitmaps for every intermediate frame in the
    /// process-wide CoreGraphics glyph cache, so the heap kept growing with every show.
    var flattenLabels = false
    @Environment(\.colorScheme) private var scheme
    @Namespace private var glass

    private let size = Ring.size
    private var center: CGPoint { CGPoint(x: Ring.center.x, y: size.height - Ring.center.y) }
    private var disc: CGFloat { Ring.radius * 2 }

    private var restTint: Color {
        scheme == .dark ? Color(red: 0.16, green: 0.11, blue: 0.08).opacity(0.35) : Color(red: 1, green: 0.86, blue: 0.74).opacity(0.38)
    }

    var body: some View {
        ZStack {
            GlassEffectContainer(spacing: 2) {
                ZStack {
                    ForEach(model.wedges) { w in
                        let hot = model.hovered == w.slot
                        Color.clear
                            .frame(width: disc, height: disc)
                            .ringGlass(hot ? .regular.tint(Theme.accent.opacity(0.92)) : .regular.tint(restTint),
                                       tint: hot ? Theme.accent : Color(red: 1, green: 0.86, blue: 0.74), in: WedgeShape(path: w.path), solid: model.debugSolid)
                            .glassEffectID(w.slot, in: glass)
                            .offset(pop(w, hot ? 6 : 0))
                            .position(center)
                    }
                    Color.clear
                        .frame(width: Ring.core * 2, height: Ring.core * 2)
                        .ringGlass(.regular.tint(Theme.accent.opacity(model.centerActive ? 0.9 : 0.2)), tint: Theme.accent.opacity(0.35), in: Circle(), solid: model.debugSolid)
                        .glassEffectID("center", in: glass)
                        .position(center)
                    if model.tabs.count > 1, let bar = tabBar {
                        Color.clear
                            .frame(width: bar.width, height: bar.height)
                            .ringGlass(.regular, tint: Color.gray.opacity(0.25), in: Capsule(), solid: model.debugSolid)
                            .glassEffectID("tabs", in: glass)
                            .position(x: bar.midX, y: bar.midY)
                        if model.tabFrames.indices.contains(model.page) {
                            let f = swiftRect(model.tabFrames[model.page])
                            Color.clear
                                .frame(width: f.width, height: f.height)
                                .ringGlass(.regular.tint(Theme.accent.opacity(0.95)), tint: Theme.accent, in: Capsule(), solid: model.debugSolid)
                                .glassEffectID("tab-selection", in: glass)
                                .position(x: f.midX, y: f.midY)
                        }
                    }
                }
            }

            // Labels sit above the glass.
            if flattenLabels {
                labels.drawingGroup()
            } else {
                labels
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(model.shown ? 1 : 0.84)
        .opacity(model.shown ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: model.shown)
        .animation(.spring(response: 0.26, dampingFraction: 0.74), value: model.hovered)
        .animation(.smooth(duration: 0.3), value: model.page)
        .animation(.smooth(duration: 0.2), value: model.centerActive)
        .allowsHitTesting(false)
    }

    private var labels: some View {
        ZStack {
            ForEach(model.wedges) { w in
                label(w, hot: model.hovered == w.slot)
                    .offset(pop(w, model.hovered == w.slot ? 6 : 0))
                    .position(x: center.x + w.labelCenter.x, y: center.y - w.labelCenter.y)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            Text(model.centerText)
                .font(.system(size: model.centerText.count > 9 ? 10.5 : 12.5, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(model.centerActive ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: Ring.core * 2 - 14)
                .contentTransition(.opacity)
                .position(center)
            ForEach(Array(model.tabs.enumerated()), id: \.offset) { i, title in
                if model.tabFrames.indices.contains(i) {
                    let f = swiftRect(model.tabFrames[i])
                    Text(title)
                        .font(.system(size: 10.5, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(i == model.page ? Color.white : (model.hoveredTab == i ? Theme.accent : Color.primary))
                        .position(x: f.midX, y: f.midY)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var tabBar: CGRect? {
        guard let first = model.tabFrames.first, let last = model.tabFrames.last else { return nil }
        return swiftRect(first.union(last)).insetBy(dx: -4, dy: -3)
    }

    private func swiftRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
    }

    private func pop(_ w: RingModel.Wedge, _ distance: CGFloat) -> CGSize {
        CGSize(width: cos(w.midAngle) * distance, height: -sin(w.midAngle) * distance)
    }

    @ViewBuilder
    private func label(_ w: RingModel.Wedge, hot: Bool) -> some View {
        VStack(spacing: 3) {
            if let s = w.symbol {
                Image(systemName: s).font(.system(size: model.wedges.count > 8 ? 14 : 16, weight: .semibold))
            }
            ForEach(w.lines, id: \.self) { line in
                Text(line).font(.system(size: w.fontSize, weight: .bold)).kerning(w.fontSize * 0.04)
            }
            if w.isGroup {
                HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 2.8, height: 2.8) } }
                    .opacity(0.55)
                    .padding(.top, 1)
            }
        }
        .foregroundStyle(hot ? Color.white : Color.primary.opacity(0.88))
        .shadow(color: hot ? .black.opacity(0.18) : .clear, radius: 2, y: 1)
        .fixedSize()
    }
}
