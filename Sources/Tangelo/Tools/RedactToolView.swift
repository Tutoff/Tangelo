import SwiftUI
import TangeloCore

struct RedactToolView: View {
    let item: InputItem
    let close: () -> Void

    @State private var preview: PreviewImage?
    @State private var boxes: [ImageRender.Redaction] = []
    @State private var style: ImageRender.RedactStyle = .black
    @State private var drawing: CGRect?
    @State private var rendered: CGImage?
    @State private var selected: UUID?
    @State private var busy = false
    @State private var note: String?

    private var full: CGSize { preview?.fullSize ?? .zero }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                PillPicker(options: ImageRender.RedactStyle.allCases, selection: $style) { $0.rawValue }
                Spacer()
                Button { detect(faces: false) } label: { Label("Find Text", systemImage: "text.viewfinder") }
                    .buttonStyle(.bordered).disabled(preview == nil || busy)
                Button { detect(faces: true) } label: { Label("Find Faces", systemImage: "person.crop.square") }
                    .buttonStyle(.bordered).disabled(preview == nil || busy)
                Button { if !boxes.isEmpty { boxes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).keyboardShortcut("z", modifiers: .command).disabled(boxes.isEmpty).help("Undo")
            }
            GeometryReader { geo in
                if let preview {
                    let fit = aspectFit(full, in: geo.size)
                    let k = fit.width / max(full.width, 1)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: rendered ?? preview.cg, scale: 1).resizable().interpolation(.high)
                            .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                        ForEach(boxes) { b in
                            let r = viewRect(b.rect, fit: fit, k: k)
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(b.id == selected ? Theme.accent : Color.white.opacity(0.8),
                                              style: StrokeStyle(lineWidth: b.id == selected ? 2 : 1, dash: [5, 3]))
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                                .allowsHitTesting(false)
                        }
                        if let d = drawing {
                            let r = viewRect(d, fit: fit, k: k)
                            Rectangle().fill(Theme.accent.opacity(0.18)).overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5))
                                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let a = imagePoint(g.startLocation, fit: fit, k: k), b = imagePoint(g.location, fit: fit, k: k)
                            drawing = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                        }
                        .onEnded { g in
                            if let d = drawing, d.width * k > 4, d.height * k > 4 {
                                let box = ImageRender.Redaction(rect: d, style: style)
                                boxes.append(box)
                                selected = box.id
                            } else {
                                let p = imagePoint(g.location, fit: fit, k: k)
                                selected = boxes.last(where: { $0.rect.contains(p) })?.id
                            }
                            drawing = nil
                        })
                } else {
                    LoadingView()
                }
            }
            .frame(width: 640, height: 440)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                SecondaryButton(title: "Clear") { boxes.removeAll(); selected = nil }
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Spacer()
                SecondaryButton(title: "Cancel", action: close)
                PrimaryButton(title: "Save", enabled: !boxes.isEmpty) { save() }
            }
        }
        .padding(20)
        .padding(.top, 12)
        .task { preview = await PreviewImage.decode(item.url, maxPixel: 1600) }
        .task(id: boxes) { await render() }
        .onChange(of: style) { _, s in
            if let id = selected, let i = boxes.firstIndex(where: { $0.id == id }) { boxes[i].style = s }
        }
        .onDeleteCommand {
            if let id = selected { boxes.removeAll { $0.id == id }; selected = nil }
        }
    }

    private func viewRect(_ r: CGRect, fit: CGRect, k: CGFloat) -> CGRect {
        CGRect(x: fit.minX + r.minX * k, y: fit.minY + r.minY * k, width: r.width * k, height: r.height * k)
    }

    private func imagePoint(_ p: CGPoint, fit: CGRect, k: CGFloat) -> CGPoint {
        CGPoint(x: min(max(0, (p.x - fit.minX) / k), full.width), y: min(max(0, (p.y - fit.minY) / k), full.height))
    }

    private func render() async {
        guard let p = preview else { return }
        guard !boxes.isEmpty else { rendered = nil; return }
        let k = p.scale
        let scaled = boxes.map { ImageRender.Redaction(rect: $0.rect.applying(CGAffineTransform(scaleX: k, y: k)), style: $0.style) }
        let cg = p.cg
        let out = await Task.detached(priority: .userInitiated) { ImageRender.renderRedactions(cg, scaled) }.value
        if !Task.isCancelled { rendered = out }
    }

    private func detect(faces: Bool) {
        guard let p = preview else { return }
        busy = true
        let cg = p.cg, k = p.scale, style = self.style
        Task {
            let rects: [CGRect] = await Task.detached(priority: .userInitiated) {
                if faces { return (try? VisionKit.faceRects(in: cg)) ?? [] }
                return ((try? VisionKit.recognizeLines(in: cg)) ?? []).map { $0.rect.insetBy(dx: -3, dy: -3) }
            }.value
            let found = rects.map { ImageRender.Redaction(rect: $0.applying(CGAffineTransform(scaleX: 1 / k, y: 1 / k)), style: style) }
            boxes.append(contentsOf: found)
            note = found.isEmpty ? (faces ? "No faces found." : "No text found.") : "Added \(found.count) area\(found.count == 1 ? "" : "s")."
            busy = false
        }
    }

    private func save() {
        let item = self.item, boxes = self.boxes
        let anchor = ToolPresenter.hudAnchor()
        close()
        JobRunner.shared.run(title: "Redacting", near: anchor) { ctx in
            let full = try ImageKit.load(item.url).image
            guard let out = ImageRender.renderRedactions(full, boxes) else { throw TangeloError.failed("Couldn't render.") }
            try await ImageActions.saveEdited(out, like: item, suffix: "Redacted", ctx: ctx)
        }
    }
}
