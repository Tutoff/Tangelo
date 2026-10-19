import SwiftUI
import TangeloCore

enum CropAspect: String, CaseIterable {
    case free = "Free", square = "1:1", wide = "16:9", tall = "9:16", classic = "4:3", portrait = "3:4", original = "Original"
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .wide: return 16.0 / 9
        case .tall: return 9.0 / 16
        case .classic: return 4.0 / 3
        case .portrait: return 3.0 / 4
        case .original: return original.width / max(original.height, 1)
        }
    }
}

/// Which edges a crop handle moves.
struct CropHandle: Hashable {
    var left = false, right = false, top = false, bottom = false
    static let all: [CropHandle] = [
        .init(left: true, top: true), .init(right: true, top: true), .init(left: true, bottom: true), .init(right: true, bottom: true),
        .init(top: true), .init(bottom: true), .init(left: true), .init(right: true),
    ]
    var isCorner: Bool { (left || right) && (top || bottom) }
}

struct CropToolView: View {
    let item: InputItem
    let close: () -> Void

    @State private var preview: PreviewImage?
    @State private var crop: CGRect = .zero
    @State private var aspect: CropAspect = .free
    @State private var dragStart: CGRect?

    private var full: CGSize { preview?.fullSize ?? .zero }

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { geo in
                if let preview {
                    // Inset so the corner handles are never clipped.
                    let fit = aspectFit(full, in: CGSize(width: geo.size.width - 28, height: geo.size.height - 28)).offsetBy(dx: 14, dy: 14)
                    let k = fit.width / max(full.width, 1)
                    let view = CGRect(x: fit.minX + crop.minX * k, y: fit.minY + crop.minY * k, width: crop.width * k, height: crop.height * k)
                    ZStack(alignment: .topLeading) {
                        preview.image.resizable().interpolation(.high)
                            .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                        // Dim everything outside the crop.
                        Path { p in
                            p.addRect(fit)
                            p.addRect(view)
                        }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                        // Rule of thirds + border.
                        Path { p in
                            for i in 1...2 {
                                let x = view.minX + view.width * CGFloat(i) / 3, y = view.minY + view.height * CGFloat(i) / 3
                                p.move(to: CGPoint(x: x, y: view.minY)); p.addLine(to: CGPoint(x: x, y: view.maxY))
                                p.move(to: CGPoint(x: view.minX, y: y)); p.addLine(to: CGPoint(x: view.maxX, y: y))
                            }
                        }
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.7)
                        .allowsHitTesting(false)
                        Rectangle()
                            .strokeBorder(Color.white, lineWidth: 1.5)
                            .background(Color.white.opacity(0.001))
                            .frame(width: view.width, height: view.height)
                            .offset(x: view.minX, y: view.minY)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { g in move(by: g.translation, k: k) }
                                .onEnded { _ in dragStart = nil })
                        ForEach(CropHandle.all, id: \.self) { h in
                            handleView(h)
                                .position(handlePosition(h, in: view))
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { g in resize(h, by: g.translation, k: k) }
                                    .onEnded { _ in dragStart = nil })
                        }
                    }
                } else {
                    LoadingView()
                }
            }
            .frame(width: 560, height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 12) {
                Text("Aspect ratio").font(.system(size: 12)).foregroundStyle(.secondary)
                PillPicker(options: CropAspect.allCases, selection: $aspect) { $0.rawValue }
                Spacer()
            }
            HStack(spacing: 8) {
                dimensionField("W", value: Binding(get: { Int(crop.width.rounded()) }, set: { setSize(width: CGFloat($0)) }))
                dimensionField("H", value: Binding(get: { Int(crop.height.rounded()) }, set: { setSize(height: CGFloat($0)) }))
                Text("px").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                SecondaryButton(title: "Reset") { withAnimation(.snappy) { aspect = .free; crop = CGRect(origin: .zero, size: full) } }
                Spacer()
                SecondaryButton(title: "Cancel", action: close)
                PrimaryButton(title: "Apply", enabled: preview != nil) { apply() }
            }
        }
        .padding(20)
        .padding(.top, 12)
        .task {
            preview = await PreviewImage.decode(item.url)
            if let p = preview { crop = CGRect(origin: .zero, size: p.fullSize) }
        }
        .onChange(of: aspect) { _, a in applyAspect(a) }
    }

    private func dimensionField(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
        }
    }

    private func handleView(_ h: CropHandle) -> some View {
        Group {
            if h.isCorner {
                Circle().fill(Theme.accent).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            } else {
                Capsule().fill(Theme.accent)
                    .frame(width: h.left || h.right ? 6 : 22, height: h.left || h.right ? 22 : 6)
                    .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }

    private func handlePosition(_ h: CropHandle, in r: CGRect) -> CGPoint {
        CGPoint(x: h.left ? r.minX : (h.right ? r.maxX : r.midX), y: h.top ? r.minY : (h.bottom ? r.maxY : r.midY))
    }

    // MARK: Geometry

    private var bounds: CGRect { CGRect(origin: .zero, size: full) }
    private var ratio: CGFloat? { aspect.ratio(original: full) }

    private func move(by t: CGSize, k: CGFloat) {
        if dragStart == nil { dragStart = crop }
        guard let s = dragStart else { return }
        var r = s.offsetBy(dx: t.width / k, dy: t.height / k)
        r.origin.x = min(max(0, r.origin.x), full.width - r.width)
        r.origin.y = min(max(0, r.origin.y), full.height - r.height)
        crop = r
    }

    private func resize(_ h: CropHandle, by t: CGSize, k: CGFloat) {
        if dragStart == nil { dragStart = crop }
        guard let s = dragStart else { return }
        let minSize: CGFloat = max(8, full.width / 200)
        let dx = t.width / k, dy = t.height / k
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if h.left { minX = min(maxX - minSize, max(0, s.minX + dx)) }
        if h.right { maxX = max(minX + minSize, min(full.width, s.maxX + dx)) }
        if h.top { minY = min(maxY - minSize, max(0, s.minY + dy)) }
        if h.bottom { maxY = max(minY + minSize, min(full.height, s.maxY + dy)) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let ratio {
            var w = r.width, hgt = r.height
            let widthDrives = h.isCorner ? abs(dx) >= abs(dy) * ratio : (h.left || h.right)
            if widthDrives { hgt = w / ratio } else { w = hgt * ratio }
            // Anchor: opposite corner for corners, opposite edge (centered) for edges.
            let ax = h.left ? s.maxX : (h.right ? s.minX : s.midX)
            let ay = h.top ? s.maxY : (h.bottom ? s.minY : s.midY)
            // Shrink to stay inside the image.
            let maxW = h.left ? ax : (h.right ? full.width - ax : 2 * min(ax, full.width - ax))
            let maxH = h.top ? ay : (h.bottom ? full.height - ay : 2 * min(ay, full.height - ay))
            let f = min(1, maxW / max(w, 1), maxH / max(hgt, 1))
            w *= f; hgt *= f
            let x = h.left ? ax - w : (h.right ? ax : ax - w / 2)
            let y = h.top ? ay - hgt : (h.bottom ? ay : ay - hgt / 2)
            r = CGRect(x: x, y: y, width: max(w, minSize), height: max(hgt, minSize))
        }
        crop = r.intersection(bounds)
    }

    private func applyAspect(_ a: CropAspect) {
        guard let ratio = a.ratio(original: full) else { return }
        var w = full.width, h = w / ratio
        if h > full.height { h = full.height; w = h * ratio }
        let c = CGPoint(x: crop.midX, y: crop.midY)
        var r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        r.origin.x = min(max(0, r.origin.x), full.width - w)
        r.origin.y = min(max(0, r.origin.y), full.height - h)
        withAnimation(.snappy(duration: 0.25)) { crop = r }
    }

    private func setSize(width: CGFloat? = nil, height: CGFloat? = nil) {
        var w = min(max(1, width ?? crop.width), full.width)
        var h = min(max(1, height ?? crop.height), full.height)
        if let ratio {
            if width != nil { h = w / ratio } else { w = h * ratio }
            let f = min(1, full.width / w, full.height / h)
            w *= f; h *= f
        }
        let c = CGPoint(x: crop.midX, y: crop.midY)
        var r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        r.origin.x = min(max(0, r.origin.x), full.width - w)
        r.origin.y = min(max(0, r.origin.y), full.height - h)
        crop = r
    }

    private func apply() {
        let rect = crop.integral
        let item = self.item
        let anchor = ToolPresenter.hudAnchor()
        close()
        JobRunner.shared.run(title: "Cropping", near: anchor) { ctx in
            try await ImageActions.crop(item, rect: rect, ctx: ctx)
        }
    }
}
