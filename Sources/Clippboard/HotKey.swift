import Carbon
import ClippboardCore

struct HotKeyError: Error {
    let status: OSStatus

    var isAlreadyTaken: Bool { status == OSStatus(eventHotKeyExistsErr) }
}

/// Global hotkey via the Carbon API; works without Accessibility permission.
/// Only one instance is meant to exist: the Carbon callback reaches it through a static handler.
@MainActor
final class HotKey {
    // Read in deinit, which is not main-actor isolated; set once in init and never changed.
    nonisolated(unsafe) private let ref: EventHotKeyRef
    private static var handler: (() -> Void)?
    private static var eventHandlerInstalled = false

    init(spec: HotKeySpec, handler: @escaping () -> Void) throws {
        Self.handler = handler
        if !Self.eventHandlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // Carbon delivers hotkey events on the main thread.
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { HotKey.handler?() }
                return noErr
            }, 1, &eventType, nil, nil)
            Self.eventHandlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x434C_4950), id: 1) // 'CLIP'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotKeyError(status: status) }
        self.ref = ref
    }

    deinit {
        UnregisterEventHotKey(ref)
    }
}
