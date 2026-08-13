import CoreAudio
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var engine: VoiceInkEngine
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var whisperModelManager: WhisperModelManager
    @EnvironmentObject var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var mainWindowNavigation: MainWindowNavigation
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var aiService: AIService
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @ObservedObject private var modeManager = ModeManager.shared
    @ObservedObject private var liveTranscribeController = LiveTranscribeController.shared
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false

    private let liveTranslateSourceLanguages: [(code: String, label: String)] = [
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

    private let liveTranslateTargetLanguages: [(code: String, label: String)] = [
        ("zh", "Chinese"),
        ("en", "English"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("ru", "Russian"),
    ]

    var body: some View {
        VStack {
            if hasCompletedOnboardingV2 {
                completedOnboardingMenu
            } else {
                onboardingMenu
            }
        }
    }

    private var onboardingMenu: some View {
        Group {
            Button("Complete Onboarding") {
                showMainWindow()
            }

            Divider()

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var completedOnboardingMenu: some View {
        Group {
            Button("Toggle Recorder") {
                recorderUIManager.handleToggleRecorderPanelNotification()
            }

            Divider()

            Menu {
                ForEach(modeManager.enabledConfigurations) { config in
                    Button {
                        modeManager.setActiveConfiguration(config)
                    } label: {
                        let isActive = modeManager.currentEffectiveConfiguration?.id == config.id
                        Text(isActive ? "\(config.name)  ✓" : config.name)
                    }
                }

                if modeManager.enabledConfigurations.isEmpty {
                    Text("No modes available")
                        .foregroundColor(.secondary)
                }

                Divider()

                Button("Manage Modes") {
                    showMainWindowAndNavigate(to: "Modes")
                }

                Button("Manage Models") {
                    showMainWindowAndNavigate(to: "AI Models")
                }
            } label: {
                HStack {
                    Image(systemName: "sparkles.square.fill.on.square")
                        .font(.system(size: 11, weight: .medium))
                    let activeMode = modeManager.currentEffectiveConfiguration
                    Text(String(format: String(localized: "Mode: %@"), activeMode?.name ?? String(localized: "None")))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                }
            }

            Menu {
                Button {
                    audioDeviceManager.selectInputMode(.systemDefault)
                } label: {
                    let isActive = audioDeviceManager.inputMode == .systemDefault
                    Text(isActive ? "\(systemDefaultAudioInputTitle)  ✓" : systemDefaultAudioInputTitle)
                }

                if !audioDeviceManager.availableDevices.isEmpty {
                    Divider()
                }

                ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                    Button {
                        audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
                    } label: {
                        let isActive = isPinnedAudioInputDevice(device.id)
                        Text(isActive ? "\(device.name)  ✓" : device.name)
                    }
                }

                if audioDeviceManager.availableDevices.isEmpty {
                    Text("No devices available")
                        .foregroundColor(.secondary)
                }
            } label: {
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .medium))
                    Text("Audio Input")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                }
            }

            liveTranslateMenu

            Divider()

            Button("Retry Last Transcription") {
                LastTranscriptionService.retryLastTranscription(
                    from: engine.modelContext,
                    transcriptionModelManager: transcriptionModelManager,
                    serviceRegistry: engine.serviceRegistry,
                    enhancementService: enhancementService
                )
            }

            Button("Copy Last Transcription") {
                LastTranscriptionService.copyLastTranscription(from: engine.modelContext)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("History") {
                menuBarManager.openHistoryWindow()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button(menuBarManager.isMenuBarOnly ? "Show Dock Icon" : "Hide Dock Icon") {
                let shouldShowMainWindow = menuBarManager.isMenuBarOnly
                menuBarManager.toggleMenuBarOnly()

                if shouldShowMainWindow {
                    showMainWindow()
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLoginManager.isEnabled },
                    set: { launchAtLoginManager.setEnabled($0) }
                )
            )
            .disabled(launchAtLoginManager.isUpdating)

            Divider()

            Button("Settings") {
                showMainWindowAndNavigate(to: "Settings")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check for Updates") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Menu Bar entry for Live Translate with nested Translate / language menus.
    private var liveTranslateMenu: some View {
        Menu {
            Button {
                Task {
                    await liveTranscribeController.toggle(modelContext: engine.modelContext)
                }
            } label: {
                Text(liveTranscribeController.isRunning ? "Stop" : "Start")
            }
            .disabled(
                liveTranscribeController.isSwitchingPipeline
                    || (!liveTranscribeController.isRunning && !liveTranscribeController.hasAlibabaAPIKey)
            )

            if liveTranscribeController.isRunning {
                Button("Show Caption Window") {
                    liveTranscribeController.bringCaptionWindowToFront()
                }
            }

            Divider()

            Menu {
                Button {
                    Task { await liveTranscribeController.applyTranslationEnabled(true) }
                } label: {
                    Text(liveTranscribeController.isTranslationEnabled ? "On  ✓" : "On")
                }
                .disabled(liveTranscribeController.isSwitchingPipeline)

                Button {
                    Task { await liveTranscribeController.applyTranslationEnabled(false) }
                } label: {
                    Text(liveTranscribeController.isTranslationEnabled ? "Off" : "Off  ✓")
                }
                .disabled(liveTranscribeController.isSwitchingPipeline)
            } label: {
                Text(
                    liveTranscribeController.isTranslationEnabled
                        ? "Translate: On"
                        : "Translate: Off"
                )
            }

            Menu {
                ForEach(liveTranslateSourceLanguages, id: \.code) { language in
                    Button {
                        liveTranscribeController.sourceLanguage = language.code
                    } label: {
                        Text(
                            liveTranscribeController.sourceLanguage == language.code
                                ? "\(language.label)  ✓"
                                : language.label
                        )
                    }
                }
            } label: {
                Text("Source: \(languageLabel(for: liveTranscribeController.sourceLanguage, in: liveTranslateSourceLanguages))")
            }
            .disabled(liveTranscribeController.isRunning)

            Menu {
                ForEach(liveTranslateTargetLanguages, id: \.code) { language in
                    Button {
                        liveTranscribeController.targetLanguage = language.code
                    } label: {
                        Text(
                            liveTranscribeController.targetLanguage == language.code
                                ? "\(language.label)  ✓"
                                : language.label
                        )
                    }
                }
            } label: {
                Text("Target: \(languageLabel(for: liveTranscribeController.targetLanguage, in: liveTranslateTargetLanguages))")
            }
            .disabled(liveTranscribeController.isRunning || !liveTranscribeController.isTranslationEnabled)

            Divider()

            Button("Open Live Transcribe…") {
                showMainWindowAndNavigate(to: "Live Transcribe")
            }
        } label: {
            HStack {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 11, weight: .medium))
                Text(liveTranslateMenuTitle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
            }
        }
    }

    private var liveTranslateMenuTitle: String {
        if liveTranscribeController.isRunning {
            return liveTranscribeController.isTranslationEnabled
                ? String(localized: "Live Translate: On")
                : String(localized: "Live Translate: Captions")
        }
        return String(localized: "Live Translate")
    }

    /// Menu title for following macOS's current default input device.
    private var systemDefaultAudioInputTitle: String {
        guard let name = audioDeviceManager.getSystemDefaultDeviceName() else {
            return String(localized: "System Default")
        }
        return String(format: String(localized: "System Default (%@)"), name)
    }

    /// Whether this device is the pinned custom/priority input, not merely the live system default.
    private func isPinnedAudioInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        audioDeviceManager.inputMode != .systemDefault
            && audioDeviceManager.getCurrentDevice() == deviceID
    }

    /// Resolves a language code to its menu label.
    private func languageLabel(
        for code: String,
        in options: [(code: String, label: String)]
    ) -> String {
        options.first(where: { $0.code == code })?.label ?? code.uppercased()
    }

    private func showMainWindow() {
        let existingWindow = WindowManager.shared.currentMainWindow()
        menuBarManager.activateForPresentedWindow()

        if existingWindow == nil {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            openWindow(id: AppWindowID.main)
        } else {
            openWindow(id: AppWindowID.main)
            WindowManager.shared.showMainWindow()
        }
    }

    private func showMainWindowAndNavigate(to destination: String) {
        mainWindowNavigation.navigate(to: destination)
        showMainWindow()
    }
}
