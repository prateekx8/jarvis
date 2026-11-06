import Carbon

/// System-wide hotkey with press and release events. Carbon hotkeys need no Accessibility permission.
final class HotKey {
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}
    private(set) var registered = false
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(keyCode: Int, modifiers: Int) {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            let me = Unmanaged<HotKey>.fromOpaque(ctx!).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { me.onDown() } else { me.onUp() }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let id = EventHotKeyID(signature: OSType(0x5642_5253), id: 1) // "VBRS"
        registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
