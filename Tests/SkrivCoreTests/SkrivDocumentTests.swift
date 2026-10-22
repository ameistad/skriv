import AppKit
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct SkrivDocumentTests {
    init() { _ = TestApplication.documents }

    @Test func closeDelegateReceivesDecisionDocumentAndOriginalContext() {
        let document = SkrivDocument()
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
        let document = SkrivDocument()
        let text = "Ærlig talt: blåbær, øl og ål.\n👩🏽‍💻 🇳🇴 e\u{301}\n\tIndented\r\n"
        try document.read(from: Data(text.utf8), ofType: SkrivDocument.typeName)
        #expect(document.textStorage.string == text)
        #expect(try document.data(ofType: SkrivDocument.typeName) == Data(text.utf8))
    }

    @Test func fileEncodingPreservesExactBytesIncludingNULAndDecomposedText() throws {
        for text in ["", "\0", "e\u{301}\r\n👩🏽‍💻\0é\r", String(repeating: "æøå e\u{301} 🇳🇴\n", count: 100_000)] {
            let data = Data(text.utf8)
            let document = SkrivDocument()
            try document.read(from: data, ofType: SkrivDocument.typeName)
            #expect(try document.data(ofType: SkrivDocument.typeName) == data)
        }
        let document = SkrivDocument()
        document.textStorage.mutableString.setString("keep")
        for invalid in [[UInt8](arrayLiteral: 0xC0, 0x80), [0xE2, 0x82], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]] {
            #expect(throws: CocoaError.self) { try document.read(from: Data(invalid), ofType: SkrivDocument.typeName) }
            #expect(document.textStorage.string == "keep")
        }
    }

    @Test func invalidUTF8DoesNotReplaceExistingText() throws {
        let document = SkrivDocument()
        document.textStorage.mutableString.setString("Keep me")
        #expect(throws: CocoaError.self) {
            try document.read(from: Data([0xFF, 0xFE]), ofType: SkrivDocument.typeName)
        }
        #expect(document.textStorage.string == "Keep me")
    }

    @Test func newDocumentsHaveIndependentStorage() throws {
        let first = SkrivDocument()
        let second = SkrivDocument()
        first.textStorage.mutableString.setString("First document")
        #expect(second.textStorage.string.isEmpty)
        #expect(!second.isDocumentEdited)
        #expect(try second.data(ofType: SkrivDocument.typeName).isEmpty)
    }

    @Test func nativeEditingTracksChangesAndSupportsUndo() throws {
        _ = NSApplication.shared
        let document = SkrivDocument()
        document.makeWindowControllers()
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
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
        let document = SkrivDocument()
        defer { document.close() }
        let original = "Norsk æøå 👩🏽‍💻"
        document.textStorage.mutableString.setString(original)
        document.updateChangeCount(.changeDone)
        let saved = directory.appendingPathComponent("document.txt")
        try await document.save(to: saved, ofType: SkrivDocument.typeName, for: .saveAsOperation)
        #expect(try String(contentsOf: saved, encoding: .utf8) == original)
        #expect(!document.isDocumentEdited)
        document.textStorage.mutableString.append(" — changed")
        document.updateChangeCount(.changeDone)
        let impossible = directory.appendingPathComponent("missing-parent/document.txt")
        do {
            try await document.save(to: impossible, ofType: SkrivDocument.typeName, for: .saveAsOperation)
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
