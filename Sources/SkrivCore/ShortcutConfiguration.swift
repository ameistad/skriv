import AppKit
import Carbon

public struct ShortcutConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(enabled: Bool = true, keyCode: UInt32, modifiers: UInt32) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = Self(keyCode: 45, modifiers: UInt32(controlKey | optionKey | cmdKey))
    public static let keys: [(name: String, code: UInt32)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3),
        ("G", 5), ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37),
        ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12), ("R", 15),
        ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7),
        ("Y", 16), ("Z", 6), ("Space", 49),
    ]

    public var isValid: Bool {
        let allowed = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        return Self.keys.contains { $0.code == keyCode }
            && modifiers & ~allowed == 0
            && modifiers & UInt32(controlKey | cmdKey) != 0
    }

    public var displayName: String {
        let symbols: [(UInt32, String)] = [
            (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
            (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘"),
        ]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined()
            + (Self.keys.first { $0.code == keyCode }?.name ?? "?")
    }
}


extension ShortcutConfiguration {
    static func parse(_ value: String) throws -> Self {
        if value.isEmpty { return .default }
        if value == "none" {
            var disabled = Self.default
            disabled.enabled = false
            return disabled
        }
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last,
              let key = keys.first(where: { $0.name.lowercased() == name }) else {
            throw ShortcutError.invalidConfiguration
        }
        let flags: [String: UInt32] = ["ctrl": UInt32(controlKey), "alt": UInt32(optionKey),
                                       "cmd": UInt32(cmdKey), "shift": UInt32(shiftKey)]
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            guard let flag = flags[part], modifiers & flag == 0 else { throw ShortcutError.invalidConfiguration }
            modifiers |= flag
        }
        let result = Self(keyCode: key.code, modifiers: modifiers)
        guard result.isValid else { throw ShortcutError.invalidConfiguration }
        return result
    }
}
