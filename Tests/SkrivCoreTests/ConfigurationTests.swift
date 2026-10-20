import Foundation
import Carbon
import Testing
@testable import SkrivCore

struct ConfigurationTests {
    @Test func parsesCommentsQuotesColorsAndRepeatedBindings() throws {
        let settings = try SkrivConfiguration.parse("""
          # Entire line comment
        font-family = "SF Mono"
        font-size=18.5
        writing-width = 80
        wrap = false
        word-wrap = false
        line-numbers = both
        expand-tabs = true
        tab-width = 4
        indent-width = 2
        background = #102030
        foreground = aabbcc
        cursor-color = fedcba
        selection-background = 010203
        selection-foreground = 040506
        line-number-foreground = 070809
        line-number-background = 0a0b0c
        global-shortcut = ctrl+shift+space
        keybind = H=h
        keybind = L=l
        keybind = H=0
        """)
        #expect(settings.editor.fontFamily == "SF Mono")
        #expect(settings.editor.fontSize == 18.5)
        #expect(settings.editor.writingWidth == 80)
        #expect(!settings.editor.wrap && !settings.editor.wordWrap)
        #expect(settings.editor.number && settings.editor.relativeNumber)
        #expect(settings.editor.expandTabs)
        #expect(settings.editor.tabWidth == 4 && settings.editor.indentWidth == 2)
        #expect(settings.editor.background == 0x102030 && settings.editor.foreground == 0xAABBCC)
        #expect(settings.editor.cursorColor == 0xFEDCBA)
        #expect(settings.editor.selectionBackground == 0x010203 && settings.editor.selectionForeground == 0x040506)
        #expect(settings.editor.lineNumberForeground == 0x070809 && settings.editor.lineNumberBackground == 0x0A0B0C)
        #expect(settings.editor.normalKeyMappings == ["H": "0", "L": "l"])
        #expect(settings.shortcut == ShortcutConfiguration(keyCode: 49, modifiers: UInt32(controlKey | shiftKey)))
    }

    @Test func emptyValuesResetDefaultsAndLastScalarWins() throws {
        let settings = try SkrivConfiguration.parse("""
        font-family = Menlo
        font-family =
        font-size = 20
        font-size =
        writing-width = 100
        writing-width =
        background = ffffff
        background =
        line-numbers = both
        line-numbers =
        wrap = false
        wrap =
        word-wrap = false
        word-wrap =
        expand-tabs = true
        expand-tabs =
        tab-width = 4
        tab-width =
        indent-width = 2
        indent-width =
        global-shortcut = none
        global-shortcut =
        keybind = H=h
        keybind = L=l
        keybind =
        """)
        #expect(settings == SkrivConfiguration())
        let repeated = try SkrivConfiguration.parse("font-size = 12\nfont-size = 24")
        #expect(repeated.editor.fontSize == 24)
        #expect(try SkrivConfiguration.parse("global-shortcut = none").shortcut.enabled == false)
        #expect(try SkrivConfiguration.parse("line-numbers = relative").editor.number == false)
        #expect(try SkrivConfiguration.parse("line-numbers = absolute").editor.relativeNumber == false)
    }

    @Test func reportsLineNumbersAndRejectsUnsupportedSyntaxAndValues() throws {
        let invalid = [
            "font-size 18", "font-size = nan", "font-size = inf", "font-size = 0", "font-size = 73",
            "font-family = \"Menlo", "wrap = yes", "wrap = true # inline comments aren't supported",
            "tab-width = 0", "indent-width = -1", "writing-width = 0", "line-numbers = true",
            "background = #fff", "background = 12345g", "background = -12345",
            "unknown = value", "= value", "keybind = 2=h", "keybind = jk=i", "keybind = H=gg",
            "keybind = H=:quit", "keybind = H", "global-shortcut = alt+n",
            "global-shortcut = cmd+cmd+n", "global-shortcut = cmd++n", "global-shortcut = cmd+F99",
        ]
        for entry in invalid {
            #expect(throws: ConfigurationError.self) { try SkrivConfiguration.parse(entry) }
        }
        do {
            _ = try SkrivConfiguration.parse("# comment\r\n\r\nfont-size = nope")
            Issue.record("Expected a parse error")
        } catch let error as ConfigurationError {
            #expect(error.message.hasPrefix("Line 3:"))
            #expect(error.message.contains("font-size"))
        }
        // Hashes and equals within values aren't interpreted as comments or executable syntax.
        #expect(try SkrivConfiguration.parse("font-family = a#b=c").editor.fontFamily == "a#b=c")
    }

