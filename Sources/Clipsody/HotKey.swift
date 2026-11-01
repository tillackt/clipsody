import Carbon
import ClipsodyCore

struct HotKeyError: Error {
    let status: OSStatus

    var isAlreadyTaken: Bool { status == OSStatus(eventHotKeyExistsErr) }
}

/// Global hotkey via the Carbon API; works without Accessibility permission. Each hotkey has its
/// own ID: the panel's (1) and, while the fill bar is open, "paste next" (2). The Carbon callback
/// reaches them through a static table.
@MainActor
final class HotKey {
    enum Slot: UInt32 {
        case panel = 1
        case fillNext = 2
    }

    // Read in deinit, which is not main-actor isolated; set once in init and never changed.
    nonisolated(unsafe) private let ref: EventHotKeyRef
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerInstalled = false

    init(spec: HotKeySpec, id: Slot = .panel, handler: @escaping () -> Void) throws {
        if !Self.eventHandlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // Carbon delivers hotkey events on the main thread.
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr else { return status }
                MainActor.assumeIsolated { HotKey.handlers[pressed.id]?() }
                return noErr
            }, 1, &eventType, nil, nil)
            Self.eventHandlerInstalled = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_4950), id: id.rawValue) // 'CLIP'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotKeyError(status: status) }
        self.ref = ref
        Self.handlers[id.rawValue] = handler
    }

    deinit {
        // The handler stays in the table; an unregistered hotkey never fires, and the next
        // registration with this ID replaces it.
        UnregisterEventHotKey(ref)
    }
}
