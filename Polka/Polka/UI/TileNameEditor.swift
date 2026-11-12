import AppKit
import SwiftUI

/// The field a tile's name turns into for "Rename", as when renaming an icon in
/// Finder. The name starts out selected, a file's without its extension, so typing
/// replaces the name and keeps the extension. Return or Tab keeps what's typed, Esc
/// keeps the old name, and a click anywhere else keeps what's typed: `NotchPanel`
/// ends the edit for a click elsewhere in the panel, the controller for a click in
/// another app.
///
/// AppKit rather than a SwiftUI `TextField`, because choosing what's selected when
/// editing starts needs macOS 15 in SwiftUI. The panel takes the keys while this
/// shows, as it does for the link field (see `NotchPanel`).
struct TileNameEditor: NSViewRepresentable {
    /// The name the field starts with.
    let name: String
    /// The file's extension, left out of the first selection. Nil for folders and links.
    let fileExtension: String?
    let font: NSFont
    /// Every change, so the tile can size the field to what's typed.
    let onTextChange: @MainActor (String) -> Void
    /// Return, Tab or a click elsewhere, with what's typed.
    let onFinish: @MainActor (String) -> Void
    /// Esc, or the tile went away while its name was being edited.
    let onCancel: @MainActor () -> Void

    /// What's selected when editing starts, in UTF-16 units as AppKit counts: the name
    /// up to a file's extension, as Finder does, or all of it. A given name only leaves
    /// out an extension it really ends with, so "Q3 notes" is selected whole.
    static func initialSelection(of name: String, fileExtension: String?) -> NSRange {
        let text = name as NSString
        let whole = NSRange(location: 0, length: text.length)
        guard let fileExtension, !fileExtension.isEmpty else { return whole }
        let found = text.range(of: "." + fileExtension, options: [.caseInsensitive, .anchored, .backwards])
        // Nothing would be left to select for a name that's only the extension.
        guard found.location != NSNotFound, found.location > 0 else { return whole }
        return NSRange(location: 0, length: found.location)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(editor: self)
    }

    func makeNSView(context: Context) -> NameField {
        let field = NameField(string: name)
        field.initialSelection = Self.initialSelection(of: name, fileExtension: fileExtension)
        field.font = font
        field.textColor = .white
        field.alignment = .center
        // Plain text; the tile draws the field's background and focus ring.
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        // One line that scrolls sideways once it's wider than the field.
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // A light caret and the accent-colored selection on the black panel.
        field.appearance = NSAppearance(named: .darkAqua)
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Name")
        return field
    }

    func updateNSView(_ field: NameField, context: Context) {
        // Only the closures can change; the text belongs to the field while it's edited.
        context.coordinator.editor = self
    }

    /// As wide as the tile makes it, and one line of the name tall.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NameField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 60, height: field.intrinsicContentSize.height)
    }

    /// The tile can go away mid-edit, if the item expires. The edit ends then without
    /// keeping anything, a tick later, since SwiftUI is still updating its views.
    static func dismantleNSView(_ field: NameField, coordinator: Coordinator) {
        coordinator.fieldWentAway()
    }

    /// Takes the keys as soon as it's on screen, with the name selected.
    final class NameField: NSTextField {
        var initialSelection = NSRange(location: 0, length: 0)
        private var hasStarted = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !hasStarted else { return }
            // A tick later, once SwiftUI has finished placing it and the panel is key.
            DispatchQueue.main.async { [weak self] in
                self?.startEditing()
            }
        }

        private func startEditing() {
            guard let window, !hasStarted else { return }
            hasStarted = true
            // Becoming the first responder selects the whole name; then just the part
            // before a file's extension is selected instead.
            guard window.makeFirstResponder(self) else { return }
            currentEditor()?.selectedRange = initialSelection
        }

        /// Clicks place the caret even though Polka isn't the active app.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }

    /// Hears the keys that end the edit, and editing ending any other way.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var editor: TileNameEditor
        /// Set once the edit is over, so it only ends once however many ways it's told to.
        private var hasEnded = false

        init(editor: TileNameEditor) {
            self.editor = editor
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            editor.onTextChange(field.stringValue)
        }

        /// AppKit turns keys into commands like "insert a new line" before typing them,
        /// and asks here first. Returning true means the key was dealt with.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                endFromKey(control, keeping: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                endFromKey(control, keeping: false)
                return true
            default:
                return false
            }
        }

        /// Editing ended without Return or Esc: the panel ended it for a click
        /// elsewhere, which keeps what's typed, as in Finder.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSControl, !hasEnded else { return }
            hasEnded = true
            editor.onFinish(field.stringValue)
        }

        /// Return, Tab or Esc. The field lets go of the keys before it goes away, so
        /// nothing is left typing into a field that's no longer there.
        private func endFromKey(_ field: NSControl, keeping: Bool) {
            guard !hasEnded else { return }
            hasEnded = true
            let name = field.stringValue
            field.window?.makeFirstResponder(nil)
            if keeping {
                editor.onFinish(name)
            } else {
                editor.onCancel()
            }
        }

        func fieldWentAway() {
            guard !hasEnded else { return }
            hasEnded = true
            let onCancel = editor.onCancel
            DispatchQueue.main.async {
                onCancel()
            }
        }
    }
}