    @Test func templateUsesDefaultsAndHasValidExamples() throws {
        #expect(try SkrivConfiguration.parse(SkrivConfiguration.template) == SkrivConfiguration())
        let examples = SkrivConfiguration.template.components(separatedBy: "\n")
            .filter { $0.hasPrefix("# ") && $0.contains(" =") }
            .map { String($0.dropFirst(2)) }.joined(separator: "\n")
        _ = try SkrivConfiguration.parse(examples)
    }

    @Test func validatesShortcutPhysicalKeysAndModifierBits() throws {
        #expect(ShortcutConfiguration.default.isValid)
        #expect(ShortcutConfiguration.default.displayName == "⌃⌥⌘N")
        #expect(try ShortcutConfiguration.parse("ctrl+alt+cmd+N") == .default)
        #expect(!ShortcutConfiguration(keyCode: 45, modifiers: UInt32(optionKey)).isValid)
        #expect(!ShortcutConfiguration(keyCode: 45, modifiers: UInt32(cmdKey) | 0x80000000).isValid)
        #expect(!ShortcutConfiguration(keyCode: 255, modifiers: UInt32(cmdKey)).isValid)
    }
}

@Suite(.serialized)
@MainActor
struct ConfigurationControllerTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.skriv")
    }

    @Test func fileOwnsSettingsAndReloadFailureKeepsPreviousConfiguration() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = ConfigurationController(url: url)
        var appliedShortcut: ShortcutConfiguration?
        try controller.reload { appliedShortcut = $0 }
        #expect(controller.current == SkrivConfiguration())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try controller.createIfMissing()
        try "font-size = 20\nglobal-shortcut = none\n".write(to: url, atomically: true, encoding: .utf8)
        try controller.reload { appliedShortcut = $0 }
        let valid = controller.current
        #expect(valid.editor.fontSize == 20)
        #expect(appliedShortcut?.enabled == false)
        try "font-size = 28\nglobal-shortcut = ctrl+cmd+m\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(controller.current == valid, "Editing the file alone doesn't reload open notes.")
        #expect(throws: ShortcutError.registrationFailed(-1)) {
            try controller.reload { _ in throw ShortcutError.registrationFailed(-1) }
        }
        #expect(controller.current == valid, "A shortcut conflict must not partially apply editor preferences.")
        try "font-size = 30\nunknown = nope".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ConfigurationError.self) {
            try controller.reload { _ in Issue.record("Invalid settings must never reach registration.") }
        }
        #expect(controller.current == valid)
        try "font-size = 24".write(to: url, atomically: true, encoding: .utf8)
        try controller.reload { appliedShortcut = $0 }
        #expect(controller.current.editor.fontSize == 24)
        #expect(appliedShortcut == .default, "Removing an override restores its default.")
        try FileManager.default.removeItem(at: url)
        try controller.reload { appliedShortcut = $0 }
        #expect(controller.current == SkrivConfiguration())
    }

    @Test func openCreatesTemplateOnceAndPreservesUserBytes() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = ConfigurationController(url: url)
        try controller.createIfMissing()
        #expect(try String(contentsOf: url, encoding: .utf8) == SkrivConfiguration.template)
        let custom = "# My spacing and comments\nfont-size=21\n"
        try custom.write(to: url, atomically: true, encoding: .utf8)
        try controller.createIfMissing()
        try controller.reload { _ in }
        #expect(try String(contentsOf: url, encoding: .utf8) == custom)
        #expect(controller.current.editor.fontSize == 21)
    }

    @Test func corruptOversizeAndUnreadableFilesCannotBecomeDefaultsSilently() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = ConfigurationController(url: url)
        try controller.createIfMissing()
        for data in [Data([0xFF]), Data(repeating: 32, count: SkrivConfiguration.maximumBytes + 1)] {
            try data.write(to: url)
            #expect(throws: ConfigurationError.self) { try controller.reload { _ in } }
            #expect(controller.current == SkrivConfiguration())
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try controller.reload { _ in } }
    }
}
