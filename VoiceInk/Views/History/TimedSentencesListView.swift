import SwiftUI

/// Timed ASR sentences with live playback highlighting and seek-on-tap.
struct TimedSentencesListView: View {
    enum Presentation {
        /// Collapsible section used in History detail / cards (parent scrolls).
        case disclosure
        /// Always-visible scrolling list (e.g. video-window sidebar).
        case plainList
    }

    let sentences: [TranscriptionTimedSentence]
    var usesEnhancedText = false
    var showsCardChrome = true
    var presentation: Presentation = .disclosure

    @State private var currentTime: TimeInterval = 0
    @State private var isPlaying = false
    @State private var isExpanded = true

    var body: some View {
        Group {
            switch presentation {
            case .disclosure:
                DisclosureGroup(isExpanded: $isExpanded) {
                    sentenceList(scrollable: false)
                } label: {
                    headerLabel
                }
            case .plainList:
                VStack(alignment: .leading, spacing: 8) {
                    headerLabel
                    sentenceList(scrollable: true)
                }
            }
        }
        .padding(showsCardChrome ? 12 : 0)
        .background {
            if showsCardChrome {
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .fill(AppTheme.Surface.materialCard)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                            .strokeBorder(AppTheme.Border.subtle, lineWidth: 1)
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionPlaybackTimeDidChange)) {
            notification in
            if let time = notification.userInfo?["time"] as? TimeInterval {
                currentTime = time
            }
            if let playing = notification.userInfo?["isPlaying"] as? Bool {
                isPlaying = playing
            }
        }
    }

    private var headerLabel: some View {
        Text(
            usesEnhancedText
                ? "Enhanced Timestamps (\(sentences.count))"
                : "Timestamps (\(sentences.count))"
        )
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(AppTheme.Text.muted)
    }

    /// Sentence rows with active highlight + auto-scroll while playing.
    /// - Parameter scrollable: when true, wraps in ScrollView for fixed-height containers
    ///   (sidebar). When false, expands for a parent ScrollView (History detail / inline card).
    @ViewBuilder
    private func sentenceList(scrollable: Bool) -> some View {
        ScrollViewReader { proxy in
            Group {
                if scrollable {
                    ScrollView {
                        sentenceRows
                    }
                } else {
                    sentenceRows
                }
            }
            .onChange(of: activeSentenceID) { _, newID in
                guard isPlaying, let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var sentenceRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sentences) { sentence in
                sentenceRow(sentence)
            }
        }
        .padding(.top, presentation == .disclosure ? 6 : 0)
    }

    /// One tappable sentence row that seeks playback to `beginTime`.
    private func sentenceRow(_ sentence: TranscriptionTimedSentence) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .seekTranscriptionAudio,
                object: nil,
                userInfo: ["time": sentence.beginTime]
            )
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(sentence.timeRangeLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.muted)
                    .frame(width: 92, alignment: .leading)
                Text(sentence.text)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Text.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isActive(sentence)
                            ? AppTheme.Selection.fill
                            : Color.clear
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isActive(sentence)
                            ? AppTheme.Selection.border
                            : Color.clear,
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to \(sentence.beginTimeLabel)")
        .id(sentence.id)
    }

    /// Active sentence id for auto-scroll while audio is playing.
    private var activeSentenceID: Int? {
        sentences.first(where: isActive)?.id
    }

    /// Whether `sentence` covers the current playback clock.
    private func isActive(_ sentence: TranscriptionTimedSentence) -> Bool {
        let isLast = sentences.last?.id == sentence.id
        if isLast {
            return currentTime >= sentence.beginTime && currentTime <= sentence.endTime + 0.05
        }
        return currentTime >= sentence.beginTime && currentTime < sentence.endTime
    }
}
