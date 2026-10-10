/// A key press, reduced to what the keymap needs, so the table is testable without AppKit.
public struct KeyPress: Equatable, Sendable {
    public let keyCode: UInt16
    /// The typed characters ignoring modifiers, e.g. "/" or "g".
    public let characters: String
    public let shift: Bool
    public let command: Bool
    public let control: Bool
    public let option: Bool

    public init(
        keyCode: UInt16, characters: String = "", shift: Bool = false, command: Bool = false, control: Bool = false,
        option: Bool = false
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.shift = shift
        self.command = command
        self.control = control
        self.option = option
    }
}

/// What a key does: a session command, or a view toggle the app owns.
public enum KeyAction: Equatable, Sendable {
    case cull(CullCommand)
    case toggleZoom
    case toggleGrid
    case toggleExif
}

/// The fixed one-handed keymap (REQUIREMENTS §4.3; no remapping in v1).
public enum KeyMap {
    private enum Code {
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let delete: UInt16 = 51
    }

    public static func action(for press: KeyPress) -> KeyAction? {
        // ⌘, ⌃ and ⌥ combinations belong to the menus and the system.
        guard !press.command, !press.control, !press.option else { return nil }
        switch press.keyCode {
        case Code.up: return .cull(.keep)
        case Code.down: return .cull(.reject)
        case Code.left: return .cull(press.shift ? .jump(-10) : .previous)
        case Code.right: return .cull(press.shift ? .jump(10) : .next)
        case Code.returnKey, Code.keypadEnter: return .toggleZoom
        case Code.delete: return .cull(.undo)
        default: break
        }
        // Punctuation and letters go by the typed character, so other keyboard layouts still work.
        switch press.characters.lowercased() {
        case "/": return .cull(.toggleFavourite)
        case ".": return .cull(.reset)
        case "'": return .cull(.toggleUndecidedFilter)
        case "g": return .toggleGrid
        case "i": return .toggleExif
        default: return nil
        }
    }
}
