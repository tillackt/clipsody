import ClippboardCore

/// Owns the global hotkey: registration, suspension while a new one is recorded, and replacement
/// with fallback to the previous one.
@MainActor
final class HotKeyController {
    private let onPress: () -> Void
    private let onRegister: (_ label: String) -> Void
    private let onError: (_ message: String) -> Void
    private var hotKey: HotKey?
    /// The configured hotkey, also while suspended or after a failed registration.
    private(set) var current: String?
    private var isSuspended = false

    init(onPress: @escaping () -> Void, onRegister: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onPress = onPress
        self.onRegister = onRegister
        self.onError = onError
    }

    /// Registers `hotkey` in place of the current one. On failure nothing is registered and
    /// `onError` explains why.
    @discardableResult
    func register(_ hotkey: String) -> Bool {
        current = hotkey
        isSuspended = false
        guard let spec = HotKeySpec(hotkey) else {
            onError("Ungültiger Hotkey „\(hotkey)“ in config.json. Beispiel: \"cmd+option+c\"")
            return false
        }
        let label = KeyLabel.display(spec)
        // Release the old one first, otherwise re-registering the same combination counts as taken.
        hotKey = nil
        do {
            hotKey = try HotKey(spec: spec, handler: onPress)
        } catch let error as HotKeyError where error.isAlreadyTaken {
            onError("Der Hotkey \(label) ist bereits von einer anderen App belegt (z. B. Alfred).")
            return false
        } catch {
            onError("macOS hat den Hotkey \(label) abgelehnt (\(error)). Bitte eine Kombination mit ⌘ oder ⌃ wählen.")
            return false
        }
        onRegister(label)
        return true
    }

    /// The registered hotkey would swallow the keystroke while a new one is recorded.
    func suspend() {
        isSuspended = true
        hotKey = nil
    }

    func resume() {
        guard isSuspended, let current else { return }
        register(current)
    }

    /// Registers `hotkey`; if that fails, the previous one is registered again and false returned.
    /// The same hotkey only resumes, so an unchanged setting does not re-register or alert.
    func replace(with hotkey: String) -> Bool {
        guard hotkey != current else {
            resume()
            return true
        }
        let previous = current
        if register(hotkey) { return true }
        if let previous { register(previous) }
        return false
    }
}
