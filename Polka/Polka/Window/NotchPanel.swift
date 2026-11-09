import AppKit

/// Borderless, transparent, non-activating panel that sits over the notch.
/// It never becomes key, so it never steals focus from the app you're using.
final class NotchPanel: NSPanel {
    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: backingStoreType,
                   defer: flag)

        isFloatingPanel = true
        // Above the menu bar so the panel can cover the notch area.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        // Every Space, including full-screen apps; not part of Cmd-Tab or Mission Control.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Clicks pass through while collapsed; the controller flips this per state.
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
