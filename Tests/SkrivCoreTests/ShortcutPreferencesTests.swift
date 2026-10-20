import Foundation
import Carbon
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct ShortcutPreferencesTests {
    @Test func atomicRoundTripAndDisabledState() throws {
        let name = "SkrivTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ShortcutPreferences(defaults: defaults)
        #expect(preferences.configuration == .default)
        let changed = ShortcutConfiguration(enabled: false, keyCode: 49, modifiers: UInt32(controlKey | shiftKey))
        try preferences.save(changed)
        #expect(ShortcutPreferences(defaults: defaults).configuration == changed)
        #expect(defaults.dictionaryRepresentation()[ShortcutPreferences.storageKey] is Data)
    }

    @Test func corruptionAndInvalidStoredValuesFallBack() throws {
        let name = "SkrivTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ShortcutPreferences(defaults: defaults)
        defaults.set(Data("bad json".utf8), forKey: ShortcutPreferences.storageKey)
        #expect(preferences.configuration == .default)
        defaults.set(try JSONEncoder().encode(ShortcutConfiguration(keyCode: 999, modifiers: 0)),
                     forKey: ShortcutPreferences.storageKey)
        #expect(preferences.configuration == .default)
        #expect(throws: ShortcutError.invalidConfiguration) {
            try preferences.save(ShortcutConfiguration(keyCode: 45, modifiers: 0))
        }
        #expect(preferences.configuration == .default)
    }

    @Test func validationRejectsUnsupportedKeysAndModifierBits() {
        #expect(ShortcutConfiguration.default.isValid)
        #expect(ShortcutConfiguration.default.displayName == "⌃⌥⌘N")
        #expect(!ShortcutConfiguration(keyCode: 45, modifiers: UInt32(optionKey)).isValid)
        #expect(!ShortcutConfiguration(keyCode: 45, modifiers: UInt32(cmdKey) | 0x80000000).isValid)
        #expect(!ShortcutConfiguration(keyCode: 255, modifiers: UInt32(cmdKey)).isValid)
    }
}
