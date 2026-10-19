import AVFoundation
import AVKit
import SwiftUI
import TangeloCore

struct TrimToolView: View {
    let item: InputItem
    let close: () -> Void

    @State private var native: Bool?
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            switch native {
            case .some(true):
                TrimPlayer(url: item.url) { range in
                    if let range { save(start: range.start.seconds, end: range.end.seconds) } else { close() }
                }
                .frame(width: 680, height: item.kind == .audio ? 160 : 420)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Drag the yellow handles, then click Trim.").font(.system(size: 12)).foregroundStyle(.secondary)
            case .some(false):
                fallback
            case .none:
                LoadingView().frame(width: 680, height: 200)
            }
        }
        .padding(20)
        .padding(.top, 12)
        .task {
            native = await Media.isNativelyReadable(item.url)
            if native == false {
                duration = await Media.duration(of: item.url, ctx: JobContext(settings: AppSettings.shared.engine)) ?? 0
                end = duration
            }
        }
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This format can't be previewed, but it can still be trimmed precisely.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            SliderRow(title: "Start", value: $start, range: 0...max(duration, 0.1), unit: "", format: timecode)
            SliderRow(title: "End", value: $end, range: 0...max(duration, 0.1), unit: "", format: timecode)
            Text("Length: \(timecode(max(0, end - start)))").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                SecondaryButton(title: "Cancel", action: close)
                PrimaryButton(title: "Trim", enabled: end - start > 0.1) { save(start: start, end: end) }
            }
        }
        .frame(width: 480)
        .onChange(of: start) { _, s in if s > end { end = s } }
        .onChange(of: end) { _, e in if e < start { start = e } }
    }

    private func timecode(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int((s * 10).truncatingRemainder(dividingBy: 10)))
    }

    private func save(start: Double, end: Double) {
        let item = self.item
        let anchor = ToolPresenter.hudAnchor()
        close()
        JobRunner.shared.run(title: "Trimming", near: anchor) { ctx in
            try await AudioActions.trim(item, start: start, end: end, ctx: ctx)
        }
    }
}

/// AVPlayerView with QuickTime's trimming UI.
struct TrimPlayer: NSViewRepresentable {
    let url: URL
    let onFinish: (CMTimeRange?) -> Void

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.player = AVPlayer(url: url)
        context.coordinator.begin(view, onFinish: onFinish)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        coordinator.timer?.invalidate()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var timer: Timer?
        private var attempts = 0

        func begin(_ view: AVPlayerView, onFinish: @escaping (CMTimeRange?) -> Void) {
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self, weak view] t in
                guard let self, let view else { t.invalidate(); return }
                self.attempts += 1
                guard view.window != nil, view.canBeginTrimming else {
                    if self.attempts > 60 { t.invalidate() }
                    return
                }
                t.invalidate()
                view.beginTrimming { result in
                    guard result == .okButton, let item = view.player?.currentItem else { onFinish(nil); return }
                    let s = item.reversePlaybackEndTime, e = item.forwardPlaybackEndTime
                    let start = s.isValid && s.isNumeric ? s : .zero
                    let end = e.isValid && e.isNumeric ? e : item.duration
                    view.player?.pause()
                    onFinish(CMTimeRange(start: start, end: end))
                }
            }
        }
    }
}
