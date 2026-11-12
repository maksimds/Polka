import AppKit

/// Borderless, transparent, non-activating panel that sits over the notch.
///
/// It never becomes key, so it never steals focus from the app you're using. The
/// one exception is the link field ("Add New", "Link"), which needs the keys while
/// you type. A non-activating panel can be the key window without making Polka the
/// active app, so the app you were in keeps its menu bar and its windows stay put.
final class NotchPanel: NSPanel {
    /// True only while the shelf shows the link field. The controller sets it.
    var acceptsKeyboard = false

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

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    /// Command shortcuts while you type a link. Polka isn't the active app then, so
    /// the menu bar shows the other app's menus, not Polka's. The editing shortcuts
    /// are handled here, and every other one is swallowed, so Cmd-Q can't quit a
    /// Polka you can't see the menus of. Esc and Return still reach the field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard acceptsKeyboard else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        if let action = Self.editingAction(for: event.charactersIgnoringModifiers ?? "",
                                           shift: flags.contains(.shift)) {
            NSApp.sendAction(action, to: nil, from: self)
        }
        return true
    }

    private static func editingAction(for key: String, shift: Bool) -> Selector? {
        switch (key.lowercased(), shift) {
        case ("x", false): return #selector(NSText.cut(_:))
        case ("c", false): return #selector(NSText.copy(_:))
        case ("v", false): return #selector(NSText.paste(_:))
        case ("a", false): return #selector(NSText.selectAll(_:))
        case ("z", false): return Selector(("undo:"))
        case ("z", true): return Selector(("redo:"))
        default: return nil
        }
    }
}
