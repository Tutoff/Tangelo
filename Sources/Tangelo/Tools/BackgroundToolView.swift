import SwiftUI
import TangeloCore

struct BackgroundToolView: View {
    let item: InputItem
    let close: () -> Void

    @State private var preview: PreviewImage?
    @State private var style = BackdropStyle()
    @State private var rendered: CGImage?
    @State private var custom: Color = Color(nsColor: Theme.tangerine)
    @State private var defaults = BackdropStyle()

    private var full: CGSize { preview?.fullSize ?? CGSize(width: 1000, height: 1000) }
    private var maxPadding: Double { Double(max(full.width, full.height)) * 0.5 }
    private var maxCorner: Double { Double(min(full.width, full.height)) * 0.25 }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Checkerboard()
                if let rendered {
                    Image(decorative: rendered, scale: 1).resizable().interpolation(.high).scaledToFit().padding(10)
                } else {
                    LoadingView()
                }
            }
            .frame(width: 520, height: 330)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text("Background").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) { ForEach(BackgroundFill.gradients, id: \.self) { swatch($0) } }
                        HStack(spacing: 7) {
                            ForEach(BackgroundFill.solids, id: \.self) { swatch($0) }
                            ColorPicker("", selection: $custom, supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 26, height: 26)
                                .help("Custom color")
                        }
                    }
                }
            }
            SliderRow(title: "Padding", value: $style.padding, range: 0...max(maxPadding, 1))
            SliderRow(title: "Corners", value: $style.cornerRadius, range: 0...max(maxCorner, 1))
            SliderRow(title: "Shadow", value: $style.shadow, range: 0...max(150, Double(max(full.width, full.height)) * 0.06))
            HStack(spacing: 10) {
                Text("Ratio").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                PillPicker(options: CanvasAspect.allCases, selection: $style.aspect) { $0.rawValue }
                Spacer()
            }
            HStack {
                SecondaryButton(title: "Reset") { style = defaults }
                Spacer()
                SecondaryButton(title: "Cancel", action: close)
                PrimaryButton(title: "Save with Background", enabled: preview != nil) { save() }
            }
        }
        .padding(20)
        .padding(.top, 12)
        .frame(width: 560)
        .task {
            preview = await PreviewImage.decode(item.url, maxPixel: 1100, colorSpace: ImageKit.sRGB)
            let longer = Double(max(full.width, full.height)), shorter = Double(min(full.width, full.height))
            var s = BackdropStyle()
            s.padding = (longer * 0.07).rounded()
            s.cornerRadius = max(8, (shorter * 0.02).rounded())
            s.shadow = max(12, (longer * 0.012).rounded())
            defaults = s
            style = s
        }
        .task(id: style) { await render() }
        .onChange(of: custom) { _, c in
            let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
            style.fill = .solid(RGBA(ns.redComponent, ns.greenComponent, ns.blueComponent))
        }
    }

    private func swatch(_ fill: BackgroundFill) -> some View {
        let selected = style.fill == fill
        return Button { style.fill = fill } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(swatchFill(fill))
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func swatchFill(_ fill: BackgroundFill) -> AnyShapeStyle {
        func color(_ c: RGBA) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
        switch fill {
        case .solid(let c): return AnyShapeStyle(color(c))
        case .gradient(let cs, _): return AnyShapeStyle(LinearGradient(colors: cs.map(color), startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private func render() async {
        guard let p = preview else { return }
        var s = style
        let k = Double(p.scale)
        s.padding *= k; s.cornerRadius *= k; s.shadow *= k
        let cg = p.cg
        let out = await Task.detached(priority: .userInitiated) { ImageRender.addBackground(cg, style: s) }.value
        if !Task.isCancelled { rendered = out }
    }

    private func save() {
        let item = self.item, style = self.style
        let anchor = ToolPresenter.hudAnchor()
        close()
        JobRunner.shared.run(title: "Adding background", near: anchor) { ctx in
            let full = try ImageKit.load(item.url).image
            guard let out = ImageRender.addBackground(full, style: style) else { throw TangeloError.failed("The image is too large.") }
            try await ImageActions.saveEdited(out, like: item, suffix: "With Background", forcePNG: true, ctx: ctx)
        }
    }
}
