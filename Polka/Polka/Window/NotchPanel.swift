import AppKit

/// Borderless, transparent, non-activating panel that sits over the notch.
///
/// It never becomes key, so it never steals focus from the app you're using. The
/// two exceptions are the link field ("Add New", "Link") and a tile's name being
/// edited ("Rename"), which need the keys while you type. A non-activating panel can
/// be the key window without making Polka the active app, so the app you were in
/// keeps its menu bar and its windows stay put.
final class NotchPanel: NSPanel {
    /// True only while the shelf shows the link field or a tile is being renamed.
    /// The controller sets it.
    var acceptsKeyboard = false
    /// True while a tile is being renamed. A click anywhere else in the panel then
    /// ends the edit before it does anything else, keeping what's typed, as a click
    /// away does in Finder. (Clicking a view that can't type, like a tile, wouldn't
    /// end it on its own.) The controller sets it.
    var endsEditingOnClickElsewhere = false

    override func sendEvent(_ event: NSEvent) {
        if endsEditingOnClickElsewhere, Self.isPress(event), let field = editedField,
           !field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }

    private static func isPress(_ event: NSEvent) -> Bool {
        [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
    }

    /// The text field being typed in. While a field is edited, the keys go to a text
    /// view AppKit lends it, the "field editor", whose delegate is the field itself.
    private var editedField: NSView? {
        (firstResponder as? NSTextView)?.delegate as? NSView
    }

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

    /// Command shortcuts while you type a link or a name. Polka isn't the active app then, so
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
