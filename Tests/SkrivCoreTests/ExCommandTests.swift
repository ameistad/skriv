import AppKit
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct ExCommandTests {
    init() { _ = TestApplication.documents }

    @Test func parsesOnlySupportedWholeCommands() {
        for input in ["w", "write", "  w \n"] { #expect(ExCommand(input) == .write) }
        for input in ["q", "quit"] { #expect(ExCommand(input) == .quit(force: false)) }
        for input in ["q!", "quit!"] { #expect(ExCommand(input) == .quit(force: true)) }
        #expect(ExCommand("wq") == .writeQuit)
        for input in ["x", "xit", "exit"] { #expect(ExCommand(input) == .exit) }
        for input in ["", "w file.txt", "w!", "wq!", "qall", "q !", "W", "%w", "1,2w", "w | q", "!rm", "write garbage"] {
            #expect(ExCommand(input) == nil)
        }
    }

    @Test func colonIsANormalCommandAndDoesNotLeakPendingState() {
        var engine = VimEngine()
        #expect(engine.handle(":", text: "abc", caret: 0) == .passThrough)
        engine.reset(mode: .normal)
        #expect(engine.handle(":", text: "abc", caret: 0) == .beginCommand)
        for prefix in ["d", "g", "3"] {
            _ = engine.handle(prefix, text: "abc", caret: 0)
            #expect(engine.handle(":", text: "abc", caret: 0) == .handled)
            #expect(engine.handle("l", text: "abc", caret: 0) == .move(1))
        }
        _ = engine.handle("v", text: "abc", caret: 0)
        #expect(engine.handle(":", text: "abc", caret: 0) == .handled)
        #expect(engine.mode == .visual)
    }

    private func fixture() throws -> (SkrivDocument, DocumentWindowController) {
        let document = SkrivDocument()
        document.makeWindowControllers()
        return (document, try #require(document.windowControllers.first as? DocumentWindowController))
    }

    private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    @Test func commandPromptSubmitsAndCancelsWithoutEditingAndCanSwitchToSearch() throws {
        let (owner, controller) = try fixture()
        defer { controller.document = owner; owner.close() }
        let document = CommandDocument()
        controller.document = document
        let view = controller.textView
        view.string = "one two one"
        view.handleVimKey("<Esc>")
        view.handleVimKey("0")
        view.handleVimKey(":")
        let content = try #require(controller.window?.contentView)
        let field = try #require(fields(in: content).first { $0.isEditable })
        #expect(field.accessibilityLabel() == "Vim command")
        #expect(field.currentEditor() != nil)
        field.stringValue = "q!"
        #expect(controller.control(field, textView: view, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!document.closed)
        #expect(controller.window?.firstResponder === view)
        view.handleVimKey(":")
        #expect(field.stringValue.isEmpty)
        field.stringValue = "w"
        #expect(field.sendAction(field.action, to: field.target))
        #expect(document.saveCount == 1)
        document.completeSave(false)
        view.handleVimKey("/")
        #expect(field.accessibilityLabel() == "Vim literal search")
        field.stringValue = "one"
        #expect(field.sendAction(field.action, to: field.target))
        #expect(view.selectedRange().location == 8)
        #expect(view.string == "one two one")
        #expect(view.engine.mode == .normal)
        #expect(!owner.isDocumentEdited)
    }

    @Test func quitProtectsEditsAndForceQuitDiscardsWithoutSaving() throws {
        let (owner, controller) = try fixture()
        defer { controller.document = owner; owner.close() }
        let document = CommandDocument()
        controller.document = document
        document.updateChangeCount(.changeDone)
        controller.executeCommand("q")
        #expect(!document.closed)
        #expect(document.isDocumentEdited)
        controller.executeCommand("q!")
        #expect(document.closed)
        #expect(document.saveCount == 0)
    }

    @Test func cleanQuitAndExitCloseWithoutWriting() throws {
        for command in ["q", "x"] {
            let (owner, controller) = try fixture()
            defer { controller.document = owner; owner.close() }
            let document = CommandDocument()
            controller.document = document
            controller.executeCommand(command)
            #expect(document.closed)
            #expect(document.saveCount == 0)
        }
    }

    @Test func saveAndQuitWaitsForSuccessAndProtectsNewEdits() throws {
        for command in ["w", "wq", "x"] {
            let (owner, controller) = try fixture()
            defer { controller.document = owner; owner.close() }
            let document = CommandDocument()
            controller.document = document
            document.updateChangeCount(.changeDone)
            controller.executeCommand(command)
            #expect(document.saveCount == 1)
            #expect(!document.closed)
            // A second command must not race a pending save or discard its buffer.
            controller.executeCommand("q!")
            controller.executeCommand("wq")
            #expect(!document.closed)
            #expect(document.saveCount == 1)
            document.completeSave(false)
            #expect(!document.closed)
            #expect(document.isDocumentEdited)
            // Success alone is insufficient if there are newer unsaved edits.
            controller.executeCommand(command)
            document.completeSave(true)
            #expect(!document.closed)
            controller.executeCommand(command)
            document.updateChangeCount(.changeCleared)
            document.completeSave(true)
            #expect(document.closed == (command != "w"))
        }
    }

    @Test func unsupportedAndEmptyCommandsHaveNoDocumentSideEffects() throws {
        let (owner, controller) = try fixture()
        defer { controller.document = owner; owner.close() }
        let document = CommandDocument()
        controller.document = document
        for command in ["", "   ", "w other.txt", "qall!", "w | q", "1,2w", "!echo hello"] {
            controller.executeCommand(command)
        }
        #expect(!document.closed)
        #expect(document.saveCount == 0)
    }

    @Test func writeAndWriteQuitUseNativeUTF8Saving() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (document, controller) = try fixture()
        defer { document.close() }
        let url = directory.appendingPathComponent("document.txt")
        document.textStorage.mutableString.setString("Original")
        try await document.save(to: url, ofType: SkrivDocument.typeName, for: .saveAsOperation)
        for command in ["w", "wq"] {
            let text = "Saved with :\(command) — æøå 👩🏽‍💻"
            document.textStorage.mutableString.setString(text)
            document.updateChangeCount(.changeDone)
            controller.executeCommand(command)
            for _ in 0..<200 {
                if !document.isDocumentEdited && (command == "w" || document.windowControllers.isEmpty) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!document.isDocumentEdited)
            #expect(try String(contentsOf: url, encoding: .utf8) == text)
            #expect(document.windowControllers.isEmpty == (command == "wq"))
        }
    }

    @Test func forceQuitLeavesSavedFileAndOtherDocumentsIntact() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let (document, controller) = try fixture()
        let (other, _) = try fixture()
        defer { document.close(); other.close() }
        document.textStorage.mutableString.setString("Saved text")
        try await document.save(to: url, ofType: SkrivDocument.typeName, for: .saveAsOperation)
        document.textStorage.mutableString.setString("Unsaved replacement")
        document.updateChangeCount(.changeDone)
        controller.executeCommand("q")
        #expect(!document.windowControllers.isEmpty)
        controller.executeCommand("q!")
        #expect(document.windowControllers.isEmpty)
        #expect(!other.windowControllers.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Saved text")
    }
}

@MainActor
private final class CommandDocument: NSDocument {
    var saveCount = 0
    var closed = false
    private var pendingSave: DocumentCloseRequest?

    override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?,
                       contextInfo: UnsafeMutableRawPointer?) {
        saveCount += 1
        pendingSave = DocumentCloseRequest(delegate: delegate as AnyObject, selector: didSaveSelector, context: contextInfo)
    }

    func completeSave(_ success: Bool) {
        let callback = pendingSave
        pendingSave = nil
        callback?.reply(document: self, shouldClose: success)
    }

    override func close() { closed = true }
}
