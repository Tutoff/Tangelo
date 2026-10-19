import SwiftUI
import TangeloCore

struct WelcomeView: View {
    let ring: NSImage
    var ringModel: RingModel? = nil
    let sample: URL?
    let openSettings: () -> Void
    let close: () -> Void
    @ObservedObject var s = AppSettings.shared
    @State private var loginError: String?

    private var keyName: String {
        switch s.trigger {
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .shiftControl: return "⇧ Shift + ⌃ Control"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            Group {
                if #available(macOS 26.0, *), let ringModel {
                    GlassRingView(model: ringModel)
                        .scaleEffect(300 / Ring.size.width)
                        .frame(width: 300, height: 300 * Ring.size.height / Ring.size.width)
                } else {
                    Image(nsImage: ring).resizable().interpolation(.high).frame(width: 300, height: 328)
                }
            }
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Tangelo").font(.system(size: 26, weight: .bold))
                    Text("Convert and edit files right where they are. No app to open, nothing uploaded.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                step(1, "Start dragging any file", "From Finder, the Desktop or another app.")
                step(2, "Hold \(keyName)", "The ring opens around your cursor.")
                step(3, "Drop on a format or tool", "The result is saved next to the original.")
                Text("Tap \(s.trigger.symbol) again, or hover the tabs under the ring, to switch between Convert, More and Tools. Drop in the middle to cancel.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                if let sample, let thumb = NSImage(contentsOf: sample) {
                    HStack(spacing: 12) {
                        Image(nsImage: thumb).resizable().scaledToFill().frame(width: 64, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5))
                            .onDrag { NSItemProvider(contentsOf: sample) ?? NSItemProvider() }
                            .help("Drag me while holding \(keyName)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Try it now").font(.system(size: 12.5, weight: .semibold))
                            Text("Drag this photo while holding \(keyName).").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.08)))
                }

                Toggle("Open Tangelo at login", isOn: Binding(get: { s.launchAtLogin }, set: { loginError = s.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Text("Tangelo lives in your menu bar.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    SecondaryButton(title: "Settings…", action: openSettings)
                    PrimaryButton(title: "Get Started", action: close)
                }
            }
            .frame(width: 380)
        }
        .padding(26)
        .padding(.top, 10)
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
