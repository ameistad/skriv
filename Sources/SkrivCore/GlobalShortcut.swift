import AppKit
import Carbon

public enum ShortcutError: LocalizedError, Equatable {
    case invalidConfiguration
    case registrationFailed(Int32)
    case handlerFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Choose a letter or Space with Command or Control."
        case .registrationFailed(let code):
            "This shortcut could not be registered (macOS \(code)). It may be in use. Choose another combination; your previous shortcut is unchanged."
        case .handlerFailed(let code):
            "The global shortcut handler could not start (macOS \(code))."
        }
    }
}

/// Uses the system hot-key registry, without monitoring keyboard input.
@MainActor
public final class GlobalShortcut {
    public private(set) var configuration: ShortcutConfiguration?
    public private(set) var lastError: ShortcutError?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onInvoke: () -> Void
    private static let signature: OSType = 0x534B5256 // SKRV

    public init(onInvoke: @escaping () -> Void) {
        self.onInvoke = onInvoke
    }

    public func apply(_ configuration: ShortcutConfiguration) throws {
        guard configuration.isValid else { throw ShortcutError.invalidConfiguration }
        if self.configuration == configuration { lastError = nil; return }
        if !configuration.enabled {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            self.configuration = configuration
            lastError = nil
            return
        }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == 0x534B5256, identifier.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().onInvoke()
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else {
                let error = ShortcutError.handlerFailed(result)
                lastError = error
                throw error
            }
        }

        // Register the candidate first so a collision cannot discard the working shortcut.
        var candidate: EventHotKeyRef?
        let result = RegisterEventHotKey(configuration.keyCode, configuration.modifiers,
            EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &candidate)
        guard result == noErr else {
            let error = ShortcutError.registrationFailed(result)
            lastError = error
            throw error
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate
        self.configuration = configuration
        lastError = nil
    }

    /// Call during application termination before releasing this process-lifetime object.
    public func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        configuration = nil
    }
}
