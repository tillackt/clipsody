import Carbon
import ClippboardCore

/// Hotkey labels as printed on the user's keyboard. Hotkeys are stored as physical (ANSI) key
/// positions, so on a German layout the key code of "Z" must be shown as "Y".
@MainActor
enum KeyLabel {
    static func display(_ spec: HotKeySpec) -> String {
        spec.modifierSymbols + (spec.keyCode == UInt32(kVK_Space) ? String(localized: "Space") : character(for: spec.keyCode) ?? spec.display)
    }

    /// Character the key produces on the current keyboard layout, uppercased.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count,
                                  &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
