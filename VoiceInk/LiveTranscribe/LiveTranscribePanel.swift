import AppKit
import Combine
import SwiftUI

enum LiveTranscribePanelSettingsKeys {
    static let frame = "LiveTranscribePanelFrame"
}

/// Floating non-activating caption panel for Live Transcribe.
final class LiveTranscribePanel: NSPanel {
    static let resizeCornerSize: CGFloat = 28
    static let titleBarHeight: CGFloat = 34
    /// Bottom AppKit control strip (close + Translate). Right corner left for resize.
    static let bottomControlsHeight: CGFloat = 34

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    private func configurePanel() {
        isFloatingPanel = true
        canHide = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = true
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        sharingType = .none
        minSize = NSSize(width: 420, height: 120)
        maxSize = NSSize(width: 1600, height: 700)
        acceptsMouseMovedEvents = true
    }

    static func calculateWindowMetrics() -> NSRect {
        if let saved = savedFrame(), isFrameVisible(saved) {
            return saved
        }

        let width: CGFloat = 840
        let height: CGFloat = 180
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }
        let visibleFrame = screen.visibleFrame
        let xPosition = visibleFrame.midX - (width / 2)
        let yPosition = visibleFrame.minY + 28
        return NSRect(x: xPosition, y: yPosition, width: width, height: height)
    }

    func show() {
        setFrame(Self.calculateWindowMetrics(), display: true)
        orderFrontRegardless()
    }

    func persistFrame() {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: LiveTranscribePanelSettingsKeys.frame)
    }

    private static func savedFrame() -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: LiveTranscribePanelSettingsKeys.frame) else {
            return nil
        }
        let rect = NSRectFromString(raw)
        guard rect.width >= 420, rect.height >= 120 else { return nil }
        return rect
    }

    private static func isFrameVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}

/// AppKit title-bar strip that moves the panel with a dedicated drag loop.
final class LiveTranscribeTitleDragView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // Intentionally empty — this view is an invisible hit target only.
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        NSCursor.openHand.set()
        let dragStartMouse = NSEvent.mouseLocation
        let dragStartFrame = window.frame

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .infinity,
            mode: .eventTracking
        ) { trackedEvent, stop in
            guard let trackedEvent else {
                stop.pointee = true
                return
            }
            if trackedEvent.type == .leftMouseUp {
                stop.pointee = true
                return
            }

            let current = NSEvent.mouseLocation
            var frame = dragStartFrame
            frame.origin.x = dragStartFrame.origin.x + (current.x - dragStartMouse.x)
            frame.origin.y = dragStartFrame.origin.y + (current.y - dragStartMouse.y)
            window.setFrame(frame, display: true, animate: false)
            NSCursor.openHand.set()
        }

        (window as? LiveTranscribePanel)?.persistFrame()
        NSCursor.arrow.set()
    }
}

/// NSButton that accepts the first click while another app is active.
private final class LiveTranscribeFirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Bottom-left AppKit controls (close + pause + Translate). Same hit reliability as the resize grip.
final class LiveTranscribeBottomControlsView: NSView {
    private weak var controller: LiveTranscribeController?
    private let closeButton = LiveTranscribeFirstMouseButton(title: "", target: nil, action: nil)
    private let pauseButton = LiveTranscribeFirstMouseButton(title: "", target: nil, action: nil)
    private let translateButton = LiveTranscribeFirstMouseButton(title: "", target: nil, action: nil)
    private var translateEnabledObserver: AnyCancellable?
    private var pausedObserver: AnyCancellable?
    private var switchingObserver: AnyCancellable?

    override var isOpaque: Bool { false }

    init(controller: LiveTranscribeController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureButtons()
        bind(controller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) {
            return hit
        }
        return nil
    }

    override func layout() {
        super.layout()
        let buttonHeight: CGFloat = 24
        let y = max(0, (bounds.height - buttonHeight) / 2)
        closeButton.frame = NSRect(x: 10, y: y, width: 28, height: buttonHeight)
        pauseButton.frame = NSRect(x: 42, y: y, width: 28, height: buttonHeight)
        translateButton.frame = NSRect(x: 74, y: y, width: 28, height: buttonHeight)
    }

