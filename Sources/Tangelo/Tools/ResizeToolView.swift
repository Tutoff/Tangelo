import SwiftUI
import TangeloCore

struct ResizeToolView: View {
    let item: InputItem
    let close: () -> Void

    @State private var original: CGSize = .zero
    @State private var width = 0
    @State private var height = 0
    @State private var linked = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Current size: \(Int(original.width)) × \(Int(original.height)) px")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                field("Width", value: Binding(get: { width }, set: { setWidth($0) }))
                Button { linked.toggle(); if linked { setWidth(width) } } label: {
                    Image(systemName: linked ? "link" : "link.badge.plus")
                        .foregroundStyle(linked ? Theme.accent : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(linked ? "Keep proportions" : "Free proportions")
                field("Height", value: Binding(get: { height }, set: { setHeight($0) }))
                Text("px").foregroundStyle(.secondary).font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("SCALE").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach([25, 50, 75, 150, 200], id: \.self) { p in
                        preset("\(p)%") { setWidth(Int((original.width * CGFloat(p) / 100).rounded()), force: true) }
                    }
                }
                Text("LONGEST SIDE").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).padding(.top, 4)
                HStack(spacing: 6) {
                    ForEach([1080, 1920, 2560, 3840], id: \.self) { side in
                        preset("\(side)") { fitLongest(side) }
                    }
                }
            }
            HStack {
                Spacer()
                SecondaryButton(title: "Cancel", action: close)
                PrimaryButton(title: "Resize", enabled: width > 0 && height > 0 && (width != Int(original.width) || height != Int(original.height))) { save() }
            }
        }
        .padding(22)
        .padding(.top, 12)
        .frame(width: 440)
        .task {
            original = ImageKit.pixelSize(of: item.url) ?? .zero
            width = Int(original.width); height = Int(original.height)
        }
    }

    private func field(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 96).multilineTextAlignment(.trailing)
        }
    }

    private func preset(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var ratio: CGFloat { original.height > 0 ? original.width / original.height : 1 }

    private func setWidth(_ w: Int, force: Bool = false) {
        width = max(1, min(w, 30000))
        if linked || force { height = max(1, Int((CGFloat(width) / ratio).rounded())) }
    }

    private func setHeight(_ h: Int) {
        height = max(1, min(h, 30000))
        if linked { width = max(1, Int((CGFloat(height) * ratio).rounded())) }
    }

    private func fitLongest(_ side: Int) {
        if original.width >= original.height { setWidth(side, force: true) }
        else { height = side; width = max(1, Int((CGFloat(side) * ratio).rounded())) }
    }

    private func save() {
        let item = self.item, w = width, h = height
        let anchor = ToolPresenter.hudAnchor()
        close()
        JobRunner.shared.run(title: "Resizing", near: anchor) { ctx in
            try await ImageActions.resize(item, width: w, height: h, ctx: ctx)
        }
    }
}
