import AppKit
import Carbon.HIToolbox

/// Cmd-V and Cmd-C while the pointer is over the open shelf: Cmd-V pastes onto it,
/// like the + menu's Paste, and Cmd-C copies the selected tiles, like their Copy.
///
/// The panel never takes the keys, so a keystroke goes to the app you're in, and
/// Polka never sees it. System hot keys are how it gets these two: macOS hands the
/// keystroke to the app that registered it instead of the front app. They need no
/// permission (a key monitor would need Accessibility, and couldn't stop the front
/// app pasting or copying too), and they don't activate Polka or make the panel key.
///
/// While they're on, Cmd-V and Cmd-C reach no other app, so the controller turns them
/// on only for as long as the pointer is over the open shelf (`isWanted`). The rest of
/// the time they work as usual everywhere.
///
/// The keys are the V and C keys' positions, which is how Command shortcuts already
/// work on Russian and other non-Latin layouts. Cmd-Shift-V and the like aren't matched.
@MainActor
final class ShelfShortcuts {
    /// Run on the main thread when the key is pressed while the shortcuts are on.
    var onPaste: (@MainActor () -> Void)?
    var onCopy: (@MainActor () -> Void)?

    private enum Key: UInt32, CaseIterable {
        case paste = 1
        case copy = 2

        var keyCode: Int {
            switch self {
            case .paste: kVK_ANSI_V
            case .copy: kVK_ANSI_C
            }
        }
    }

    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Registers or releases the hot keys. Setting the same value again does nothing,
    /// so this can be set on every pointer move.
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            if isOn { register() } else { unregister() }
        }
    }

    /// When Cmd-V and Cmd-C belong to Polka: the shelf is open and the pointer is over
    /// it. Not while a name is being typed or the link field is up, where the panel has
    /// the keys and they act on the field's text. Not while a menu is open (the menu
    /// has the keys then) or Share is up. And not while a message keeps the shelf open
    /// with the pointer away, since you're back in your other app by then.
    nonisolated static func isWanted(state: NotchState,
                                     isRenaming: Bool,
                                     isMenuOpen: Bool,
                                     isSharing: Bool,
                                     isPointerOverPanel: Bool) -> Bool {
        state == .expanded && !isRenaming && !isMenuOpen && !isSharing && isPointerOverPanel
    }

    private func register() {
        installHandlerIfNeeded()
        for key in Key.allCases {
            var hotKey: EventHotKeyRef?
            let id = EventHotKeyID(signature: hotKeySignature, id: key.rawValue)
            let status = RegisterEventHotKey(UInt32(key.keyCode), UInt32(cmdKey), id,
                                             GetApplicationEventTarget(), 0, &hotKey)
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
            } else {
                Log.input.error("Couldn't register a shelf shortcut (\(key.rawValue, privacy: .public)): \(status, privacy: .public)")
            }
        }
    }

    private func unregister() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
    }

    fileprivate func pressed(_ id: UInt32) {
        switch Key(rawValue: id) {
        case .paste: onPaste?()
        case .copy: onCopy?()
        case nil: break
        }
    }

    /// One handler for the app's lifetime; only the hot keys come and go. Carbon
    /// delivers hot key events on the main thread's run loop.
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == hotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            let shortcuts = Unmanaged<ShelfShortcuts>.fromOpaque(userData).takeUnretainedValue()
            let key = id.id
            MainActor.assumeIsolated { shortcuts.pressed(key) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr {
            Log.input.error("Couldn't install the hot key handler: \(status, privacy: .public)")
        }
    }
}

/// "PlkV": tells Polka's hot keys apart from any other the app might receive.
private let hotKeySignature: OSType = 0x506C_6B56