    private func configureButtons() {
        closeButton.target = self
        closeButton.action = #selector(stopSession)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close"
        )
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        closeButton.imagePosition = .imageOnly
        closeButton.toolTip = "Stop Live Transcribe"

        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.setButtonType(.pushOnPushOff)
        pauseButton.bezelStyle = .inline
        pauseButton.isBordered = false
        pauseButton.focusRingType = .none
        pauseButton.title = ""
        pauseButton.imagePosition = .imageOnly
        pauseButton.toolTip = "Pause transcription"

        translateButton.target = self
        translateButton.action = #selector(toggleTranslation)
        translateButton.setButtonType(.pushOnPushOff)
        translateButton.bezelStyle = .inline
        translateButton.isBordered = false
        translateButton.focusRingType = .none
        translateButton.title = ""
        translateButton.imagePosition = .imageOnly
        translateButton.toolTip = "Toggle translation"

        addSubview(closeButton)
        addSubview(pauseButton)
        addSubview(translateButton)
        refreshPauseAppearance()
        refreshTranslateAppearance()
    }

    private func bind(_ controller: LiveTranscribeController) {
        translateEnabledObserver = controller.$isTranslationEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshTranslateAppearance()
            }
        pausedObserver = controller.$isPaused
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshPauseAppearance()
                self?.refreshTranslateAppearance()
            }
        switchingObserver = controller.$isSwitchingPipeline
            .receive(on: RunLoop.main)
            .sink { [weak self] isSwitching in
                self?.translateButton.isEnabled = !isSwitching && self?.controller?.isPaused != true
                self?.translateButton.alphaValue = (isSwitching || self?.controller?.isPaused == true) ? 0.5 : 1
                self?.pauseButton.isEnabled = !isSwitching
                self?.pauseButton.alphaValue = isSwitching ? 0.5 : 1
            }
    }

    /// Updates the pause/resume icon to match controller state.
    private func refreshPauseAppearance() {
        let paused = controller?.isPaused == true
        pauseButton.state = paused ? .on : .off
        pauseButton.image = NSImage(
            systemSymbolName: paused ? "play.fill" : "pause.fill",
            accessibilityDescription: paused ? "Resume" : "Pause"
        )
        pauseButton.contentTintColor = paused
            ? NSColor.systemYellow
            : NSColor.white.withAlphaComponent(0.7)
        pauseButton.toolTip = paused
            ? "Resume transcription"
            : "Pause transcription (keep window open)"
    }

    /// Updates the two-state Translate icon button to match controller state.
    private func refreshTranslateAppearance() {
        let enabled = controller?.isTranslationEnabled == true
        let paused = controller?.isPaused == true
        translateButton.state = enabled ? .on : .off
        translateButton.image = NSImage(
            systemSymbolName: enabled ? "character.bubble.fill" : "character.bubble",
            accessibilityDescription: "Translate"
        )
        translateButton.contentTintColor = enabled
            ? NSColor.controlAccentColor
            : NSColor.white.withAlphaComponent(0.7)
        translateButton.isEnabled = !paused && controller?.isSwitchingPipeline != true
        translateButton.alphaValue = translateButton.isEnabled ? 1 : 0.5
        translateButton.toolTip = enabled
            ? "Turn off translation (captions only)"
            : "Turn on EN→ZH translation"
    }

    @objc private func togglePause() {
        guard let controller else { return }
        let shouldPause = pauseButton.state == .on
        Task { @MainActor in
            await controller.setPaused(shouldPause)
        }
    }

    @objc private func toggleTranslation() {
        guard let controller else { return }
        // pushOnPushOff flips state before the action; sync to the desired enabled value.
        let shouldEnable = translateButton.state == .on
        Task { @MainActor in
            await controller.applyTranslationEnabled(shouldEnable)
        }
    }

    @objc private func stopSession() {
        guard let controller else { return }
        Task { @MainActor in
            await controller.stop()
        }
    }
}

