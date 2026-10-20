import AppKit
import Carbon
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct GlobalShortcutTests {
    @Test func registeredHandlerDispatchesOnlyItsHotKeyEvent() throws {
        _ = NSApplication.shared
        var invocations = 0
        let shortcut = GlobalShortcut { invocations += 1 }
        defer { shortcut.stop() }
        for key in ShortcutConfiguration.keys {
            let candidate = ShortcutConfiguration(keyCode: key.code,
                modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
            if (try? shortcut.apply(candidate)) != nil { break }
        }
        _ = try #require(shortcut.configuration)
        var event: EventRef?
        #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                            GetCurrentEventTime(), EventAttributes(kEventAttributeNone), &event) == noErr)
        let created = try #require(event)
        defer { ReleaseEvent(created) }
        var identifier = EventHotKeyID(signature: 0x534B5256, id: 999)
        #expect(SetEventParameter(created, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
        _ = SendEventToEventTarget(created, GetApplicationEventTarget())
        #expect(invocations == 0)
        identifier.id = 1
        #expect(SetEventParameter(created, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
        #expect(SendEventToEventTarget(created, GetApplicationEventTarget()) == noErr)
        #expect(invocations == 1)
    }

    @Test func collisionPreservesWorkingRegistrationAndDisableReleasesIt() throws {
        _ = NSApplication.shared
        let first = GlobalShortcut(onInvoke: {})
        let second = GlobalShortcut(onInvoke: {})
        defer { first.stop(); second.stop() }
        let candidates = ShortcutConfiguration.keys.map {
            ShortcutConfiguration(keyCode: $0.code, modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
        }
        // Select available combinations so user-assigned shortcuts are never replaced.
        for candidate in candidates {
            if (try? first.apply(candidate)) != nil { break }
        }
        let firstChoice = try #require(first.configuration)
        for candidate in candidates where candidate != firstChoice {
            if (try? second.apply(candidate)) != nil { break }
        }
        let secondChoice = try #require(second.configuration)
        do {
            try second.apply(firstChoice)
            Issue.record("Registering another owner's shortcut unexpectedly succeeded.")
        } catch let error as ShortcutError {
            guard case .registrationFailed = error else {
                Issue.record("Expected collision failure, received \(error).")
                return
            }
        }
        #expect(second.configuration == secondChoice)
        var disabled = firstChoice
        disabled.enabled = false
        try first.apply(disabled)
        try second.apply(firstChoice)
        #expect(second.configuration == firstChoice)
        #expect(first.configuration == disabled)
        // Applying the same registered choice again is idempotent.
        try second.apply(firstChoice)
        #expect(second.lastError == nil)
    }
}
