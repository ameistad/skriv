import Foundation

struct SkrivConfiguration: Equatable, Sendable {
    var editor = EditorSettings()

    static let maximumBytes = 65_536

    /// A deliberately flat, non-executable format: split at the first =, then parse by key.
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= maximumBytes else {
            throw ConfigurationError("Configuration exceeds 64 KiB.")
        }
        var result = Self()
        let defaults = Self()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            func invalid(_ message: String) -> ConfigurationError {
                ConfigurationError("Line \(index + 1): \(message)")
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw invalid("Expected key = value.")
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") || value.hasSuffix("\"") {
                guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
                    throw invalid("Unmatched quote for \(key).")
                }
                value = String(value.dropFirst().dropLast())
            }
            func boolean(_ fallback: Bool) throws -> Bool {
                if value.isEmpty { return fallback }
                guard value == "true" || value == "false" else {
                    throw invalid("\(key) must be true or false.")
                }
                return value == "true"
            }
            func integer(_ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
                if value.isEmpty { return fallback }
                guard let number = Int(value), range.contains(number) else {
                    throw invalid("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound).")
                }
                return number
            }
            func color() throws -> UInt32? {
                if value.isEmpty { return nil }
                let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
                guard hex.utf8.count == 6, hex.utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }), let rgb = UInt32(hex, radix: 16) else {
                    throw invalid("\(key) must be a six-digit RGB color, such as 1e1e1e or #1e1e1e.")
                }
                return rgb
            }
            switch key {
            case "font-family": result.editor.fontFamily = value.isEmpty ? defaults.editor.fontFamily : value
            case "font-size":
                if value.isEmpty { result.editor.fontSize = defaults.editor.fontSize }
                else {
                    guard let size = Double(value), (6...72).contains(size) else {
                        throw invalid("font-size must be a number from 6 to 72.")
                    }
                    result.editor.fontSize = size
                }
            case "writing-width": result.editor.writingWidth = try integer(defaults.editor.writingWidth, 20...500)
            case "wrap": result.editor.wrap = try boolean(defaults.editor.wrap)
            case "word-wrap": result.editor.wordWrap = try boolean(defaults.editor.wordWrap)
            case "expand-tabs": result.editor.expandTabs = try boolean(defaults.editor.expandTabs)
            case "tab-width": result.editor.tabWidth = try integer(defaults.editor.tabWidth, 1...9999)
            case "indent-width": result.editor.indentWidth = try integer(defaults.editor.indentWidth, 0...9999)
            case "line-numbers":
                switch value {
                case "", "none": result.editor.number = false; result.editor.relativeNumber = false
                case "absolute": result.editor.number = true; result.editor.relativeNumber = false
                case "relative": result.editor.number = false; result.editor.relativeNumber = true
                case "both": result.editor.number = true; result.editor.relativeNumber = true
                default: throw invalid("line-numbers must be none, absolute, relative, or both.")
                }
            case "background": result.editor.background = try color()
            case "foreground": result.editor.foreground = try color()
            case "cursor-color": result.editor.cursorColor = try color()
            case "selection-background": result.editor.selectionBackground = try color()
            case "selection-foreground": result.editor.selectionForeground = try color()
            case "line-number-foreground": result.editor.lineNumberForeground = try color()
            case "line-number-background": result.editor.lineNumberBackground = try color()
            case "keybind":
                if value.isEmpty { result.editor.normalKeyMappings.removeAll(); continue }
                guard let equals = value.firstIndex(of: "=") else {
                    throw invalid("keybind must be a single Normal-mode key mapping, such as H=h.")
                }
                let source = String(value[..<equals]).trimmingCharacters(in: .whitespaces)
                let target = String(value[value.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                guard source.count == 1,
                      !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
                      !"0123456789".contains(source), EditorSettings.supportedNormalTargets.contains(target) else {
                    throw invalid("Unsupported keybind: use one non-digit key and a supported single-key Normal command.")
                }
                result.editor.normalKeyMappings[source] = target
            default: throw invalid("Unknown setting “\(key)”.")
            }
        }
        return result
    }

    static let template = """
    # Skriv configuration — ~/.config/skriv/config.skriv
    # Save, then choose Skriv → Reload Configuration (Command–Shift–comma).
    # Only overrides are needed. An empty value restores the built-in default.
    # Comments occupy their own line; optional double quotes enclose literal values.
    # Repeated settings use the last value. Repeated keybind entries add mappings.

    # Font: installed family or PostScript name; monospace uses the system font.
    # An unavailable font falls back to the system monospace font at font-size.
    # font-family = monospace
    # font-size = 16
    # writing-width = 72

    # wrap = true
    # word-wrap = true
    # line-numbers = none
    # Choices: none, absolute, relative, both.
    # tab-width = 8
    # indent-width = 0
    # Zero indent-width follows tab-width.
    # expand-tabs = false

    # Colors are six hexadecimal digits, optionally prefixed with #.
    # Empty colors use the built-in Etterglød palette or the editor foreground/background.
    # background = 1e1e1e
    # foreground = c5c8c6
    # cursor-color = c07020
    # selection-background = 676b71
    # selection-foreground =
    # line-number-foreground =
    # line-number-background =

    # Nonrecursive single-key Normal-mode mappings; Insert/Visual/operator keys are unchanged.
    # Targets: h j k l w b e W B E 0 $ ^ i a I A o O x X p P u D C Y G d c y v V n N / ?
    # keybind = H=h
    # keybind = L=l
    # keybind =
    # An empty keybind clears all preceding mappings.

    """
}

struct ConfigurationError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The file is authoritative; this object holds only the last successfully applied configuration.
@MainActor
final class ConfigurationController {
    let url: URL
    private(set) var current = SkrivConfiguration()

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/skriv/config.skriv")) {
        self.url = url
    }

    func reload() throws {
        // Publish only after the entire file has been read and validated.
        current = try read()
    }

    private func read() throws -> SkrivConfiguration {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return SkrivConfiguration()
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: SkrivConfiguration.maximumBytes + 1) ?? Data()
        guard data.count <= SkrivConfiguration.maximumBytes else {
            throw ConfigurationError("Configuration exceeds 64 KiB.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigurationError("Configuration must be UTF-8 text.")
        }
        return try SkrivConfiguration.parse(text)
    }

    /// Only the explicit Open Configuration action creates a file. Existing bytes are never rewritten.
    func createIfMissing() throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(SkrivConfiguration.template.utf8).write(to: url, options: .withoutOverwriting)
    }
}
