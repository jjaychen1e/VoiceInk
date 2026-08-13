import AppKit

/// Prevents HUD overlay panels from fighting the menu-bar extra.
///
/// SwiftUI `MenuBarExtra` nested menus flicker when another window in the same
/// app is visible and can take key/mouse. `NSMenu.didBeginTrackingNotification`
/// often does not fire for `MenuBarExtra`, so this type also watches menu-like
/// windows, status-item highlight, and a short timer while overlays are up.
enum OverlayPanelFocus {
    /// One step above `.floating` / submenu (both are 3).
    static let hudWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    private(set) static var isYielding = false
    private static var isMenuTracking = false
    private static var savedLevels: [ObjectIdentifier: NSWindow.Level] = [:]
    private static var observer: OverlayPanelFocusObserver?

    /// Starts menu-conflict observers. Safe to call more than once.
    static func installIfNeeded() {
        guard observer == nil else { return }
        observer = OverlayPanelFocusObserver()
    }

    /// Whether an overlay HUD may become the key window.
    static var canOverlayBecomeKey: Bool {
        installIfNeeded()
        return !isYielding
    }

    /// Shared non-activating HUD policy: stay visible, but do not auto-key.
    static func applyBasePolicy(to panel: NSPanel) {
        installIfNeeded()
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.canHide = false
        panel.collectionBehavior.insert(.ignoresCycle)
    }

    /// Recomputes whether overlays must yield to a visible status-item menu.
    static func sync() {
        installIfNeeded()
        let shouldYield = isMenuTracking || hasMenuLikeWindow() || isStatusItemHighlighted()
        if shouldYield {
            beginYield()
        } else {
            endYield()
        }
    }

    fileprivate static func handleMenuTrackingBegan() {
        isMenuTracking = true
        beginYield()
    }

    fileprivate static func handleMenuTrackingEnded() {
        isMenuTracking = false
        sync()
    }

    private static func beginYield() {
        isYielding = true
        for window in overlayPanels() {
            if savedLevels[ObjectIdentifier(window)] == nil {
                savedLevels[ObjectIdentifier(window)] = window.level
            }
            if window.isKeyWindow {
                window.resignKey()
            }
            window.ignoresMouseEvents = true
            // Drop below submenu level (3) so nested menus are not z-fought.
            window.level = .normal
        }
    }

    private static func endYield() {
        guard isYielding || !savedLevels.isEmpty else { return }
        for window in overlayPanels() {
            window.ignoresMouseEvents = false
            if let saved = savedLevels[ObjectIdentifier(window)] {
                window.level = saved
            }
        }
        savedLevels.removeAll()
        isYielding = false
    }

    /// True when this app currently hosts an AppKit/SwiftUI menu window.
    private static func hasMenuLikeWindow() -> Bool {
        NSApp.windows.contains { window in
            guard window.isVisible else { return false }
            if window is OverlayHUDPanel { return false }
            if window.level == .popUpMenu { return true }
            let name = NSStringFromClass(type(of: window))
            return name.contains("NSMenu")
                || name.contains("MenuBar")
                || name.contains("PopupMenu")
                || name.contains("CarbonMenu")
                || name.contains("StatusItem")
        }
    }

    /// True while the SwiftUI/AppKit status item is in the pressed/open state.
    private static func isStatusItemHighlighted() -> Bool {
        for window in NSApp.windows {
            if let button = statusBarButton(in: window), button.isHighlighted {
                return true
            }
        }
        return false
    }

    /// Finds an `NSStatusBarButton` in a window's view tree.
    private static func statusBarButton(in window: NSWindow) -> NSStatusBarButton? {
        func search(_ view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton {
                return button
            }
            for subview in view.subviews {
                if let button = search(subview) {
                    return button
                }
            }
            return nil
        }
        if let contentView = window.contentView, let button = search(contentView) {
            return button
        }
        return window.contentView as? NSStatusBarButton
    }

    private static func overlayPanels() -> [NSWindow] {
        NSApp.windows.filter { window in
            window is MiniRecorderPanel
                || window is NotchRecorderPanel
                || window is LiveTranscribePanel
        }
    }
}

/// Watches menu tracking, menu-like windows, and mouse events so overlays yield
/// even when SwiftUI `MenuBarExtra` skips `NSMenu` tracking notifications.
private final class OverlayPanelFocusObserver {
    private var localMonitor: Any?
    private var timer: Timer?

    init() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(menuDidBeginTracking),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(menuDidEndTracking),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowListMayHaveChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowListMayHaveChanged),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowListMayHaveChanged),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .mouseMoved]
        ) { event in
            OverlayPanelFocus.sync()
            return event
        }

        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            OverlayPanelFocus.sync()
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        timer?.invalidate()
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        OverlayPanelFocus.handleMenuTrackingBegan()
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        OverlayPanelFocus.handleMenuTrackingEnded()
    }

    @objc private func windowListMayHaveChanged(_ notification: Notification) {
        OverlayPanelFocus.sync()
    }
}

/// Overlay `NSPanel` that refuses key/main status while a menu is open.
class OverlayHUDPanel: NSPanel {
    override var canBecomeKey: Bool { OverlayPanelFocus.canOverlayBecomeKey }
    override var canBecomeMain: Bool { false }
}
