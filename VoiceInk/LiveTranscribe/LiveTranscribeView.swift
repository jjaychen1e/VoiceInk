import AppKit
import SwiftData
import SwiftUI

/// Sidebar page for starting Live Transcribe sessions (system audio + optional translation).
struct LiveTranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var controller = LiveTranscribeController.shared
    @State private var isRequestingPermission = false

    private let languageOptions: [(code: String, label: String)] = [
        ("en", "English"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("ru", "Russian"),
        ("auto", "Auto-detect"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controlsCard
                permissionsCard
                tipsCard
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            controller.refreshPermissions()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Transcribe")
                .font(.system(size: 26, weight: .bold))
            Text(
                "Captures system audio and shows a floating caption window. Translation is optional and uses Qwen LiveTranslate (English → Chinese by default)."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button {
                    Task { await controller.toggle(modelContext: modelContext) }
                } label: {
                    Label(
                        controller.isRunning ? "Stop" : "Start",
                        systemImage: controller.isRunning ? "stop.fill" : "play.fill"
                    )
                    .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isRunning ? .red : AppTheme.Accent.primary)
                .disabled(controller.isRunning == false && !controller.hasAlibabaAPIKey)

                if controller.isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(controller.statusMessage ?? "Running")
                            .foregroundStyle(.secondary)
                    }

                    if controller.activeCorpusTermCount > 0 || controller.activeCorpusPhraseCount > 0 {
                        Text(
                            "Corpus: \(controller.activeCorpusTermCount) terms"
                                + (controller.isTranslationEnabled
                                    ? ", \(controller.activeCorpusPhraseCount) phrases"
                                    : "")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }

            Toggle(
                isOn: Binding(
                    get: { controller.isTranslationEnabled },
                    set: { newValue in
                        Task { await controller.applyTranslationEnabled(newValue) }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translate")
                    Text(
                        controller.isRunning
                            ? "Can be changed while running; switches the realtime model."
                            : "Uses Qwen LiveTranslate. Leave off for captions only."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .disabled(controller.isSwitchingPipeline)
            .toggleStyle(.switch)

            HStack(alignment: .top, spacing: 16) {
                languagePicker(
                    title: "Source",
                    selection: $controller.sourceLanguage,
                    includeAuto: true
                )

                if controller.isTranslationEnabled {
                    languagePicker(
                        title: "Target",
                        selection: $controller.targetLanguage,
                        includeAuto: false
                    )
                }
            }
            .disabled(controller.isRunning)

            if let errorMessage = controller.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Requirements")
                .font(.headline)

            requirementRow(
                title: "Screen Recording",
                detail: "Needed to capture system audio without interrupting Teams share.",
                isOK: controller.hasScreenRecordingPermission
            ) {
                Button("Request Access") {
                    Task {
                        isRequestingPermission = true
                        _ = await controller.requestScreenRecordingPermission()
                        isRequestingPermission = false
                    }
                }
                .disabled(isRequestingPermission || controller.hasScreenRecordingPermission)

                Button("Open Settings") {
                    controller.openScreenRecordingSettings()
                }
            }

            requirementRow(
                title: "Alibaba API Key",
                detail: "DashScope key used by qwen3-asr-flash-realtime / LiveTranslate.",
                isOK: controller.hasAlibabaAPIKey
            ) {
                Button("Open AI Models") {
                    MainWindowNavigation.shared.navigate(to: .models)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
            Text("• Dictionary vocabulary → ASR `corpus.text` bias.")
            Text("• Word Replacements → LiveTranslate `corpus.phrases` (source → target).")
            Text("• Qwen-Audio instant hotwords are not used on this path.")
            Text("• Does not mute system audio or steal Teams focus.")
            Text("• Change Translate / languages only while stopped.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(16)
        .background(cardBackground)
    }

    /// Language picker used for source / target configuration.
    private func languagePicker(
        title: String,
        selection: Binding<String>,
        includeAuto: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Picker(title, selection: selection) {
                ForEach(languageOptions.filter { includeAuto || $0.code != "auto" }, id: \.code) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 180, alignment: .leading)
        }
    }

    /// Single requirement row with status indicator and actions.
    private func requirementRow(
        title: String,
        detail: String,
        isOK: Bool,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isOK ? Color.green : Color.orange)
                .font(.system(size: 16))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    actions()
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(AppTheme.Surface.window.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
            )
    }
}
