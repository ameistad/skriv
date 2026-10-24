import AppKit
import Testing
@testable import SkrivCore

struct JoinLinesTests {
    @Test(arguments: [
        ("one\n  two\nthree", "one two\nthree", 3),
        ("one \n\ttwo", "one two", 4),
        ("one\n  )", "one)", 3),
        ("one\n  ", "one", 2),
        ("\ntwo", "two", 0),
        ("\n", "", 0),
        ("👩🏽‍💻\r\n\te\u{301}", "👩🏽‍💻 e\u{301}", 7),
        ("one\rtwo", "one two", 3),
    ])
    func joinsWithVimSpacingAndGraphemeSafeCaret(_ fixture: (String, String, Int)) throws {
        var engine = VimEngine()
        engine.setRegister(text: "keep", linewise: true)
        let generation = engine.registerGeneration
        let effect = engine.handle("J", text: fixture.0, caret: 0)
        guard case .edit(let range, let replacement, let caret) = effect else {
            Issue.record("Expected a join edit"); return
        }
        #expect((fixture.0 as NSString).replacingCharacters(in: range, with: replacement) == fixture.1)
        #expect(caret == fixture.2)
        #expect(engine.register == .init(text: "keep", linewise: true))
        #expect(engine.registerGeneration == generation)
        #expect(engine.mode == .normal)
    }

    @Test func countsAndVisualSelectionJoinThroughLastBoundary() {
        let text = "one\ntwo\nthree\nfour"
        for keys in [["3", "J"], ["V", "j", "j", "J"], ["v", "j", "j", "o", "J"]] {
            var engine = VimEngine()
            var effect: VimEffect = .handled
            for key in keys { effect = engine.handle(key, text: text, caret: 0) }
            #expect(effect == .edit(range: NSRange(location: 0, length: 13), replacement: "one two three", caret: 7))
            #expect(engine.mode == .normal)
        }
        for count in ["1", "2", "9"] {
            var engine = VimEngine()
            _ = engine.handle(count, text: "one\ntwo", caret: 0)
            #expect(engine.handle("J", text: "one\ntwo", caret: 0) ==
                .edit(range: NSRange(location: 0, length: 7), replacement: "one two", caret: 3))
        }
    }

    @Test func lastLineAndPendingCommandsDoNotEdit() {
        var engine = VimEngine()
        #expect(engine.handle("J", text: "", caret: 0) == .handled)
        #expect(engine.handle("J", text: "one\ntwo", caret: 5) == .handled)
        _ = engine.handle("d", text: "one\ntwo", caret: 0)
        #expect(engine.handle("J", text: "one\ntwo", caret: 0) == .handled)
        engine.reset(mode: .insert)
        #expect(engine.handle("J", text: "one\ntwo", caret: 0) == .passThrough)
    }
}

@Suite(.serialized)
@MainActor
struct NativeJoinLinesTests {
    init() { _ = TestApplication.documents }

    @Test func joinsUseNativeUndoAndPreserveInsertMode() throws {
        for native in [false, true] {
            let document = SkrivDocument()
            document.makeWindowControllers()
            defer { document.close() }
            let controller = try #require(document.windowControllers.first as? DocumentWindowController)
            let view = controller.textView
            let original = "👩🏽‍💻\r\n  e\u{301}\nlast"
            document.textStorage.mutableString.setString(original)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            if native { view.handleVimKey("i") }
            let undo = try #require(document.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            if native { view.joinLines(nil) } else { view.handleVimKey("J") }
            undo.endUndoGrouping()
            #expect(view.string == "👩🏽‍💻 e\u{301}\nlast")
            #expect(view.selectedRange() == NSRange(location: 7, length: 0))
            #expect(view.engine.mode == (native ? .insert : .normal))
            undo.undo()
            #expect(view.string == original)
            undo.redo()
            #expect(view.string == "👩🏽‍💻 e\u{301}\nlast")
        }
    }

    @Test func nativeSelectionExcludesLineAtSelectionEndAndCompositionIsUntouched() {
        let view = VimTextView()
        view.string = "one\ntwo\nthree"
        view.setSelectedRange(NSRange(location: 0, length: 8))
        view.joinLines(nil)
        #expect(view.string == "one two\nthree")
        view.setMarkedText("compose", selectedRange: NSRange(location: 7, length: 0),
                           replacementRange: NSRange(location: 0, length: 0))
        let marked = view.string
        view.joinLines(nil)
        #expect(view.string == marked)
        #expect(view.hasMarkedText())
    }
}
