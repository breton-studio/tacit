import Foundation

/// A key combination: a Carbon virtual keycode plus a modifier set, as used for a keystroke
/// action's binding. `TacitCore` stays Foundation-only, so this has no dependency on Carbon or
/// AppKit — `keyCode` is just the `UInt16` that those frameworks' `kVK_*` constants use.
public struct KeyChord: Codable, Equatable, Sendable {
    public struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command  = Modifiers(rawValue: 1 << 0)
        public static let shift    = Modifiers(rawValue: 1 << 1)
        public static let option   = Modifiers(rawValue: 1 << 2)
        public static let control  = Modifiers(rawValue: 1 << 3)
    }

    /// Carbon virtual keycode (kVK_*).
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Renders as modifier symbols in the fixed order ⌃⌥⇧⌘ followed by the key cap name,
    /// e.g. "⇧⌘Z". A keycode with no cap name in `KeyChord.capNames` renders as "key 0xNN"
    /// (uppercase, two-digit hex).
    public var display: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + Self.capName(for: keyCode)
    }

    private static func capName(for keyCode: UInt16) -> String {
        capNames[keyCode] ?? String(format: "key 0x%02X", keyCode)
    }

    /// Carbon virtual keycode → key cap name, covering letters A–Z, digits 0–9, and the named
    /// keys the app needs to display (Return, Tab, Space, Delete, Escape, arrows). Copied from
    /// the standard US ANSI `kVK_*` layout.
    static let capNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
        25: "9", 29: "0",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
    ]
}
