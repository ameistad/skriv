import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    // Construct this before anyone requests NSDocumentController.shared.
    private let documents = ScratchDocumentController()
    private let configuration = ConfigurationController()
    private var startupConfigurationError: Error?
    private lazy var globalShortcut = GlobalShortcut { [weak self] in self?.newQuickNote() }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        do { try loadConfiguration() }
        catch {
            startupConfigurationError = error
            // First launch has no previous configuration; keep the bundled defaults usable.
            if !LaunchBenchmark.isRequested { try? globalShortcut.apply(.default) }
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = makeMenu()
        if documents.documents.isEmpty {
            documents.newDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let error = startupConfigurationError {
            showConfigurationError(error, keepingDefaults: true)
        }
        LaunchBenchmark.startIfRequested { [weak self] in self?.newQuickNote() }
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            newQuickNote()
        }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        globalShortcut.stop()
    }

    @objc private func newQuickNote() {
        LaunchMetrics.shared.begin(.warmInvocation)
        NSApp.activate(ignoringOtherApps: true)
        documents.newDocument(nil)
    }

    private func loadConfiguration() throws {
        try configuration.reload { [self] candidate in
            if !LaunchBenchmark.isRequested { try globalShortcut.apply(candidate) }
        }
        documents.applySettings(configuration.current.editor)
    }

    @objc private func openConfiguration(_ sender: Any?) {
        do {
            try configuration.createIfMissing()
            try documents.openConfiguration(at: configuration.url)
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func reloadConfiguration(_ sender: Any?) {
        do { try loadConfiguration() }
        catch { showConfigurationError(error) }
    }

    private func showConfigurationError(_ error: Error, keepingDefaults: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "Could Not Load Configuration"
        alert.informativeText = "\(configuration.url.path)\n\n\(error.localizedDescription)\n\n"
            + (keepingDefaults ? "Using built-in settings." : "The last working configuration is still active.")
            + " Save your changes, then choose Skriv → Reload Configuration."
        alert.runModal()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let appMenu = submenu("Skriv", in: menu)
        appMenu.addItem(withTitle: "About Skriv", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Open Configuration…", action: #selector(openConfiguration(_:)), keyEquivalent: ",").target = self
        let reload = appMenu.addItem(withTitle: "Reload Configuration", action: #selector(reloadConfiguration(_:)), keyEquivalent: ",")
        reload.keyEquivalentModifierMask = [.command, .shift]
        reload.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Skriv", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Skriv", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu("File", in: menu)
        file.addItem(withTitle: "New Note", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Save…", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Close Note", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Discard Note…", action: #selector(NoteWindowController.discardNote(_:)), keyEquivalent: "")

        let edit = submenu("Edit", in: menu)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Shift Right", action: #selector(VimTextView.shiftRight(_:)), keyEquivalent: "]")
        edit.addItem(withTitle: "Shift Left", action: #selector(VimTextView.shiftLeft(_:)), keyEquivalent: "[")
        edit.addItem(.separator())
        let find = submenu("Find", in: edit)
        for (title, action, key, shift) in [
            ("Find…", NSTextFinder.Action.showFindInterface, "f", false),
            ("Find Next", .nextMatch, "g", false),
            ("Find Previous", .previousMatch, "g", true),
            ("Use Selection for Find", .setSearchString, "e", false),
            ("Find and Replace…", .showReplaceInterface, "f", true),
        ] {
            let item = find.addItem(withTitle: title, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
            item.tag = action.rawValue
            item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
        }

        let window = submenu("Window", in: menu)
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        return menu
    }

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        menu.addItem(item)
        return submenu
    }
}

@MainActor
final class ScratchDocumentController: NSDocumentController {
    /// Applied to every new note; nil means the built-in editor settings.
    var currentSettings: EditorSettings?

    func applySettings(_ settings: EditorSettings) {
        currentSettings = settings
        for document in documents {
            for controller in document.windowControllers {
                (controller as? NoteWindowController)?.applySettings(settings)
            }
        }
    }

    /// Open our custom extension as plain text, reusing an existing document with unsaved edits.
    func openConfiguration(at url: URL) throws {
        if let existing = document(for: url) {
            existing.showWindows()
            return
        }
        let document = try ScratchDocument(contentsOf: url, ofType: ScratchDocument.configurationTypeName)
        addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    override var defaultType: String? { ScratchDocument.typeName }

    override func documentClass(forType typeName: String) -> AnyClass? {
        ScratchDocument.self
    }
}
