import AVFoundation
import AVKit
import AppKit
import Combine
import SwiftUI

/// Coordinates AVPlayer playback for a History-linked companion video.
@MainActor
final class LinkedVideoPlaybackCoordinator: ObservableObject {
    @Published var player: AVPlayer?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isPlaying = false
    @Published var activeSubtitle: String = ""
    @Published var playbackRate: Float = 1.0

    private var sentences: [TranscriptionTimedSentence] = []
    private var timeObserver: Any?
    private var seekObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var statusCancellable: AnyCancellable?

    /// Loads a video and optional timed sentences, seeking to `startAt` when ready.
    func load(url: URL, sentences: [TranscriptionTimedSentence], startAt: TimeInterval) {
        cleanup()
        self.sentences = sentences

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        player = newPlayer

        statusCancellable = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, status == .readyToPlay else { return }
                let mediaDuration = item.duration.seconds
                if mediaDuration.isFinite, mediaDuration > 0 {
                    self.duration = mediaDuration
                }
                if startAt > 0 {
                    self.seek(to: startAt, resumePlaying: false)
                }
                self.updateSubtitle(for: self.currentTime)
            }

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = seconds
                self.isPlaying = newPlayer.rate > 0
                self.updateSubtitle(for: seconds)
                self.publishPlaybackTime()
            }
        }

        seekObserver = NotificationCenter.default.addObserver(
            forName: .seekTranscriptionAudio,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let time = notification.userInfo?["time"] as? TimeInterval else { return }
            Task { @MainActor in
                self?.seek(to: time, resumePlaying: true)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.publishPlaybackTime()
            }
        }
    }

    func play() {
        player?.rate = playbackRate
        player?.play()
        isPlaying = true
        publishPlaybackTime()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        publishPlaybackTime()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seeks video and optionally resumes playback.
    func seek(to time: TimeInterval, resumePlaying: Bool) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        updateSubtitle(for: clamped)
        publishPlaybackTime()
        if resumePlaying {
            play()
        }
    }

    func cyclePlaybackRate() {
        switch playbackRate {
        case 1.0: playbackRate = 1.5
        case 1.5: playbackRate = 2.0
        default: playbackRate = 1.0
        }
        if isPlaying {
            player?.rate = playbackRate
        }
    }

    func cleanup() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let seekObserver {
            NotificationCenter.default.removeObserver(seekObserver)
        }
        seekObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusCancellable = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        activeSubtitle = ""
    }

    private func updateSubtitle(for time: TimeInterval) {
        guard let sentence = sentences.first(where: { isActive($0, at: time) }) else {
            activeSubtitle = ""
            return
        }
        activeSubtitle = sentence.text
    }

    private func isActive(_ sentence: TranscriptionTimedSentence, at time: TimeInterval) -> Bool {
        let isLast = sentences.last?.id == sentence.id
        if isLast {
            return time >= sentence.beginTime && time <= sentence.endTime + 0.05
        }
        return time >= sentence.beginTime && time < sentence.endTime
    }

    private func publishPlaybackTime() {
        NotificationCenter.default.post(
            name: .transcriptionPlaybackTimeDidChange,
            object: self,
            userInfo: [
                "time": currentTime,
                "isPlaying": isPlaying,
            ]
        )
    }
}

/// AppKit-backed video surface. Avoids SwiftUI `VideoPlayer`, which can abort on macOS
/// when `_AVKit_SwiftUI` fails to demangle `AVPlayerView` metadata.
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// Separate-window UI: video surface + optional subtitle sidebar + transport.
struct LinkedVideoPlayerView: View {
    private static let sidebarWidth: CGFloat = 320
    private static let sidebarVisibilityKey = "linkedVideoShowsSubtitleSidebar"

    let videoURL: URL
    let sentences: [TranscriptionTimedSentence]
    var startAt: TimeInterval = 0
    var title: String = "Linked Video"
    var usesEnhancedText = false

    @StateObject private var coordinator = LinkedVideoPlaybackCoordinator()
    @AppStorage(Self.sidebarVisibilityKey) private var showsSubtitleSidebar = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                videoStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showsSubtitleSidebar, !sentences.isEmpty {
                    Divider()
                    subtitleSidebar
                        .frame(width: Self.sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showsSubtitleSidebar)

            transportBar
        }
        .frame(
            minWidth: showsSubtitleSidebar && !sentences.isEmpty ? 960 : 720,
            minHeight: 480
        )
        .onAppear {
            NotificationCenter.default.post(name: .pauseTranscriptionAudio, object: nil)
            coordinator.load(url: videoURL, sentences: sentences, startAt: startAt)
        }
        .onDisappear {
            coordinator.cleanup()
        }
    }

    private var videoStage: some View {
        ZStack(alignment: .bottom) {
            AVPlayerViewRepresentable(player: coordinator.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            if coordinator.player == nil {
                ProgressView()
            }

            if !coordinator.activeSubtitle.isEmpty {
                Text(coordinator.activeSubtitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 720)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .background(Color.black)
    }

    private var subtitleSidebar: some View {
        TimedSentencesListView(
            sentences: sentences,
            usesEnhancedText: usesEnhancedText,
            showsCardChrome: false,
            presentation: .plainList
        )
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Surface.materialCard)
    }

    private var transportBar: some View {
        HStack(spacing: 12) {
            Text(formatClock(coordinator.currentTime))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            Slider(
                value: Binding(
                    get: { coordinator.currentTime },
                    set: { coordinator.seek(to: $0, resumePlaying: coordinator.isPlaying) }
                ),
                in: 0...max(coordinator.duration, 0.1)
            )

            Text(formatClock(coordinator.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Button {
                coordinator.cyclePlaybackRate()
            } label: {
                Text(rateLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 36)
            }
            .buttonStyle(.plain)
            .help("Playback speed")

            Button {
                coordinator.togglePlayPause()
            } label: {
                Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(coordinator.isPlaying ? "Pause" : "Play")

            if !sentences.isEmpty {
                Button {
                    showsSubtitleSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(showsSubtitleSidebar ? AppTheme.Text.primary : AppTheme.Text.muted)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(
                                    showsSubtitleSidebar
                                        ? AppTheme.Surface.controlActive
                                        : AppTheme.Surface.subtle
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(showsSubtitleSidebar ? "Hide subtitle sidebar" : "Show subtitle sidebar")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.Surface.materialCard)
    }

    private var rateLabel: String {
        switch coordinator.playbackRate {
        case 1.5: return "1.5×"
        case 2.0: return "2×"
        default: return "1×"
        }
    }

    private func formatClock(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded(.down)))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