/// Hosts SwiftUI content, title drag, bottom controls, and bottom-right resize.
final class LiveTranscribeChromeContainer: NSView {
    private let cornerSize: CGFloat
    private let titleBarHeight: CGFloat
    private let bottomControlsHeight: CGFloat
    private let hostedView: NSView
    private let titleDragView = LiveTranscribeTitleDragView()
    private let bottomControlsView: LiveTranscribeBottomControlsView
    private var trackingArea: NSTrackingArea?

    init(
        hostedView: NSView,
        controller: LiveTranscribeController,
        cornerSize: CGFloat,
        titleBarHeight: CGFloat,
        bottomControlsHeight: CGFloat
    ) {
        self.hostedView = hostedView
        self.cornerSize = cornerSize
        self.titleBarHeight = titleBarHeight
        self.bottomControlsHeight = bottomControlsHeight
        self.bottomControlsView = LiveTranscribeBottomControlsView(controller: controller)
        super.init(frame: .zero)
        addSubview(hostedView)
        addSubview(titleDragView)
        addSubview(bottomControlsView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        hostedView.frame = bounds
        titleDragView.frame = NSRect(
            x: 0,
            y: max(0, bounds.height - titleBarHeight),
            width: bounds.width,
            height: min(titleBarHeight, bounds.height)
        )
        // Leave the bottom-right resize corner free.
        let controlsWidth = max(0, bounds.width - cornerSize)
        bottomControlsView.frame = NSRect(
            x: 0,
            y: 0,
            width: controlsWidth,
            height: min(bottomControlsHeight, bounds.height)
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: cornerRect,
            options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if cornerRect.contains(point) {
            return self
        }
        if bottomControlsView.frame.contains(point),
           let controlsHit = bottomControlsView.hitTest(convert(point, to: bottomControlsView)) {
            return controlsHit
        }
        if titleDragView.frame.contains(point) {
            return titleDragView
        }
        return hostedView.hitTest(convert(point, to: hostedView)) ?? super.hitTest(point)
    }

    override func mouseMoved(with event: NSEvent) {
        if isInCorner(convert(event.locationInWindow, from: nil)) {
            setResizeCursor()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isInCorner(convert(event.locationInWindow, from: nil)) {
            setResizeCursor()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard isInCorner(local), let window else { return }

        setResizeCursor()
        let dragStartMouse = NSEvent.mouseLocation
        let dragStartFrame = window.frame

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .infinity,
            mode: .eventTracking
        ) { trackedEvent, stop in
            guard let trackedEvent else {
                stop.pointee = true
                return
            }
            if trackedEvent.type == .leftMouseUp {
                stop.pointee = true
                return
            }

            let current = NSEvent.mouseLocation
            let dx = current.x - dragStartMouse.x
            let dy = current.y - dragStartMouse.y

            var frame = dragStartFrame
            frame.size.width = dragStartFrame.size.width + dx
            frame.size.height = dragStartFrame.size.height - dy
            frame.size.width = min(max(frame.size.width, window.minSize.width), window.maxSize.width)
            frame.size.height = min(max(frame.size.height, window.minSize.height), window.maxSize.height)
            frame.origin.y = dragStartFrame.maxY - frame.size.height

            window.setFrame(frame, display: true, animate: false)
            self.setResizeCursor()
        }

        (window as? LiveTranscribePanel)?.persistFrame()
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if isInCorner(pointer) {
            setResizeCursor()
        } else {
            NSCursor.arrow.set()
        }
    }

    private var cornerRect: NSRect {
        NSRect(
            x: max(0, bounds.width - cornerSize),
            y: 0,
            width: min(cornerSize, bounds.width),
            height: min(cornerSize, bounds.height)
        )
    }

    private func isInCorner(_ point: NSPoint) -> Bool {
        cornerRect.contains(point)
    }

    private func setResizeCursor() {
        if #available(macOS 15.0, *) {
            NSCursor.frameResize(position: .bottomRight, directions: .all).set()
        } else {
            NSCursor.crosshair.set()
        }
    }
}

/// Creates and owns the Live Transcribe floating HUD.
@MainActor
final class LiveTranscribeWindowManager: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private var panel: LiveTranscribePanel?
    private weak var controller: LiveTranscribeController?

    func bind(to controller: LiveTranscribeController) {
        self.controller = controller
    }

    func show() {
        // Recreate chrome so layout/control changes apply after updates.
        if panel == nil {
            initializeWindow()
        }
        panel?.show()
    }

    func hide() {
        panel?.persistFrame()
        panel?.orderOut(nil)
    }

    func destroyWindow() {
        panel?.persistFrame()
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }

    func windowDidResize(_ notification: Notification) {
        panel?.persistFrame()
    }

    func windowDidMove(_ notification: Notification) {
        panel?.persistFrame()
    }

    private func initializeWindow() {
        destroyWindow()
        guard let controller else { return }

        let metrics = LiveTranscribePanel.calculateWindowMetrics()
        let newPanel = LiveTranscribePanel(contentRect: metrics)
        newPanel.delegate = self

        let view = LiveTranscribeHUDView(controller: controller)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.wantsLayer = true

        let container = LiveTranscribeChromeContainer(
            hostedView: hostingController.view,
            controller: controller,
            cornerSize: LiveTranscribePanel.resizeCornerSize,
            titleBarHeight: LiveTranscribePanel.titleBarHeight,
            bottomControlsHeight: LiveTranscribePanel.bottomControlsHeight
        )
        container.frame = NSRect(origin: .zero, size: metrics.size)
        container.autoresizingMask = [.width, .height]

        newPanel.contentView = container
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }
}

/// Caption content shown inside the floating Live Transcribe panel.
struct LiveTranscribeHUDView: View {
    @ObservedObject var controller: LiveTranscribeController

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                titleBar

