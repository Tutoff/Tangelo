import SwiftUI
import TangeloCore

struct MetadataToolView: View {
    let item: InputItem
    let close: () -> Void

    @State private var entries: [ImageMeta.Entry] = []
    @State private var location: ImageMeta.Location?
    @State private var thumb: CGImage?

    private var groups: [String] {
        var seen: [String] = []
        for e in entries where !seen.contains(e.group) { seen.append(e.group) }
        return seen
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let thumb { Image(decorative: thumb, scale: 1).resizable().scaledToFill() } else { Color.primary.opacity(0.08) }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.url.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.self) { g in
                        Text(g.uppercased()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
                            .padding(.top, 12).padding(.bottom, 4).padding(.horizontal, 12)
                        ForEach(entries.filter { $0.group == g }) { e in
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.key).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
                                Text(e.value).font(.system(size: 12)).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .frame(width: 480, height: 340)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

            if let loc = location {
                HStack(spacing: 8) {
                    Image(systemName: "location.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 16))
                    Text("This photo contains its location: \(String(format: "%.5f, %.5f", loc.latitude, loc.longitude))")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Open in Maps") {
                        if let url = URL(string: "https://maps.apple.com/?ll=\(loc.latitude),\(loc.longitude)&q=Photo") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                }
            }
            HStack {
                if location != nil { SecondaryButton(title: "Remove Location") { strip(onlyLocation: true) } }
                Spacer()
                SecondaryButton(title: "Done", action: close)
                PrimaryButton(title: "Remove All Metadata") { strip(onlyLocation: false) }
            }
        }
        .padding(20)
        .padding(.top, 12)
        .task {
            let url = item.url
            let (e, l, t) = await Task.detached {
                (ImageMeta.entries(for: url), ImageMeta.location(for: url), PreviewImage.decodedImage(url, maxPixel: 200))
            }.value
            entries = e; location = l; thumb = t
        }
    }

    private var subtitle: String {
        let size = ImageKit.pixelSize(of: item.url).map { "\(Int($0.width)) × \(Int($0.height)) px" } ?? ""
        return [size, ByteFormat.string(item.size), item.format.uppercased()].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func strip(onlyLocation: Bool) {
        let item = self.item
        let anchor = ToolPresenter.hudAnchor()
        close()
        JobRunner.shared.run(title: onlyLocation ? "Removing location" : "Removing metadata", near: anchor) { ctx in
            try await ImageMeta.strip(item, onlyLocation: onlyLocation, ctx: ctx)
        }
    }
}
