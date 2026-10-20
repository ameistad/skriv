import AppKit

/// Built-in plain-text colors from ameistad/etterglod.nvim.
/// Keep this palette available without reading user configuration.
@MainActor
enum EditorTheme {
    static let background = color(0x1E1E1E)          // Normal.bg
    static let foreground = color(0xC5C8C6)          // Normal.fg
    static let cursor = color(0xC07020)              // Cursor.bg
    static let selectionBackground = color(0x676B71) // Visual.bg

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

@MainActor
enum EditorFont {
    static func resolve(_ family: String, size: Double) -> NSFont? {
        guard (6...72).contains(size) else { return nil }
        if family == "monospace" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: family, size: size)
    }
}
