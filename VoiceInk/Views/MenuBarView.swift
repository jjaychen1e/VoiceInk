import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var mainWindowNavigation: MainWindowNavigation
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var enhancementService: AIEnhancementService
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @ObservedObject private var modeManager = ModeManager.shared
    /// Menu-only Live Transcribe state. The full controller is not observed here
    /// because caption text would rebuild the status-item `NSMenu` on every token.
    @StateObject private var liveTranslateChrome = LiveTranscribeMenuChrome()
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
        Group {
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
                        let isActive =
                            audioDeviceManager.inputMode != .systemDefault
                            && audioDeviceManager.getCurrentDevice() == device.id
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
                menuBarManager.retryLastTranscription(
                    transcriptionModelManager: transcriptionModelManager,
                    enhancementService: enhancementService
                )
            }

            Button("Copy Last Transcription") {
                menuBarManager.copyLastTranscription()
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
        let live = liveTranslateChrome.snapshot
        return Menu {
            Button {
                Task {
                    await LiveTranscribeController.shared.toggle(
                        modelContext: menuBarManager.liveTranscribeModelContext()
                    )
                }
            } label: {
                Text(live.isRunning ? "Stop" : "Start")
            }
            .disabled(
                live.isSwitchingPipeline
                    || (!live.isRunning && !live.hasAlibabaAPIKey)
            )

            if live.isRunning {
                Button("Show Caption Window") {
                    LiveTranscribeController.shared.bringCaptionWindowToFront()
                }
            }

            Divider()

            Menu {
                Button {
                    Task { await LiveTranscribeController.shared.applyTranslationEnabled(true) }
                } label: {
                    Text(live.isTranslationEnabled ? "On  ✓" : "On")
                }
                .disabled(live.isSwitchingPipeline)

                Button {
                    Task { await LiveTranscribeController.shared.applyTranslationEnabled(false) }
                } label: {
                    Text(live.isTranslationEnabled ? "Off" : "Off  ✓")
                }
                .disabled(live.isSwitchingPipeline)
            } label: {
                Text(
                    live.isTranslationEnabled
                        ? "Translate: On"
                        : "Translate: Off"
                )
            }

            Menu {
                ForEach(liveTranslateSourceLanguages, id: \.code) { language in
                    Button {
                        LiveTranscribeController.shared.sourceLanguage = language.code
                    } label: {
                        Text(
                            live.sourceLanguage == language.code
                                ? "\(language.label)  ✓"
                                : language.label
                        )
                    }
                }
            } label: {
                Text("Source: \(languageLabel(for: live.sourceLanguage, in: liveTranslateSourceLanguages))")
            }
            .disabled(live.isRunning)

            Menu {
                ForEach(liveTranslateTargetLanguages, id: \.code) { language in
                    Button {
                        LiveTranscribeController.shared.targetLanguage = language.code
                    } label: {
                        Text(
                            live.targetLanguage == language.code
                                ? "\(language.label)  ✓"
                                : language.label
                        )
                    }
                }
            } label: {
                Text("Target: \(languageLabel(for: live.targetLanguage, in: liveTranslateTargetLanguages))")
            }
            .disabled(live.isRunning || !live.isTranslationEnabled)

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
        let live = liveTranslateChrome.snapshot
        if live.isRunning {
            return live.isTranslationEnabled
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
