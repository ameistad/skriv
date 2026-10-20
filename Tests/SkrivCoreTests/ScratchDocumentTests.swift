import AppKit
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct ScratchDocumentTests {
    @Test func closeDelegateReceivesDecisionDocumentAndOriginalContext() {
        let document = ScratchDocument()
        let receiver = CloseDecisionReceiver()
        var sentinel = 42
        withUnsafeMutablePointer(to: &sentinel) { pointer in
            let context = UnsafeMutableRawPointer(pointer)
            let request = DocumentCloseRequest(
                delegate: receiver,
                selector: #selector(CloseDecisionReceiver.receive(_:shouldClose:contextInfo:)),
                context: context)
            request.reply(document: document, shouldClose: false)
            #expect(receiver.document === document)
            #expect(receiver.decision == false)
            #expect(receiver.context == context)
            request.reply(document: document, shouldClose: true)
            #expect(receiver.decision == true)
            #expect(receiver.context == context)
        }
    }

    @Test func unicodeRoundTrip() throws {
        let document = ScratchDocument()
        let text = "Ærlig talt: blåbær, øl og ål.\n👩🏽‍💻 🇳🇴 e\u{301}\n\tIndented\r\n"
        try document.read(from: Data(text.utf8), ofType: ScratchDocument.typeName)
        #expect(document.textStorage.string == text)
        #expect(try document.data(ofType: ScratchDocument.typeName) == Data(text.utf8))
    }

    @Test func invalidUTF8DoesNotReplaceExistingText() throws {
        let document = ScratchDocument()
        document.textStorage.mutableString.setString("Keep me")
        #expect(throws: CocoaError.self) {
            try document.read(from: Data([0xFF, 0xFE]), ofType: ScratchDocument.typeName)
        }
        #expect(document.textStorage.string == "Keep me")
    }

    @Test func newNotesHaveIndependentStorage() throws {
        let first = ScratchDocument()
        let second = ScratchDocument()
        first.textStorage.mutableString.setString("First note")
        #expect(second.textStorage.string.isEmpty)
        #expect(!second.isDocumentEdited)
        #expect(try second.data(ofType: ScratchDocument.typeName).isEmpty)
    }

    @Test func nativeEditingTracksChangesAndSupportsUndo() throws {
        _ = NSApplication.shared
        let document = ScratchDocument()
        document.makeWindowControllers()
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? NoteWindowController)
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        controller.textView.insertText("Hei 🇳🇴", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        #expect(document.textStorage.string == "Hei 🇳🇴")
        #expect(document.isDocumentEdited)
        #expect(undo.canUndo)
        undo.undo()
        #expect(document.textStorage.string.isEmpty)
        #expect(!document.isDocumentEdited)
        undo.redo()
        #expect(document.textStorage.string == "Hei 🇳🇴")
        #expect(document.isDocumentEdited)
    }

    @Test func saveAndFailedSavePreserveTheCorrectDocumentState() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = ScratchDocument()
        defer { document.close() }
        let original = "Norsk æøå 👩🏽‍💻"
        document.textStorage.mutableString.setString(original)
        document.updateChangeCount(.changeDone)
        let saved = directory.appendingPathComponent("note.txt")
        try await document.save(to: saved, ofType: ScratchDocument.typeName, for: .saveAsOperation)
        #expect(try String(contentsOf: saved, encoding: .utf8) == original)
        #expect(!document.isDocumentEdited)
        document.textStorage.mutableString.append(" — changed")
        document.updateChangeCount(.changeDone)
        let impossible = directory.appendingPathComponent("missing-parent/note.txt")
        do {
            try await document.save(to: impossible, ofType: ScratchDocument.typeName, for: .saveAsOperation)
            Issue.record("Saving into a missing parent directory should fail.")
        } catch {
            #expect(document.isDocumentEdited)
            #expect(document.textStorage.string == original + " — changed")
            #expect(try String(contentsOf: saved, encoding: .utf8) == original)
        }
    }
}

@MainActor
private final class CloseDecisionReceiver: NSObject {
    var document: NSDocument?
    var decision: Bool?
    var context: UnsafeMutableRawPointer?

    @objc func receive(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        self.document = document
        decision = shouldClose
        context = contextInfo
    }
}