                Group {
                    if controller.isTranslationEnabled {
                        bilingualCaptions
                    } else {
                        captionColumn(
                            title: "EN",
                            text: controller.sourceText.isEmpty
                                ? controller.listeningPlaceholder
                                : controller.sourceText,
                            emphasis: true
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, LiveTranscribePanel.bottomControlsHeight + 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            resizeGrip
                .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Visual title bar only. Full-width AppKit drag overlay handles moving.
    private var titleBar: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 28, height: 3)
                .padding(.trailing, 2)

            Circle()
                .fill(controller.isPaused ? Color.yellow : Color.red)
                .frame(width: 8, height: 8)

            Text(titleBarLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: LiveTranscribePanel.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .allowsHitTesting(false)
    }

    private var titleBarLabel: String {
        if controller.isPaused {
            return String(localized: "Paused")
        }
        return controller.isTranslationEnabled
            ? String(localized: "Live Translate")
            : String(localized: "Live Transcribe")
    }

    private var resizeGrip: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: CGFloat(10 - index * 2), height: 1.5)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: 14, height: 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bilingualCaptions: some View {
        HStack(alignment: .top, spacing: 0) {
            captionColumn(
                title: "EN",
                text: controller.sourceText.isEmpty
                    ? controller.listeningPlaceholder
                    : controller.sourceText,
                emphasis: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1)
                .padding(.vertical, 2)
                .padding(.horizontal, 10)

            captionColumn(
                title: "中文",
                text: controller.translatedText.isEmpty
                    ? controller.translationPlaceholder
                    : controller.translatedText,
                emphasis: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func captionColumn(title: String, text: String, emphasis: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.6)

            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: emphasis ? 16 : 14))
                            .foregroundStyle(.white.opacity(emphasis ? 0.95 : 0.72))
                            .multilineTextAlignment(.leading)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: max(geo.size.width, 1), alignment: .leading)
                            .id("bottom")
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.08),
                                .init(color: .black, location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .onChange(of: text) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .transaction { $0.disablesAnimations = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
