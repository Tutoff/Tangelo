import SwiftUI
import TangeloCore

struct SettingsView: View {
    @ObservedObject var s = AppSettings.shared
    @State private var loginError: String?
    private let ffmpeg = ExternalTools.find("ffmpeg")
    private let cwebp = ExternalTools.find("cwebp")

    var body: some View {
        Form {
            Section("Ring") {
                Toggle("Show the ring when dragging files", isOn: $s.enabled)
                Picker("Hold this key while dragging", selection: $s.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                Text("Tip: tap the key again (or hover the tabs under the ring) to switch between Convert, More and Tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saving") {
                Picker("Save results", selection: $s.useCustomFolder) {
                    Text("Next to the original file").tag(false)
                    Text("In a specific folder").tag(true)
                }
                if s.useCustomFolder {
                    HStack {
                        Text(s.customFolder?.path ?? "No folder chosen").font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Reveal results in Finder", isOn: $s.revealInFinder)
                Toggle("Play a sound when done", isOn: $s.playSound)
            }
            Section("Quality") {
                HStack {
                    Text("Photo quality (JPG, HEIC, AVIF)")
                    Slider(value: $s.quality, in: 0.5...1).tint(Theme.accent)
                    Text("\(Int((s.quality * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Picker("PDF pages to images", selection: $s.pdfDPI) {
                    Text("150 dpi").tag(150.0)
                    Text("200 dpi").tag(200.0)
                    Text("300 dpi").tag(300.0)
                }
                Toggle("Keep location data in converted photos", isOn: $s.keepLocation)
            }
            Section("General") {
                Toggle("Open Tangelo at login", isOn: Binding(get: { s.launchAtLogin }, set: { loginError = s.setLaunchAtLogin($0) }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Extra formats") {
                toolRow("ffmpeg", found: ffmpeg, enables: "MP3, WebM, MKV, AVI, Opus, OGG, AC3, WMA and MKV/WebM input",
                        install: "brew install ffmpeg")
                toolRow("cwebp", found: cwebp, enables: "smaller lossy WebP (without it, WebP is saved lossless)",
                        install: "brew install webp")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }

    private func toolRow(_ name: String, found: String?, enables: String, install: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: found != nil ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(found != nil ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text(found.map { "Found at \($0) — enables \(enables)." } ?? "Not installed. Run “\(install)” in Terminal for \(enables).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { s.customFolder = url }
    }
}
