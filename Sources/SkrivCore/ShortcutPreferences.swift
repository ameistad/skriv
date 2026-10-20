import AppKit
import Carbon

public struct ShortcutConfiguration: Codable, Equatable, Sendable {
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

/// The sole owner of the user's shortcut choice. Registration is separate runtime state.
@MainActor
public final class ShortcutPreferences {
    static let storageKey = "globalShortcut.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var configuration: ShortcutConfiguration {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
              decoded.isValid else { return .default }
        return decoded
    }

    public func save(_ configuration: ShortcutConfiguration) throws {
        guard configuration.isValid else { throw ShortcutError.invalidConfiguration }
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.storageKey)
    }
}

@MainActor
public final class ShortcutPreferencesWindowController: NSWindowController {
    private let preferences: ShortcutPreferences
    private let shortcut: GlobalShortcut
    private let enabled = NSButton(checkboxWithTitle: "Enable global shortcut", target: nil, action: nil)
    private let key = NSPopUpButton()
    private let control = NSButton(checkboxWithTitle: "Control ⌃", target: nil, action: nil)
    private let option = NSButton(checkboxWithTitle: "Option ⌥", target: nil, action: nil)
    private let command = NSButton(checkboxWithTitle: "Command ⌘", target: nil, action: nil)
    private let shift = NSButton(checkboxWithTitle: "Shift ⇧", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")

    public init(preferences: ShortcutPreferences, shortcut: GlobalShortcut) {
        self.preferences = preferences
        self.shortcut = shortcut
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 330),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Global Shortcut"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        key.addItems(withTitles: ShortcutConfiguration.keys.map(\.name))
        key.setAccessibilityLabel("Shortcut key")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let modifiers = NSStackView(views: [control, option, shift, command])
        modifiers.spacing = 12
        let keyRow = NSStackView(views: [NSTextField(labelWithString: "Key"), key])
        keyRow.spacing = 12
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyShortcut))
        apply.keyEquivalent = "\r"
        let reset = NSButton(title: "Use Default", target: self, action: #selector(resetShortcut))
        let actions = NSStackView(views: [reset, apply])
        actions.spacing = 12
        let info = NSTextField(wrappingLabelWithString:
            "Opens a fresh note from any app. Choose Command or Control plus a key. Letter names refer to physical US keyboard positions.")
        info.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [enabled, modifiers, keyRow, info, status, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
        ])
        window.center()
        populate(preferences.configuration)
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func showWindow(_ sender: Any?) {
        populate(preferences.configuration)
        updateStatus()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func populate(_ configuration: ShortcutConfiguration) {
        enabled.state = configuration.enabled ? .on : .off
        key.selectItem(at: ShortcutConfiguration.keys.firstIndex { $0.code == configuration.keyCode } ?? 13)
        for (button, bit) in modifierButtons {
            button.state = configuration.modifiers & bit != 0 ? .on : .off
        }
    }

    private var modifierButtons: [(NSButton, UInt32)] {
        [(control, UInt32(controlKey)), (option, UInt32(optionKey)),
         (command, UInt32(cmdKey)), (shift, UInt32(shiftKey))]
    }

    private func updateStatus() {
        status.stringValue = shortcut.lastError?.localizedDescription
            ?? (shortcut.configuration?.enabled == true
                ? "Active: \(shortcut.configuration!.displayName)" : "Global shortcut disabled.")
    }

    @objc private func applyShortcut() {
        let configuration = ShortcutConfiguration(
            enabled: enabled.state == .on,
            keyCode: ShortcutConfiguration.keys[max(0, key.indexOfSelectedItem)].code,
            modifiers: modifierButtons.reduce(0) { $0 | ($1.0.state == .on ? $1.1 : 0) })
        do {
            try shortcut.apply(configuration)
            try preferences.save(configuration)
            updateStatus()
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    @objc private func resetShortcut() {
        populate(.default)
        applyShortcut()
    }
}
