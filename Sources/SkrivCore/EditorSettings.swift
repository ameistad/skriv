import Foundation

/// Resolved presentation and editing options, derived from defaults and config.skriv.
struct EditorSettings: Equatable, Sendable {
    var background: UInt32?
    var foreground: UInt32?
    var cursorColor: UInt32?
    var selectionBackground: UInt32?
    var selectionForeground: UInt32?
    var lineNumberForeground: UInt32?
    var lineNumberBackground: UInt32?
    var number = false
    var relativeNumber = false
    var wrap = true
    var wordWrap = true
    var expandTabs = false
    var tabWidth = 8
    var indentWidth = 0
    var fontFamily = "monospace"
    var fontSize = 16.0
    var writingWidth = 72
    var normalKeyMappings: [String: String] = [:]

    // Standalone native commands and operators; sequences and scripts aren't supported.
    static let supportedNormalTargets = Set("hjklwbeWBE0$^iaIAoOxXpPuDCYGdcyvVnN/?".map(String.init))
}
