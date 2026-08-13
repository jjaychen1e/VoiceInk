import AppKit
import Testing

@testable import VoiceInk

@MainActor
struct OverlayPanelFocusTests {
    @Test func hudWindowLevelDoesNotMatchSubmenuLevel() {
        #expect(OverlayPanelFocus.hudWindowLevel != .floating)
        #expect(OverlayPanelFocus.hudWindowLevel != .tornOffMenu)
        #expect(OverlayPanelFocus.hudWindowLevel.rawValue > NSWindow.Level.floating.rawValue)
    }

    @Test func miniAndLivePanelsUseHudLevelAndYieldDuringMenuTracking() {
        OverlayPanelFocus.installIfNeeded()

        let mini = MiniRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80))
        let live = LiveTranscribePanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80))
        mini.orderFrontRegardless()
        live.orderFrontRegardless()
        defer {
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
            mini.orderOut(nil)
            live.orderOut(nil)
            mini.close()
            live.close()
        }

        #expect(mini.level == OverlayPanelFocus.hudWindowLevel)
        #expect(live.level == OverlayPanelFocus.hudWindowLevel)
        #expect(mini.becomesKeyOnlyIfNeeded)
        #expect(live.becomesKeyOnlyIfNeeded)
        #expect(mini.canBecomeMain == false)
        #expect(live.canBecomeMain == false)
        #expect(mini.ignoresMouseEvents == false)
        #expect(OverlayPanelFocus.canOverlayBecomeKey)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)

        #expect(OverlayPanelFocus.isYielding)
        #expect(OverlayPanelFocus.canOverlayBecomeKey == false)
        #expect(mini.canBecomeKey == false)
        #expect(live.canBecomeKey == false)
        #expect(mini.ignoresMouseEvents)
        #expect(live.ignoresMouseEvents)
        #expect(mini.level == .normal)
        #expect(live.level == .normal)

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)

        #expect(OverlayPanelFocus.isYielding == false)
        #expect(mini.ignoresMouseEvents == false)
        #expect(live.ignoresMouseEvents == false)
        #expect(mini.canBecomeKey)
        #expect(live.canBecomeKey)
        #expect(mini.level == OverlayPanelFocus.hudWindowLevel)
        #expect(live.level == OverlayPanelFocus.hudWindowLevel)
    }

    @Test func notchPanelKeepsStatusBarLevelAndYieldsDuringMenuTracking() {
        OverlayPanelFocus.installIfNeeded()

        let notch = NotchRecorderPanel(contentRect: .zero)
        notch.orderFrontRegardless()
        defer {
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
            notch.orderOut(nil)
            notch.close()
        }

        #expect(notch.level == .statusBar + 3)
        #expect(notch.becomesKeyOnlyIfNeeded)
        #expect(notch.canBecomeMain == false)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)

        #expect(notch.canBecomeKey == false)
        #expect(notch.ignoresMouseEvents)
        #expect(notch.level == .normal)

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)

        #expect(notch.ignoresMouseEvents == false)
        #expect(notch.level == .statusBar + 3)
    }

    @Test func overlayYieldsWhenPopupMenuWindowAppearsWithoutTrackingNotification() {
        OverlayPanelFocus.installIfNeeded()

        let mini = MiniRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80))
        mini.orderFrontRegardless()
        let menuWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        menuWindow.level = .popUpMenu
        menuWindow.orderFrontRegardless()
        defer {
            menuWindow.orderOut(nil)
            menuWindow.close()
            mini.orderOut(nil)
            mini.close()
            OverlayPanelFocus.sync()
        }

        OverlayPanelFocus.sync()

        #expect(mini.ignoresMouseEvents)
        #expect(mini.level == .normal)

        menuWindow.orderOut(nil)
        OverlayPanelFocus.sync()

        #expect(mini.ignoresMouseEvents == false)
        #expect(mini.level == OverlayPanelFocus.hudWindowLevel)
    }
}
