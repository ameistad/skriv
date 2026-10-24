import AppKit
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct NativeEditorTests {
    init() { _ = TestApplication.documents }

    private func editor() throws -> (SkrivDocument, DocumentWindowController) {
        _ = NSApplication.shared
        let document = SkrivDocument()
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        document.undoManager?.groupsByEvent = false
        return (document, controller)
    }

    private func edit(_ document: SkrivDocument, _ operation: () -> Void) {
        document.undoManager?.beginUndoGrouping()
        operation()
        document.undoManager?.endUndoGrouping()
    }

    private func preservingClipboard(_ body: () throws -> Void) rethrows {
        let clipboard = NSPasteboard.general
        let saved = clipboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            clipboard.clearContents()
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                entries.forEach { item.setData($0.1, forType: $0.0) }
                return item
            }
            clipboard.writeObjects(items)
        }
        try body()
    }

    @Test func commandSnapshotTracksDirectStorageEditsAndSearchOffsets() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        view.handleVimKey("<Esc>")
        // Canonically equivalent strings have different UTF-16 positions.
        // These replacements bypass NSTextView.didChangeText().
        for (text, next, match) in [("é x é", 1, 4), ("e\u{301} x e\u{301}", 2, 5),
                                   ("👩🏽‍💻 x é", 7, 10), ("é x é", 1, 4)] {
            document.textStorage.mutableString.setString(text)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.handleVimKey("l")
            #expect(view.selectedRange().location == next)
            view.submitSearch("é", forward: true)
            #expect(view.selectedRange().location == match)
        }
        document.textStorage.mutableString.setString("")
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 0)
        view.handleVimKey("n")
        #expect(view.selectedRange().location == 0)
        document.textStorage.mutableString.setString("a é")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("n")
        #expect(view.selectedRange().location == 2)
        // A replacement storage object needs its own notification subscription.
        let replacement = NSTextStorage(string: "e\u{301}x")
        view.layoutManager?.replaceTextStorage(replacement)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 2)
        replacement.mutableString.setString("éx")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 1)
    }

    @Test func motionChunksSurviveInsertUndoRedoAndCoalescedStorageEdits() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        let original = String(repeating: "abc 👩🏽‍💻\r\n", count: 10_000)
        document.textStorage.mutableString.setString(original)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("<Esc>")
        view.handleVimKey("i")
        edit(document) { view.insertText("e\u{301}", replacementRange: NSRange(location: 0, length: 0)) }
        #expect(view.engine.lastReindexedUTF16Length < 70_000)
        view.handleVimKey("<Esc>")
        #expect(view.selectedRange().location == 0)
        #expect(view.engine.lastReindexedUTF16Length < 70_000)
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 2)
        view.handleVimKey("u")
        #expect(document.textStorage.string == original)
        #expect(view.engine.lastReindexedUTF16Length < 70_000)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 1)
        view.handleVimKey("<C-r>")
        #expect(document.textStorage.string == "e\u{301}" + original)
        #expect(view.engine.lastReindexedUTF16Length < 70_000)
        let storage = document.textStorage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "é")
        storage.replaceCharacters(in: NSRange(location: storage.length - 2, length: 2), with: "\nlast")
        storage.endEditing()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 1)
        view.handleVimKey("G")
        #expect(view.selectedRange().location == storage.length - 4)
    }

    @Test func lazyMotionCacheFollowsReplacementStorageAndIgnoresDetachedStorage() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        let tail = "\n" + String(repeating: "unvisited 👩🏽‍💻\n", count: 10_000)
        let detached = document.textStorage
        detached.mutableString.setString("éxx" + tail)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("<Esc>")
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 1)
        #expect(view.engine.cacheMetrics.indexedUTF16Length < 70_000)

        // Equal storage lengths do not make old grapheme positions reusable.
        let replacement = NSTextStorage(string: "e\u{301}x" + tail)
        view.layoutManager?.replaceTextStorage(replacement)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 2)
        #expect(view.engine.cacheMetrics.indexedUTF16Length < 70_000)
        let indexed = view.engine.cacheMetrics.indexedUTF16Length
        detached.mutableString.setString("detached")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 2)
        #expect(view.engine.cacheMetrics.indexedUTF16Length == indexed)
        replacement.replaceCharacters(in: NSRange(location: 0, length: 2), with: "é")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 1)
        #expect(view.engine.lastReindexedUTF16Length < 70_000)
    }

    @Test func commandSnapshotTracksNativeInsertionUndoAndRedo() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        edit(document) { view.insertText("éx", replacementRange: NSRange(location: 0, length: 0)) }
        view.handleVimKey("<Esc>")
        view.handleVimKey("0")
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 1)
        view.handleVimKey("i")
        edit(document) { view.insertText("👩🏽‍💻", replacementRange: NSRange(location: 0, length: 1)) }
        view.handleVimKey("<Esc>")
        view.handleVimKey("0")
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 7)
        view.handleVimKey("u")
        view.handleVimKey("0")
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 1)
        view.handleVimKey("<C-r>")
        view.handleVimKey("0")
        view.handleVimKey("l")
        #expect(view.selectedRange().location == 7)
    }

    @Test func vimDeleteUsesNativeUndoAndPreservesGraphemes() throws {
        try preservingClipboard {
            let (document, controller) = try editor()
            defer { document.close() }
            let view = controller.textView
            edit(document) { view.insertText("👩🏽‍💻 æøå", replacementRange: NSRange(location: 0, length: 0)) }
            document.updateChangeCount(.changeCleared)
            view.handleVimKey("<Esc>")
            view.handleVimKey("0")
            edit(document) { view.handleVimKey("x") }
            #expect(view.string == " æøå")
            #expect(document.isDocumentEdited)
            #expect(NSPasteboard.general.string(forType: .string) == "👩🏽‍💻")
            view.handleVimKey("u")
            #expect(view.string == "👩🏽‍💻 æøå")
            #expect(!document.isDocumentEdited)
            view.handleVimKey("<C-r>")
            #expect(view.string == " æøå")
            #expect(document.isDocumentEdited)
        }
    }

    @Test func nativeCompositionIsNotInterpretedAsVimCommands() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        view.handleVimKey("i")
        edit(document) {
            view.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: 0, length: 0))
            #expect(view.hasMarkedText())
            #expect(!view.handleVimKey("<Esc>"))
            #expect(view.engine.mode == .insert)
            view.unmarkText()
        }
        #expect(view.string == "あ")
        #expect(view.handleVimKey("<Esc>"))
        #expect(view.engine.mode == .normal)
    }

    @Test func configuredPresentationDoesNotMarkSavedDocumentEdited() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        edit(document) { view.insertText("Æ\n👩🏽‍💻\n", replacementRange: NSRange(location: 0, length: 0)) }
        document.updateChangeCount(.changeCleared)
        let selection = view.selectedRange()
        var settings = EditorSettings()
        settings.number = true
        settings.relativeNumber = true
        settings.wrap = false
        settings.foreground = 0xCCBB99
        settings.expandTabs = true
        settings.tabWidth = 4
        controller.applySettings(settings)
        #expect(!document.isDocumentEdited)
        #expect(view.string == "Æ\n👩🏽‍💻\n")
        #expect(view.selectedRange() == selection)
        #expect(view.isHorizontallyResizable)
        edit(document) { view.insertTab(nil) }
        #expect(view.string.hasSuffix("\n    "))
        controller.applySettings(nil)
        #expect(!view.isHorizontallyResizable)
    }

    @Test func normalRemapsDoNotLeakIntoOperatorPendingOrInsertMode() throws {
        try preservingClipboard {
            let (document, controller) = try editor()
            defer { document.close() }
            let view = controller.textView
            view.normalKeyMappings = ["w": "l"]
            view.handleVimKey("i")
            #expect(!view.handleVimKey("w"))
            edit(document) { view.insertText("one two", replacementRange: NSRange(location: 0, length: 0)) }
            view.handleVimKey("<Esc>")
            view.handleVimKey("0")
            view.handleVimKey("w")
            #expect(view.selectedRange().location == 1)
            view.handleVimKey("0")
            view.handleVimKey("d")
            edit(document) { view.handleVimKey("w") }
            #expect(view.string == "two")
        }
    }

    @Test func clipboardPreservesLinewiseYanksAcrossDocumentsAndClearsStaleText() throws {
        try preservingClipboard {
            let (first, firstController) = try editor()
            let (second, secondController) = try editor()
            defer { first.close(); second.close() }
            let a = firstController.textView
            let b = secondController.textView
            edit(first) { a.insertText("yanked", replacementRange: NSRange(location: 0, length: 0)) }
            a.handleVimKey("<Esc>")
            a.handleVimKey("y")
            a.handleVimKey("y")
            edit(second) { b.insertText("target", replacementRange: NSRange(location: 0, length: 0)) }
            b.handleVimKey("<Esc>")
            edit(second) { b.handleVimKey("p") }
            #expect(b.string == "target\nyanked")
            NSPasteboard.general.clearContents()
            edit(second) { b.handleVimKey("p") }
            #expect(b.string == "target\nyanked")
        }
    }

    @Test func indentationUsesConfiguredIndentWidthAndNativeUndo() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        var settings = EditorSettings()
        settings.expandTabs = true
        settings.tabWidth = 8
        settings.indentWidth = 4
        controller.applySettings(settings)
        edit(document) { view.insertText("æøå\n👩🏽‍💻", replacementRange: NSRange(location: 0, length: 0)) }
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        edit(document) { view.shiftRight(nil) }
        #expect(view.string == "    æøå\n    👩🏽‍💻")
        edit(document) { view.shiftLeft(nil) }
        #expect(view.string == "æøå\n👩🏽‍💻")
        document.undoManager?.undo()
        #expect(view.string == "    æøå\n    👩🏽‍💻")
    }

    @Test func numberedEditorCanGrowAndClearAcrossGutterWidths() async throws {
        let (document, controller) = try editor()
        defer { document.close() }
        var settings = EditorSettings()
        settings.number = true
        controller.applySettings(settings)
        let ruler = try #require(controller.textView.enclosingScrollView?.verticalRulerView)
        document.textStorage.mutableString.setString(String(repeating: "Norsk 👩🏽‍💻\n", count: 1000))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(ruler.ruleThickness > 54)
        controller.window?.displayIfNeeded()
        document.textStorage.mutableString.setString("")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        controller.window?.displayIfNeeded()
        #expect(ruler.ruleThickness == 54)
        #expect(controller.textView.string.isEmpty)
    }

    @Test func visualDeleteAndUndoUseNativeDocumentState() throws {
        try preservingClipboard {
            let (document, controller) = try editor()
            defer { document.close() }
            let view = controller.textView
            edit(document) { view.insertText("æ👩🏽‍💻ø", replacementRange: NSRange(location: 0, length: 0)) }
            document.updateChangeCount(.changeCleared)
            view.handleVimKey("<Esc>")
            view.handleVimKey("0")
            view.handleVimKey("l")
            view.handleVimKey("v")
            #expect(view.selectedRange() == NSRange(location: 1, length: 7))
            #expect(!document.isDocumentEdited)
            edit(document) { view.handleVimKey("d") }
            #expect(view.string == "æø")
            #expect(document.isDocumentEdited)
            view.handleVimKey("u")
            #expect(view.string == "æ👩🏽‍💻ø")
            #expect(!document.isDocumentEdited)
        }
    }

    @Test func searchAndNativeFindDoNotEditText() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        edit(document) { view.insertText("æøå one æøå", replacementRange: NSRange(location: 0, length: 0)) }
        document.updateChangeCount(.changeCleared)
        view.handleVimKey("<Esc>")
        view.handleVimKey("0")
        view.submitSearch("æøå", forward: true)
        #expect(view.selectedRange().location == 8)
        view.handleVimKey("n")
        #expect(view.selectedRange().location == 0)
        view.handleVimKey("N")
        #expect(view.selectedRange().location == 8)
        let before = view.selectedRange()
        view.submitSearch("missing", forward: true)
        #expect(view.selectedRange() == before)
        #expect(!document.isDocumentEdited)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(item)
        #expect(view.enclosingScrollView?.isFindBarVisible == true)
        #expect(view.string == "æøå one æøå")
        #expect(!document.isDocumentEdited)
    }
}
