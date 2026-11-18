import AppKit
import Carbon.HIToolbox

/// Cmd-V while the pointer is over the open shelf pastes onto it, like the + menu's
/// Paste.
///
/// The panel never takes the keys, so a keystroke goes to the app you're in, and
/// Polka never sees it. A system hot key is how it gets this one: macOS hands the
/// keystroke to the app that registered it instead of the front app. It needs no
/// permission (a key monitor would need Accessibility, and couldn't stop the front
/// app pasting too), and it doesn't activate Polka or make the panel key.
///
/// While it's on, Cmd-V reaches no other app, so the controller turns it on only for
/// as long as the pointer is over the open shelf (`isWanted`). The rest of the time
/// Cmd-V works as usual everywhere.
///
/// The key is the V key's position, which is how Command shortcuts already work on
/// Russian and other non-Latin layouts. Cmd-Shift-V and the like aren't matched.
@MainActor
final class PasteShortcut {
    /// Runs on the main thread when Cmd-V is pressed while the shortcut is on.
    var onPress: (@MainActor () -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers or releases the hot key. Setting the same value again does nothing,
    /// so this can be set on every pointer move.
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            if isOn { register() } else { unregister() }
        }
    }

    /// When Cmd-V belongs to Polka: the shelf is open and the pointer is over it.
    /// Not while a name is being typed or the link field is up, where the panel has
    /// the keys and Cmd-V pastes into the field. Not while a menu is open (the menu
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
        let id = EventHotKeyID(signature: hotKeySignature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            hotKey = nil
            Log.input.error("Couldn't register the Cmd-V shortcut: \(status, privacy: .public)")
        }
    }

    private func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    /// One handler for the app's lifetime; only the hot key comes and goes. Carbon
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
            let shortcut = Unmanaged<PasteShortcut>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr {
            Log.input.error("Couldn't install the hot key handler: \(status, privacy: .public)")
        }
    }
}

/// "PlkV": tells Polka's hot key apart from any other the app might receive.
private let hotKeySignature: OSType = 0x506C_6B56
