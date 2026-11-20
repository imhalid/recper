import Carbon.HIToolbox

/// Global hotkeys (Carbon RegisterEventHotKey). No Accessibility permission needed.
/// Only ⌥⇧R is permanent; tool hotkeys are registered for the session and released afterwards
/// (⌥⇧+letter normally types a special character; it is not taken from the user outside a session).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var handler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    /// Optional key-up actions (tap vs. hold, e.g. the radial menu).
    private var releases: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    /// The Carbon callback is a C function pointer: the instance is found via this global.
    nonisolated(unsafe) private static var instance: HotKeys?

    private init() {
        HotKeys.instance = self
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            MainActor.assumeIsolated {
                if released { HotKeys.instance?.releases[id]?() } else { HotKeys.instance?.actions[id]?() }
            }
            return noErr
        }, 2, &specs, nil, &handler)
    }

    static let optShift = UInt32(optionKey | shiftKey)

    /// Registers and returns its ID.
    @discardableResult
    func register(_ keyCode: Int, _ mods: UInt32 = optShift, onRelease: (() -> Void)? = nil, _ action: @escaping () -> Void) -> UInt32 {
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x5243_5052), id: id) // 'RCPR'
        if RegisterEventHotKey(UInt32(keyCode), mods, hk, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[id] = ref
            actions[id] = action
            releases[id] = onRelease
        }
        return id
    }

    func unregister(_ ids: [UInt32]) {
        for id in ids {
            if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
            actions[id] = nil
            releases[id] = nil
        }
    }
}
