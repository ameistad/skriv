import Foundation
import Testing
@testable import SkrivCore

struct EverydayEditingTests {
    @Test func forwardBackwardCountsAndWrapping() {
        var search = LiteralSearch()
        #expect(search.submit("one", forward: true, text: "one two one one", caret: 0)?.range.location == 8)
        #expect(search.repeatMatch(reverse: false, text: "one two one one", caret: 8, count: 2) == .init(range: NSRange(location: 0, length: 3), wrapped: true))
        #expect(search.repeatMatch(reverse: true, text: "one two one one", caret: 8)?.range.location == 0)
        #expect(search.forward)
        #expect(search.submit("one", forward: false, text: "one two one one", caret: 0)?.range.location == 12)
        #expect(search.repeatMatch(reverse: true, text: "one two one one", caret: 0)?.range.location == 8)
    }

    @Test func emptyQueryReusesPreviousAndNoMatchKeepsHistory() {
        var search = LiteralSearch()
        #expect(search.submit("", forward: true, text: "hello", caret: 0) == nil)
        #expect(search.submit("missing", forward: true, text: "hello", caret: 0) == nil)
        #expect(search.query == "missing")
        #expect(search.submit("", forward: true, text: "a missing word", caret: 0)?.range.location == 2)
        #expect(search.repeatMatch(reverse: false, text: "", caret: 0) == nil)
    }

    @Test func literalSearchPreservesWholeGraphemesAndAllowsOverlap() {
        var search = LiteralSearch()
        #expect(search.submit("👩", forward: true, text: "👩🏽‍💻", caret: 0) == nil)
        #expect(search.submit("👩🏽‍💻", forward: true, text: "a 👩🏽‍💻", caret: 0)?.range == NSRange(location: 2, length: 7))
        #expect(search.submit("é", forward: true, text: "x e\u{301}", caret: 0)?.range == NSRange(location: 2, length: 2))
        #expect(search.submit("ana", forward: true, text: "banana", caret: 1)?.range.location == 3)
        #expect(search.submit(".", forward: true, text: "x.y", caret: 0)?.range.location == 1)
        #expect(search.submit("A", forward: true, text: "a", caret: 0) == nil)
    }

    @Test func searchCommandsRespectCountsAndCancelUnsupportedOperatorSearch() {
        var engine = VimEngine()
        engine.reset(mode: .normal)
        _ = engine.handle("3", text: "one", caret: 0)
        #expect(engine.handle("/", text: "one", caret: 0) == .beginSearch(forward: true, count: 3))
        #expect(engine.handle("?", text: "one", caret: 0) == .beginSearch(forward: false, count: 1))
        _ = engine.handle("2", text: "one", caret: 0)
        #expect(engine.handle("N", text: "one", caret: 0) == .repeatSearch(reverse: true, count: 2))
        _ = engine.handle("d", text: "one", caret: 0)
        #expect(engine.handle("/", text: "one", caret: 0) == .handled)
        #expect(engine.mode == .normal)
    }

    @Test func visualSelectionsIncludeWholeEmojiAndCanReverseEndpoints() {
        var engine = VimEngine()
        engine.reset(mode: .normal)
        let text = "æ👩🏽‍💻ø"
        #expect(engine.handle("v", text: text, caret: 1) == .select(range: NSRange(location: 1, length: 7), caret: 1))
        #expect(engine.handle("l", text: text, caret: 1) == .select(range: NSRange(location: 1, length: 8), caret: 8))
        #expect(engine.handle("o", text: text, caret: 1) == .select(range: NSRange(location: 1, length: 8), caret: 1))
        #expect(engine.handle("h", text: text, caret: 1) == .select(range: NSRange(location: 0, length: 9), caret: 0))
        #expect(engine.handle("y", text: text, caret: 0) == .move(0))
        #expect(engine.register.text == text)
        #expect(!engine.register.linewise)
        #expect(engine.mode == .normal)
    }

    @Test func visualDeleteAndChangeUseSelectedRange() {
        var engine = VimEngine()
        engine.reset(mode: .normal)
        _ = engine.handle("v", text: "abcde", caret: 1)
        _ = engine.handle("2", text: "abcde", caret: 1)
        _ = engine.handle("l", text: "abcde", caret: 1)
        #expect(engine.handle("c", text: "abcde", caret: 1) == .edit(range: NSRange(location: 1, length: 3), replacement: "", caret: 1))
        #expect(engine.mode == .insert)
        #expect(engine.register.text == "bcd")
    }

    @Test func visualLineHandlesLastUnterminatedLineAndEmptyBuffers() {
        var engine = VimEngine()
        engine.reset(mode: .normal)
        #expect(engine.handle("V", text: "one\ntwo", caret: 5) == .select(range: NSRange(location: 4, length: 3), caret: 5))
        #expect(engine.handle("d", text: "one\ntwo", caret: 4) == .edit(range: NSRange(location: 3, length: 4), replacement: "", caret: 0))
        #expect(engine.register.text == "two\n")
        #expect(engine.register.linewise)
        #expect(engine.handle("v", text: "", caret: 0) == .select(range: NSRange(location: 0, length: 0), caret: 0))
        #expect(engine.handle("<Esc>", text: "", caret: 0) == .move(0))
        #expect(engine.mode == .normal)
    }

    @Test func visualModesToggleWithoutEditingAndKeepActiveCaret() {
        var engine = VimEngine()
        engine.reset(mode: .normal)
        let text = "abc\ndef\nxyz"
        _ = engine.handle("v", text: text, caret: 1)
        _ = engine.handle("j", text: text, caret: 1)
        #expect(engine.handle("V", text: text, caret: 1) == .select(range: NSRange(location: 0, length: 8), caret: 5))
        #expect(engine.handle("V", text: text, caret: 1) == .move(5))
        #expect(engine.mode == .normal)
        #expect(engine.registerGeneration == 0)
    }

    @Test func visualMotionsIncludeLineSeparatorsAndNormalizeOnExit() {
        var engine = VimEngine()
        engine.reset(mode: .normal)
        let text = "one\ntwo\nthree"
        _ = engine.handle("v", text: text, caret: 6)
        #expect(engine.handle("l", text: text, caret: 6) == .select(range: NSRange(location: 6, length: 2), caret: 7))
        #expect(engine.handle("d", text: text, caret: 6) == .edit(range: NSRange(location: 6, length: 2), replacement: "", caret: 6))
        #expect(engine.register.text == "o\n")
        _ = engine.handle("v", text: text, caret: 0)
        #expect(engine.handle("$", text: text, caret: 0) == .select(range: NSRange(location: 0, length: 4), caret: 3))
        #expect(engine.handle("<Esc>", text: text, caret: 0) == .move(2))
        _ = engine.handle("v", text: text, caret: 12)
        #expect(engine.handle("k", text: text, caret: 12) == .select(range: NSRange(location: 7, length: 6), caret: 7))
        #expect(engine.handle("y", text: text, caret: 7) == .move(6))
        #expect(engine.register.text == "\nthree")
    }

    @Test func visualLineYankPositionsCursorBySelectionDirection() {
        var engine = VimEngine()
        engine.reset(mode: .normal)
        let text = "one\ntwo\nthree"
        _ = engine.handle("V", text: text, caret: 6)
        #expect(engine.handle("y", text: text, caret: 6) == .move(4))
        _ = engine.handle("V", text: text, caret: 6)
        _ = engine.handle("k", text: text, caret: 6)
        #expect(engine.handle("y", text: text, caret: 2) == .move(2))
        #expect(engine.register.text == "one\ntwo\n")
    }
}
