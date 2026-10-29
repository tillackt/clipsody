import Carbon
import ClippboardCore

/// Global hotkey via the Carbon API; works without Accessibility permission.
/// Only one instance is meant to exist: the Carbon callback reaches it through a static handler.
@MainActor
final class HotKey {
    // Read in deinit, which is not main-actor isolated; only ever set during init on the main thread.
    nonisolated(unsafe) private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?
    private static var eventHandlerInstalled = false

    init?(spec: HotKeySpec, handler: @escaping () -> Void) {
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
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
