import CoreImage
import SwiftUI
import TangeloCore

struct EditToolView: View {
    let item: InputItem
    let close: () -> Void

    @State private var preview: PreviewImage?
    @State private var adj = ImageRender.Adjustments()
    @State private var rendered: CGImage?
    @State private var thumbs: [String: CGImage] = [:]

    nonisolated(unsafe) static let ciContext = CIContext(options: [.cacheIntermediates: false])

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    Checkerboard()
                    if let img = rendered ?? preview?.cg {
                        Image(decorative: img, scale: 1).resizable().interpolation(.high).scaledToFit().padding(8)
                    } else {
                        LoadingView()
                    }
                }
                .frame(width: 470, height: 440)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    section("Adjust")
                    SliderRow(title: "Exposure", value: $adj.exposure, range: -2...2, unit: "", format: signed)
                    SliderRow(title: "Brightness", value: $adj.brightness, range: -0.4...0.4, unit: "", format: { signed($0 * 100) })
                    SliderRow(title: "Contrast", value: $adj.contrast, range: 0.5...1.5, unit: "%", format: { String(Int(($0 * 100).rounded())) })
                    SliderRow(title: "Saturation", value: $adj.saturation, range: 0...2, unit: "%", format: { String(Int(($0 * 100).rounded())) })
                    SliderRow(title: "Warmth", value: $adj.warmth, range: -1...1, unit: "", format: { signed($0 * 100) })
                    SliderRow(title: "Sharpen", value: $adj.sharpness, range: 0...1, unit: "%", format: { String(Int(($0 * 100).rounded())) })
                    SliderRow(title: "Vignette", value: $adj.vignette, range: 0...1, unit: "%", format: { String(Int(($0 * 100).rounded())) })

                    section("Rotate & Flip")
                    HStack(spacing: 8) {
                        iconButton("rotate.left", "Rotate left") { adj.quarterTurns = (adj.quarterTurns + 3) % 4 }
                        iconButton("rotate.right", "Rotate right") { adj.quarterTurns = (adj.quarterTurns + 1) % 4 }
                        iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally") { adj.flipH.toggle() }
                        iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertically") { adj.flipV.toggle() }
                    }

                    section("Filters")
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 8), count: 3), spacing: 8) {
                        ForEach(ImageRender.filters, id: \.0) { f in
                            Button { adj.filter = f.1 } label: {
                                VStack(spacing: 3) {
                                    Group {
                                        if let t = thumbs[f.0] { Image(decorative: t, scale: 1).resizable().scaledToFill() } else { Color.primary.opacity(0.08) }
                                    }
                                    .frame(width: 74, height: 46)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(adj.filter == f.1 ? Theme.accent : .clear, lineWidth: 2))
                                    Text(f.0).font(.system(size: 10, weight: adj.filter == f.1 ? .semibold : .regular))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 300)
            }
            HStack {
                SecondaryButton(title: "Reset") { adj = ImageRender.Adjustments() }
                Spacer()
                SecondaryButton(title: "Cancel", action: close)
                PrimaryButton(title: "Save", enabled: preview != nil && !adj.isIdentity) { save() }
            }
        }
        .padding(20)
        .padding(.top, 12)
        .task {
            preview = await PreviewImage.decode(item.url, maxPixel: 1400)
            await makeThumbs()
        }
        .task(id: adj) { await render() }
    }

    private func signed(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r > 0 ? "+\(r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r))" : (r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r))
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 38, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func render() async {
        guard let p = preview else { return }
        if adj.isIdentity { rendered = nil; return }
        let a = adj, cg = p.cg
        let out = await Task.detached(priority: .userInitiated) { ImageRender.render(cg, adjustments: a, context: EditToolView.ciContext) }.value
        if !Task.isCancelled { rendered = out }
    }

    private func makeThumbs() async {
        guard let p = preview else { return }
        let small = p.fitted(maxSide: 160)
        var out: [String: CGImage] = [:]
        for f in ImageRender.filters {
            var a = ImageRender.Adjustments()
            a.filter = f.1
            if let img = await Task.detached(operation: { ImageRender.render(small, adjustments: a, context: EditToolView.ciContext) }).value {
                out[f.0] = img
            }
        }
        thumbs = out
    }

    private func save() {
        let item = self.item, a = self.adj
        let anchor = ToolPresenter.hudAnchor()
        close()
        JobRunner.shared.run(title: "Saving edits", near: anchor) { ctx in
            let full = try ImageKit.load(item.url).image
            guard let out = ImageRender.render(full, adjustments: a) else { throw TangeloError.failed("Couldn't render.") }
            try await ImageActions.saveEdited(out, like: item, suffix: "Edited", ctx: ctx)
        }
    }
}
