import AppKit
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct DocumentTabTests {
    init() { _ = TestApplication.documents }

    private var documents: SkrivDocumentController { TestApplication.documents }

    private func newDocument(in destination: TabDestination? = nil) throws -> SkrivDocument {
        let document = try #require(documents.openUntitledDocumentAndDisplay(false) as? SkrivDocument)
        documents.present(document, in: destination)
        return document
    }

    private func controller(_ document: NSDocument) throws -> DocumentWindowController {
        try #require(document.windowControllers.first as? DocumentWindowController)
    }

    private func window(_ document: NSDocument) throws -> NSWindow {
        try #require(controller(document).window)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Timed out waiting for AppKit to finish the document operation")
    }

    @Test func tabsInsertAfterTheSelectedDocumentAndNewWindowsStaySeparate() throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        #expect(firstWindow.tabGroup?.isTabBarVisible == false)
        let frame = firstWindow.frame
        let destination = TabDestination(window: firstWindow)
        let second = try newDocument(in: destination)
        defer { second.close() }
        let secondWindow = try window(second)
        #expect(firstWindow.tabGroup === secondWindow.tabGroup)
        #expect(firstWindow.tabGroup?.isTabBarVisible == true)
        #expect(firstWindow.tabGroup?.selectedWindow === secondWindow)
        #expect(secondWindow.firstResponder === (try controller(second)).textView)
        #expect(secondWindow.frame == frame)

        let third = try newDocument(in: TabDestination(window: firstWindow))
        defer { third.close() }
        let thirdWindow = try window(third)
        #expect(firstWindow.tabGroup?.windows == [firstWindow, thirdWindow, secondWindow])

        let separate = try newDocument()
        defer { separate.close() }
        #expect(try window(separate).tabGroup !== firstWindow.tabGroup)
        #expect(try window(separate).tabGroup?.windows.count == 1)
        #expect(try window(separate).tabGroup?.isTabBarVisible == false)
    }

    @Test func tabNavigationWrapsAndPreservesEditingAndSearchState() throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        let second = try newDocument(in: TabDestination(window: firstWindow))
        defer { second.close() }
        let firstController = try controller(first)
        let secondController = try controller(second)
        let firstView = firstController.textView
        let secondView = secondController.textView
        #expect(firstView.engine.mode == .normal)
        #expect(secondView.engine.mode == .normal)
        secondView.handleVimKey("i")
        first.undoManager?.groupsByEvent = false
        first.undoManager?.beginUndoGrouping()
        firstView.insertText("one two one", replacementRange: NSRange(location: 0, length: 0))
        first.undoManager?.endUndoGrouping()
        firstView.handleVimKey("<Esc>")
        firstView.submitSearch("one", forward: true)
        let selection = firstView.selectedRange()
        let scrollOrigin = firstView.enclosingScrollView?.contentView.bounds.origin

        secondController.nextTab(nil)
        #expect(firstWindow.tabGroup?.selectedWindow === firstWindow)
        #expect(firstView.engine.mode == .normal)
        #expect(firstView.selectedRange() == selection)
        #expect(firstView.enclosingScrollView?.contentView.bounds.origin == scrollOrigin)
        firstController.previousTab(nil)
        #expect(firstWindow.tabGroup?.selectedWindow === secondController.window)
        #expect(secondView.engine.mode == .insert)
        #expect(secondView.string.isEmpty)
        #expect(second.undoManager?.canUndo == false)
        secondController.previousTab(nil)
        firstView.handleVimKey("n")
        #expect(firstView.selectedRange().location != selection.location)
        first.undoManager?.undo()
        #expect(firstView.string.isEmpty)
        #expect(secondView.string.isEmpty)
    }

    @Test func numberedShortcutsSelectTabsInVisibleOrder() throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        let second = try newDocument(in: TabDestination(window: firstWindow))
        defer { second.close() }
        let secondWindow = try window(second)
        let third = try newDocument(in: TabDestination(window: firstWindow))
        defer { third.close() }
        let thirdWindow = try window(third)
        let separate = try newDocument()
        defer { separate.close() }
        firstWindow.makeKeyAndOrderFront(nil)
        firstWindow.makeFirstResponder(try controller(first).textView)

        let app = NSApplication.shared
        let oldMenu = app.mainMenu
        let oldWindowsMenu = app.windowsMenu
        defer {
            app.mainMenu = oldMenu
            app.windowsMenu = oldWindowsMenu
        }
        let delegate = AppDelegate()
        let menu = delegate.makeMenu()
        app.mainMenu = menu
        let windowMenu = try #require(app.windowsMenu)
        let shortcuts = windowMenu.items.filter { $0.action == #selector(DocumentWindowController.selectNumberedTab(_:)) }
        #expect(shortcuts.map(\.tag) == Array(1...9))
        #expect(shortcuts.map(\.keyEquivalent) == (1...9).map(String.init))
        #expect(shortcuts.allSatisfy { $0.keyEquivalentModifierMask == [.command] && $0.target == nil })
        // The test host has no key window. Supply the controller that the app's
        // responder chain would resolve, while exercising the real menu shortcut.
        for item in shortcuts { item.target = try controller(first) }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: firstWindow.windowNumber,
            context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        #expect(menu.performKeyEquivalent(with: event))
        #expect(firstWindow.tabGroup?.selectedWindow === thirdWindow)
        #expect(thirdWindow.firstResponder === (try controller(third)).textView)
        #expect(try window(separate).tabGroup?.windows.count == 1)

        let missingTab = try #require(shortcuts.last)
        let thirdController = try controller(third)
        #expect(!thirdController.validateMenuItem(missingTab))
        thirdController.selectNumberedTab(missingTab)
        #expect(firstWindow.tabGroup?.selectedWindow === thirdWindow)

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        thirdWindow.beginSheet(sheet)
        let firstShortcut = try #require(shortcuts.first)
        #expect(!thirdController.validateMenuItem(firstShortcut))
        thirdController.selectNumberedTab(firstShortcut)
        #expect(firstWindow.tabGroup?.selectedWindow === thirdWindow)
        thirdWindow.endSheet(sheet)
        sheet.orderOut(nil)
        #expect(firstWindow.tabGroup?.windows == [firstWindow, thirdWindow, secondWindow])
    }

    @Test func shortcutHintsFollowInsertionReorderingClosingAndDetaching() throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        func hint(_ window: NSWindow) -> String? {
            (window.tab.accessoryView as? NSTextField)?.stringValue
        }
        #expect(hint(firstWindow) == "")
        let second = try newDocument(in: TabDestination(window: firstWindow))
        defer { second.close() }
        let secondWindow = try window(second)
        let third = try newDocument(in: TabDestination(window: firstWindow))
        defer { third.close() }
        let thirdWindow = try window(third)
        #expect([firstWindow, thirdWindow, secondWindow].map(hint) == ["⌘1", "⌘2", "⌘3"])
        let titles = [firstWindow, secondWindow, thirdWindow].map(\.title)

        let group = try #require(firstWindow.tabGroup)
        group.insertWindow(secondWindow, at: 0)
        NSApplication.shared.updateWindows()
        #expect(group.windows == [secondWindow, firstWindow, thirdWindow])
        #expect(group.windows.map(hint) == ["⌘1", "⌘2", "⌘3"])
        #expect([firstWindow, secondWindow, thirdWindow].map(\.title) == titles)

        second.close()
        NSApplication.shared.updateWindows()
        #expect([firstWindow, thirdWindow].map(hint) == ["⌘1", "⌘2"])
        thirdWindow.moveTabToNewWindow(nil)
        NSApplication.shared.updateWindows()
        #expect([firstWindow, thirdWindow].map(hint) == ["", ""])
    }

    @Test func ninthShortcutSelectsNinthTabEvenWithMoreTabs() throws {
        var opened: [SkrivDocument] = []
        defer { for document in opened { document.close() } }
        let destination = TabDestination(window: nil)
        for _ in 0..<10 { opened.append(try newDocument(in: destination)) }
        let firstWindow = try window(opened[0])
        let ninthWindow = try window(opened[8])
        let tenthWindow = try window(opened[9])
        #expect((ninthWindow.tab.accessoryView as? NSTextField)?.stringValue == "⌘9")
        #expect((tenthWindow.tab.accessoryView as? NSTextField)?.stringValue == "")
        let item = NSMenuItem(title: "Select Tab 9", action: #selector(DocumentWindowController.selectNumberedTab(_:)), keyEquivalent: "9")
        item.tag = 9
        try controller(opened[9]).selectNumberedTab(item)
        #expect(firstWindow.tabGroup?.selectedWindow === ninthWindow)
    }

    @Test func detachingATabHidesBothSingleDocumentTabBars() throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        let second = try newDocument(in: TabDestination(window: firstWindow))
        defer { second.close() }
        let secondWindow = try window(second)
        secondWindow.moveTabToNewWindow(nil)
        NSApplication.shared.updateWindows()
        #expect(firstWindow.tabGroup !== secondWindow.tabGroup)
        #expect(firstWindow.tabGroup?.windows == [firstWindow])
        #expect(secondWindow.tabGroup?.windows == [secondWindow])
        #expect(firstWindow.tabGroup?.isTabBarVisible == false)
        #expect(secondWindow.tabGroup?.isTabBarVisible == false)
    }

    @Test func settingsReachInactiveTabsWithoutChangingTheirDocuments() throws {
        let oldSettings = documents.currentSettings
        defer { documents.currentSettings = oldSettings }
        let first = try newDocument()
        defer { first.close() }
        let second = try newDocument(in: TabDestination(window: window(first)))
        defer { second.close() }
        var settings = EditorSettings()
        settings.fontSize = 23
        documents.applySettings(settings)
        for document in [first, second] {
            #expect(try controller(document).textView.font?.pointSize == 23)
            #expect(!document.isDocumentEdited)
        }
    }

    @Test func closingOneTabKeepsItsSiblingAndClosingTheLastRemovesTheWindow() throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        let second = try newDocument(in: TabDestination(window: firstWindow))
        defer { second.close() }
        let secondWindow = try window(second)
        secondWindow.performClose(nil)
        #expect(second.windowControllers.isEmpty)
        #expect(firstWindow.tabGroup?.windows == [firstWindow])
        #expect(!first.windowControllers.isEmpty)
        #expect(firstWindow.isVisible)
        NSApplication.shared.updateWindows()
        #expect(firstWindow.tabGroup?.isTabBarVisible == false)
        firstWindow.performClose(nil)
        #expect(first.windowControllers.isEmpty)
        #expect(!firstWindow.isVisible)
        #expect(!documents.documents.contains(first))
        #expect(!documents.documents.contains(second))
    }

    @Test func closingTheDestinationUsesASiblingOrCreatesANewWindow() throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        let second = try newDocument(in: TabDestination(window: firstWindow))
        defer { second.close() }
        let secondWindow = try window(second)
        let captured = TabDestination(window: secondWindow)
        second.close()
        let third = try newDocument(in: captured)
        defer { third.close() }
        #expect(try window(third).tabGroup === firstWindow.tabGroup)
        let abandoned = TabDestination(window: try window(third))
        first.close()
        third.close()
        let fourth = try newDocument(in: abandoned)
        defer { fourth.close() }
        #expect(try window(fourth).tabGroup?.windows.count == 1)
        #expect(try window(fourth).isVisible)
    }

    @Test func openingAnExistingDocumentSelectsItsTabWithoutMovingOrReplacingEdits() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        firstWindow.makeKeyAndOrderFront(nil)
        let (opened, wasOpen) = try await documents.openDocument(withContentsOf: url, display: true)
        defer { opened.close() }
        #expect(!wasOpen)
        let openedWindow = try window(opened)
        #expect(openedWindow.tabGroup === firstWindow.tabGroup)
        let text = try #require(opened as? SkrivDocument)
        text.textStorage.mutableString.setString("Unsaved")
        text.updateChangeCount(.changeDone)
        let separate = try newDocument()
        defer { separate.close() }
        let (reopened, alreadyOpen) = try await documents.openDocument(withContentsOf: url, display: true)
        #expect(alreadyOpen)
        #expect(reopened === opened)
        #expect(openedWindow.tabGroup === firstWindow.tabGroup)
        #expect(openedWindow.tabGroup?.selectedWindow === openedWindow)
        #expect(try window(separate).tabGroup !== openedWindow.tabGroup)
        #expect(text.textStorage.string == "Unsaved")
        #expect(text.isDocumentEdited)
    }

    @Test func openingAFileReplacesTheAutomaticEmptyDocumentBeforeQuit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "Saved file".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let initial = try #require(documents.openInitialDocument())
        defer { initial.close() }
        let (opened, _) = try await documents.openDocument(withContentsOf: url, display: true)
        defer { opened.close() }
        #expect(initial.windowControllers.isEmpty)
        #expect(!documents.documents.contains { $0 === initial })
        #expect(try window(opened).tabGroup?.windows.count == 1)
        #expect(try window(opened).isVisible)
        try controller(opened).executeCommand("q")
        #expect(opened.windowControllers.isEmpty)
        #expect(initial.windowControllers.isEmpty)
    }

    @Test func openingAFilePreservesAnEditedInitialDocumentAndExplicitEmptyTabs() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "Saved file".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let initial = try #require(documents.openInitialDocument() as? SkrivDocument)
        defer { initial.close() }
        initial.textStorage.mutableString.setString("Keep this draft")
        initial.updateChangeCount(.changeDone)
        let explicit = try newDocument(in: TabDestination(window: try window(initial)))
        defer { explicit.close() }
        let (opened, _) = try await documents.openDocument(withContentsOf: url, display: true)
        defer { opened.close() }
        try controller(opened).executeCommand("q")
        #expect(!initial.windowControllers.isEmpty)
        #expect(initial.textStorage.string == "Keep this draft")
        #expect(initial.isDocumentEdited)
        #expect(!explicit.windowControllers.isEmpty)
    }

    @Test func failedOpenKeepsTheInitialDocumentAndBatchOpenReplacesItOnlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try #require(documents.openInitialDocument())
        defer { initial.close() }
        do {
            _ = try await documents.openDocument(withContentsOf: directory.appendingPathComponent("missing.txt"), display: true)
            Issue.record("Opening a missing file should fail")
        } catch {}
        #expect(!initial.windowControllers.isEmpty)
        let urls = ["one.txt", "two.txt"].map { directory.appendingPathComponent($0) }
        for url in urls { try "Saved file".write(to: url, atomically: true, encoding: .utf8) }
        try window(initial).makeKeyAndOrderFront(nil)
        let succeeded = await withCheckedContinuation { continuation in
            documents.openDocuments(at: urls) { continuation.resume(returning: $0) }
        }
        let opened = urls.compactMap { documents.document(for: $0) }
        defer { opened.forEach { $0.close() } }
        #expect(succeeded)
        #expect(initial.windowControllers.isEmpty)
        #expect(opened.count == 2)
        let windows = try opened.map(window)
        #expect(windows.first?.tabGroup?.windows == windows)
    }

    @Test func configurationUsesTabsAndReusesTheOriginalTab() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".skriv")
        try "font-size = 18".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        firstWindow.makeKeyAndOrderFront(nil)
        try documents.openConfiguration(at: url)
        let configuration = try #require(documents.document(for: url) as? SkrivDocument)
        defer { configuration.close() }
        let configurationWindow = try window(configuration)
        #expect(configurationWindow.tabGroup === firstWindow.tabGroup)
        configuration.textStorage.mutableString.setString("font-size = 22")
        configuration.updateChangeCount(.changeDone)
        let separate = try newDocument()
        defer { separate.close() }
        try documents.openConfiguration(at: url)
        #expect(documents.document(for: url) === configuration)
        #expect(configurationWindow.tabGroup === firstWindow.tabGroup)
        #expect(configurationWindow.tabGroup?.selectedWindow === configurationWindow)
        #expect(configuration.textStorage.string == "font-size = 22")
    }

    @Test func batchOpeningKeepsItsDestinationWhenAnExistingFileSelectsAnotherWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["existing.txt", "new-first.txt", "new-second.txt"].map { directory.appendingPathComponent($0) }
        for url in urls { try url.lastPathComponent.write(to: url, atomically: true, encoding: .utf8) }
        let (existing, _) = try await documents.openDocument(withContentsOf: urls[0], display: true)
        defer { existing.close() }
        let originalGroup = try window(existing).tabGroup
        let destinationDocument = try newDocument()
        defer { destinationDocument.close() }
        let destinationWindow = try window(destinationDocument)
        destinationWindow.makeKeyAndOrderFront(nil)
        let succeeded = await withCheckedContinuation { continuation in
            documents.openDocuments(at: urls) { continuation.resume(returning: $0) }
        }
        let opened = urls.dropFirst().compactMap { documents.document(for: $0) }
        defer { opened.forEach { $0.close() } }
        #expect(succeeded)
        #expect(opened.count == 2)
        #expect(try window(existing).tabGroup === originalGroup)
        #expect(destinationWindow.tabGroup !== originalGroup)
        #expect(destinationWindow.tabGroup?.windows == [destinationWindow] + (try opened.map(window)))
    }

    @Test func dirtyCloseCanCancelOrDiscardWithoutAffectingOtherTabs() async throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        let second = try newDocument(in: TabDestination(window: firstWindow))
        defer { second.close() }
        let secondWindow = try window(second)
        second.textStorage.mutableString.setString("Keep until explicitly discarded")
        second.updateChangeCount(.changeDone)
        secondWindow.performClose(nil)
        try await waitUntil { secondWindow.attachedSheet != nil }
        secondWindow.endSheet(try #require(secondWindow.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await waitUntil { secondWindow.attachedSheet == nil }
        #expect(!second.windowControllers.isEmpty)
        #expect(second.isDocumentEdited)
        #expect(second.textStorage.string == "Keep until explicitly discarded")
        secondWindow.performClose(nil)
        try await waitUntil { secondWindow.attachedSheet != nil }
        secondWindow.endSheet(try #require(secondWindow.attachedSheet), returnCode: .alertThirdButtonReturn)
        try await waitUntil { second.windowControllers.isEmpty }
        #expect(!first.windowControllers.isEmpty)
        try await waitUntil { firstWindow.tabGroup?.isTabBarVisible == false }
    }

    @Test func savingFromCloseWritesOnlyThatTab() async throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        let second = try newDocument(in: TabDestination(window: firstWindow))
        defer { second.close() }
        let secondWindow = try window(second)
        second.textStorage.mutableString.setString("Saved tab — æøå")
        second.updateChangeCount(.changeDone)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        second.fileURL = url
        second.fileType = SkrivDocument.typeName
        secondWindow.performClose(nil)
        try await waitUntil { secondWindow.attachedSheet != nil }
        secondWindow.endSheet(try #require(secondWindow.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await waitUntil { second.windowControllers.isEmpty }
        #expect(try String(contentsOf: url, encoding: .utf8) == "Saved tab — æøå")
        #expect(!first.windowControllers.isEmpty)
        #expect(!first.isDocumentEdited)
    }

    @Test func vimCloseProtectsOnlyItsTabAndForceCloseLeavesSiblingsIntact() throws {
        let first = try newDocument()
        defer { first.close() }
        let firstWindow = try window(first)
        let second = try newDocument(in: TabDestination(window: firstWindow))
        defer { second.close() }
        let secondController = try controller(second)
        second.undoManager?.groupsByEvent = false
        second.undoManager?.beginUndoGrouping()
        secondController.textView.insertText("Unsaved", replacementRange: NSRange(location: 0, length: 0))
        second.undoManager?.endUndoGrouping()
        secondController.executeCommand("q")
        #expect(!second.windowControllers.isEmpty)
        secondController.executeCommand("q!")
        #expect(second.windowControllers.isEmpty)
        #expect(firstWindow.tabGroup?.windows == [firstWindow])
        #expect(!first.isDocumentEdited)
    }
}
