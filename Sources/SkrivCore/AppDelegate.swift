import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    // Construct this before anyone requests NSDocumentController.shared.
    private let documents = ScratchDocumentController()
    private let settingsImport = SettingsImportController()
    private let shortcutPreferences = ShortcutPreferences()
    private lazy var globalShortcut = GlobalShortcut { [weak self] in self?.newQuickNote() }
    private var shortcutWindow: ShortcutPreferencesWindowController?

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NoteWindowController.currentSettings = settingsImport.settings
        settingsImport.onChange = { settings in
            NoteWindowController.currentSettings = settings
            for document in NSDocumentController.shared.documents {
                for controller in document.windowControllers {
                    (controller as? NoteWindowController)?.applySettings(settings)
                }
            }
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = makeMenu()
        if documents.documents.isEmpty {
            documents.newDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let note = documents.documents.first?.windowControllers.first as? NoteWindowController {
            note.window?.makeFirstResponder(note.textView)
            LaunchMetrics.shared.markInputReady()
            note.window?.displayIfNeeded()
            LaunchMetrics.shared.markDisplaySubmitted()
        }
        if !LaunchBenchmark.isRequested {
            do { try globalShortcut.apply(shortcutPreferences.configuration) }
            catch {
                let alert = NSAlert(error: error)
                alert.informativeText += "\nYou can change the shortcut from Skriv → Global Shortcut…"
                alert.runModal()
            }
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

    @objc private func showShortcutPreferences(_ sender: Any?) {
        if shortcutWindow == nil {
            shortcutWindow = ShortcutPreferencesWindowController(preferences: shortcutPreferences, shortcut: globalShortcut)
        }
        shortcutWindow?.showWindow(sender)
    }

    @objc private func importNeovimSettings(_ sender: Any?) { settingsImport.importSettings() }
    @objc private func showImportReport(_ sender: Any?) { settingsImport.showReport() }
    @objc private func resetEditorSettings(_ sender: Any?) { settingsImport.resetSettings() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let appMenu = submenu("Skriv", in: menu)
        appMenu.addItem(withTitle: "About Skriv", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Global Shortcut…", action: #selector(showShortcutPreferences(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Import / Refresh Neovim Settings…", action: #selector(importNeovimSettings(_:)), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Neovim Import Report…", action: #selector(showImportReport(_:)), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Use Built-in Editor Settings", action: #selector(resetEditorSettings(_:)), keyEquivalent: "").target = self
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
    override var defaultType: String? { ScratchDocument.typeName }

    override func documentClass(forType typeName: String) -> AnyClass? {
        ScratchDocument.self
    }
}
