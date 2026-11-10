import AppKit

/// The push-to-talk trigger: modifier keys alone (e.g. ⌥), a key with optional modifiers, or an extra mouse button.
struct Hotkey: Codable, Equatable, Sendable {
    enum Trigger: Codable, Equatable, Sendable {
        case modifiersOnly
        case key(code: UInt16, name: String)
        /// NSEvent `buttonNumber`: 2 = middle, 3 and 4 = side buttons.
        case mouseButton(Int)
    }

    var trigger: Trigger
    var modifierFlags: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    static let `default` = Hotkey(trigger: .modifiersOnly, modifierFlags: NSEvent.ModifierFlags.option.rawValue)

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(Self.relevantModifiers) }

    init(trigger: Trigger, modifiers: NSEvent.ModifierFlags) {
        self.init(trigger: trigger, modifierFlags: modifiers.intersection(Self.relevantModifiers).rawValue)
    }

    private init(trigger: Trigger, modifierFlags: UInt) {
        self.trigger = trigger
        self.modifierFlags = modifierFlags
    }

    var display: String {
        let mods = Self.symbols(modifiers)
        switch trigger {
        case .modifiersOnly: return mods.isEmpty ? "None" : mods
        case .key(_, let name): return mods + name
        case .mouseButton(let button): return mods + "Mouse \(button + 1)"
        }
    }

    // MARK: - Matching

    /// The new pressed state if `event` presses or releases this hotkey, otherwise nil.
    func pressedState(for event: NSEvent, currentlyPressed: Bool) -> Bool? {
        let held = event.modifierFlags.intersection(Self.relevantModifiers).isSuperset(of: modifiers)
        switch trigger {
        case .modifiersOnly:
            guard event.type == .flagsChanged else { return nil }
            return !modifiers.isEmpty && held
        case .key(let code, _):
            switch event.type {
            case .keyDown where event.keyCode == code && held: return true
            case .keyUp where event.keyCode == code: return false
            case .flagsChanged where currentlyPressed && !held: return false
            default: return nil
            }
        case .mouseButton(let button):
            switch event.type {
            case .otherMouseDown where event.buttonNumber == button && held: return true
            case .otherMouseUp where event.buttonNumber == button: return false
            default: return nil
            }
        }
    }

    /// Key presses of a key hotkey are swallowed so they don't also type into the chat.
    func isOwnKeyEvent(_ event: NSEvent) -> Bool {
        guard case .key(let code, _) = trigger, event.type == .keyDown || event.type == .keyUp else { return false }
        return event.keyCode == code
    }

    // MARK: - Names

    static func symbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    static func keyName(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete", 117: "Forward Delete", 53: "Esc",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19", 90: "F20", 50: "`", 10: "§",
        ]
        if let name = special[event.keyCode] { return name }
        let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return chars.isEmpty ? "Key \(event.keyCode)" : chars.uppercased()
    }
}
