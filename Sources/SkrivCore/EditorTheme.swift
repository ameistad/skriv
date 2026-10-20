import AppKit

/// Built-in plain-text colors from ameistad/etterglod.nvim.
/// Keep this palette available without loading Neovim or reading user configuration.
/// The Neovim settings importer will supply resolved overrides in phase 3.
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
    /// Support Neovim's common family:hSIZE form, trying fallbacks in order.
    static func resolve(_ guifont: String) -> NSFont? {
        for candidate in guifont.split(separator: ",") {
            let parts = candidate.split(separator: ":").map(String.init)
            guard let name = parts.first, !name.isEmpty else { continue }
            var size: CGFloat = 16
            var supported = true
            for option in parts.dropFirst() {
                if option.hasPrefix("h"), let value = Double(option.dropFirst()), (6...72).contains(value) {
                    size = CGFloat(value)
                } else { supported = false }
            }
            guard supported else { continue }
            let family = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "\\ ", with: " ")
            if let font = NSFont(name: family, size: size) { return font }
            if ["monospace", "monospace regular"].contains(family.lowercased()) {
                return .monospacedSystemFont(ofSize: size, weight: .regular)
            }
        }
        return nil
    }
}
