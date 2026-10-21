import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    // Construct this before anyone requests NSDocumentController.shared.
    private let documents = SkrivDocumentController()
    private let configuration = ConfigurationController()
    private var startupConfigurationError: Error?

    public func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchMetrics.shared.markStartupCheckpoint("launchDispatch")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        do { try loadConfiguration() }
        catch {
            startupConfigurationError = error
        }
        LaunchMetrics.shared.markStartupCheckpoint("configuration")
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchMetrics.shared.markStartupCheckpoint("finishLaunching")
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = makeMenu()
        LaunchMetrics.shared.markStartupCheckpoint("menu")
        if documents.documents.isEmpty {
            documents.newDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let error = startupConfigurationError {
            showConfigurationError(error, keepingDefaults: true)
        }
        LaunchBenchmark.startIfRequested { [weak self] in self?.newDocument() }
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            newDocument()
        }
        return true
    }

    private func newDocument() {
        LaunchMetrics.shared.begin(.warmInvocation)
        NSApp.activate(ignoringOtherApps: true)
        documents.newDocument(nil)
    }

    private func loadConfiguration() throws {
        try configuration.reload()
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

    @objc private func showAbout(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: "View on GitHub", attributes: [
            .link: URL(string: "https://github.com/ameistad/skriv")!,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: paragraph,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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
        appMenu.addItem(withTitle: "About Skriv", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Open Configuration…", action: #selector(openConfiguration(_:)), keyEquivalent: ",").target = self
        let reload = appMenu.addItem(withTitle: "Reload Configuration", action: #selector(reloadConfiguration(_:)), keyEquivalent: ",")
        reload.keyEquivalentModifierMask = [.command, .shift]
        reload.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Skriv", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Skriv", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu("File", in: menu)
        file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Save…", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Discard Changes…", action: #selector(DocumentWindowController.discardChanges(_:)), keyEquivalent: "")

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
final class SkrivDocumentController: NSDocumentController {
    /// Applied to every new document; nil means the built-in editor settings.
    var currentSettings: EditorSettings?

    func applySettings(_ settings: EditorSettings) {
        currentSettings = settings
        for document in documents {
            for controller in document.windowControllers {
                (controller as? DocumentWindowController)?.applySettings(settings)
            }
        }
    }

    /// Open our custom extension as plain text, reusing an existing document with unsaved edits.
    func openConfiguration(at url: URL) throws {
        if let existing = document(for: url) {
            existing.showWindows()
            return
        }
        let document = try SkrivDocument(contentsOf: url, ofType: SkrivDocument.configurationTypeName)
        addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    override var defaultType: String? { SkrivDocument.typeName }

    override func documentClass(forType typeName: String) -> AnyClass? {
        SkrivDocument.self
    }
}
