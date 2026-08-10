import AppKit
import SwiftUI

/// Owns the optional companion-video playback window for History.
final class LinkedVideoWindowController: NSObject, NSWindowDelegate {
    static let shared = LinkedVideoWindowController()

    private var videoWindow: NSWindow?
    private let windowIdentifier = NSUserInterfaceItemIdentifier(
        "com.prakashjoshipax.voiceink.linkedVideoWindow"
    )
    private let windowAutosaveName = NSWindow.FrameAutosaveName("VoiceInkLinkedVideoWindowFrame")

    /// Whether the companion video window is currently open.
    var isOpen: Bool { videoWindow != nil }

    private override init() {
        super.init()
    }

    /// Shows or replaces the linked-video window for the given media and sentences.
    @MainActor
    func show(
        videoURL: URL,
        sentences: [TranscriptionTimedSentence],
        title: String,
        startAt: TimeInterval = 0,
        usesEnhancedText: Bool = false
    ) {
        AppPresentationPolicy.activateForUserFacingWindow()

        let rootView = LinkedVideoPlayerView(
            videoURL: videoURL,
            sentences: sentences,
            startAt: startAt,
            title: title,
            usesEnhancedText: usesEnhancedText
        )
        let hostingController = NSHostingController(rootView: rootView)

        if let existingWindow = videoWindow {
            existingWindow.contentViewController = hostingController
            existingWindow.title = title
            if existingWindow.isMiniaturized {
                existingWindow.deminiaturize(nil)
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = title
        window.identifier = windowIdentifier
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName(windowAutosaveName)
        if !window.setFrameUsingName(windowAutosaveName) {
            window.center()
        }

        videoWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            window.identifier == windowIdentifier
        else { return }
        videoWindow = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            window.identifier == windowIdentifier
        else { return }
        AppPresentationPolicy.activateForUserFacingWindow()
    }
}
