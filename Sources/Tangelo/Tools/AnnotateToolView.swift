import SwiftUI
import TangeloCore

enum AnnotateTool: String, CaseIterable {
    case pen, highlighter, arrow, line, rect, ellipse, text, step
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .step: return "1.circle"
        }
    }
    var help: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Box"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        case .step: return "Numbered step"
        }
    }
}

struct AnnotateToolView: View {
    let item: InputItem
    let close: () -> Void

    @State private var preview: PreviewImage?
    @State private var annotations: [ImageRender.Annotation] = []
    @State private var redo: [ImageRender.Annotation] = []
    @State private var current: ImageRender.Annotation?
    @State private var tool: AnnotateTool = .arrow
    @State private var color = RGBA(hex: 0xF0412B)
    @State private var size = 1
    @State private var pendingText: CGPoint?
    @State private var text = ""
    @FocusState private var textFocused: Bool

    static let palette: [UInt32] = [0xF0412B, 0xF46622, 0xF6C343, 0x34C759, 0x2F7CF6, 0x8E5CF7, 0x111111, 0xFFFFFF]
    private var full: CGSize { preview?.fullSize ?? .zero }
    private var baseWidth: Double { max(2, Double(max(full.width, full.height)) * 0.0035) }
    private var strokeWidth: Double { baseWidth * [1.0, 2.0, 3.6][size] }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            GeometryReader { geo in
                if let preview {
                    let fit = aspectFit(full, in: geo.size)
                    let k = fit.width / max(full.width, 1)
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, _ in
                            ctx.draw(preview.image, in: fit)
                            ctx.withCGContext { cg in
                                cg.translateBy(x: fit.minX, y: fit.minY)
                                cg.scaleBy(x: k, y: k)
                                ImageRender.draw(annotations + (current.map { [$0] } ?? []), in: cg)
                            }
                        }
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in dragChanged(g, fit: fit, k: k) }
                            .onEnded { g in dragEnded(g, fit: fit, k: k) })
                        if let p = pendingText {
                            TextField("Type, then press Return", text: $text)
                                .textFieldStyle(.plain)
                                .font(.system(size: max(13, strokeWidth * 6 * k), weight: .bold))
                                .foregroundStyle(Color(.sRGB, red: color.r, green: color.g, blue: color.b))
                                .padding(4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.85)))
                                .frame(width: 240)
                                .offset(x: fit.minX + p.x * k, y: fit.minY + p.y * k - 6)
                                .focused($textFocused)
                                .onSubmit { commitText() }
                                .onExitCommand { pendingText = nil; text = "" }
                        }
                    }
                } else {
                    LoadingView()
                }
            }
            .frame(width: 640, height: 440)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                SecondaryButton(title: "Clear") { if !annotations.isEmpty { redo = annotations.reversed(); annotations = [] } }
                Spacer()
                SecondaryButton(title: "Cancel", action: close)
                PrimaryButton(title: "Save", enabled: preview != nil && !annotations.isEmpty) { save() }
            }
        }
        .padding(20)
        .padding(.top, 12)
        .task { preview = await PreviewImage.decode(item.url, maxPixel: 2000) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(AnnotateTool.allCases, id: \.self) { t in
                    Button { tool = t } label: {
                        Image(systemName: t.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 26)
                            .foregroundStyle(tool == t ? Color.white : Color.primary.opacity(0.8))
                            .background(RoundedRectangle(cornerRadius: 7).fill(tool == t ? Theme.accent : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(t.help)
                }
            }
            .modifier(GlassBar())

            HStack(spacing: 5) {
                ForEach(Self.palette, id: \.self) { hex in
                    let c = RGBA(hex: hex)
                    Button { color = c } label: {
                        Circle().fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                            .padding(2)
                            .overlay(Circle().strokeBorder(color == c ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            PillPicker(options: [0, 1, 2], selection: $size) { ["S", "M", "L"][$0] }
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).keyboardShortcut("z", modifiers: .command).disabled(annotations.isEmpty).help("Undo")
            Button { redoLast() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(redo.isEmpty).help("Redo")
        }
    }

    // MARK: Drawing

    private func imagePoint(_ p: CGPoint, fit: CGRect, k: CGFloat) -> CGPoint {
        CGPoint(x: min(max(0, (p.x - fit.minX) / k), full.width), y: min(max(0, (p.y - fit.minY) / k), full.height))
    }

    private func dragChanged(_ g: DragGesture.Value, fit: CGRect, k: CGFloat) {
        guard pendingText == nil else { return }
        let start = imagePoint(g.startLocation, fit: fit, k: k), p = imagePoint(g.location, fit: fit, k: k)
        let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        let kind: ImageRender.AnnotationKind?
        switch tool {
        case .pen, .highlighter:
            var pts: [CGPoint] = []
            if let c = current {
                switch c.kind { case .pen(let x), .highlighter(let x): pts = x; default: break }
            }
            if pts.isEmpty || hypot(pts.last!.x - p.x, pts.last!.y - p.y) > 1.5 / k { pts.append(p) }
            kind = tool == .pen ? .pen(pts) : .highlighter(pts)
        case .arrow: kind = .arrow(start, p)
        case .line: kind = .line(start, p)
        case .rect: kind = .rect(rect)
        case .ellipse: kind = .ellipse(rect)
        case .text, .step: kind = nil
        }
        if let kind { current = ImageRender.Annotation(kind: kind, color: color, width: strokeWidth) }
    }

    private func dragEnded(_ g: DragGesture.Value, fit: CGRect, k: CGFloat) {
        let p = imagePoint(g.location, fit: fit, k: k)
        switch tool {
        case .text:
            if pendingText != nil { commitText() } else { pendingText = p; text = ""; DispatchQueue.main.async { textFocused = true } }
        case .step:
            let n = annotations.filter { if case .step = $0.kind { return true } else { return false } }.count + 1
            add(ImageRender.Annotation(kind: .step(n, p), color: color, width: strokeWidth))
        default:
            if let c = current, isMeaningful(c) { add(c) }
        }
        current = nil
    }

    private func isMeaningful(_ a: ImageRender.Annotation) -> Bool {
        switch a.kind {
        case .pen(let pts), .highlighter(let pts): return !pts.isEmpty
        case .arrow(let p, let q), .line(let p, let q): return hypot(p.x - q.x, p.y - q.y) > 3
        case .rect(let r), .ellipse(let r): return r.width > 3 && r.height > 3
        default: return true
        }
    }

    private func commitText() {
        if let p = pendingText, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            add(ImageRender.Annotation(kind: .text(text, p), color: color, width: strokeWidth))
        }
        pendingText = nil
        text = ""
    }

    private func add(_ a: ImageRender.Annotation) {
        annotations.append(a)
        redo.removeAll()
    }

    private func undo() {
        guard let last = annotations.popLast() else { return }
        redo.append(last)
    }

    private func redoLast() {
        guard let a = redo.popLast() else { return }
        annotations.append(a)
    }

    private func save() {
        let item = self.item, annotations = self.annotations
        let anchor = ToolPresenter.hudAnchor()
        close()
        JobRunner.shared.run(title: "Saving annotations", near: anchor) { ctx in
            let full = try ImageKit.load(item.url).image
            guard let out = ImageRender.renderAnnotations(full, annotations) else { throw TangeloError.failed("Couldn't render.") }
            try await ImageActions.saveEdited(out, like: item, suffix: "Annotated", ctx: ctx)
        }
    }
}
