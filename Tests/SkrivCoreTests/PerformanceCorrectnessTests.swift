import Foundation
import Testing
@testable import SkrivCore

struct PerformanceCorrectnessTests {
    @Test func byteIdentityHandlesSharedCopiedAndBridgedStorage() {
        let texts = ["", "ascii", "é", "e\u{301}", "\0", "a\0b", "a\r\nb", "a\nb",
                     "👩🏽‍💻", "👩💻", String(repeating: "æøå 👩🏽‍💻 ", count: 100)]
        for left in texts {
            for right in texts {
                let expected = left.utf8.elementsEqual(right.utf8)
                #expect(left.isByteIdentical(to: right) == expected)
                #expect((NSMutableString(string: left) as String).isByteIdentical(to: right) == expected)
                #expect(left.isByteIdentical(to: NSMutableString(string: right) as String) == expected)
            }
        }
    }

    @Test func cachedMotionsTrackExactEncodingAndExternalEdits() {
        var engine = VimEngine()
        for text in ["éx", "e\u{301}x", "éx", "a\nbc", "ab\nc", "", "👩🏽‍💻x"] {
            for key in ["h", "l", "j", "k", "w", "$", "G", "v", "V"] {
                engine.reset(mode: .normal)
                var fresh = VimEngine()
                fresh.reset(mode: .normal)
                #expect(engine.handle(key, text: text, caret: 0) == fresh.handle(key, text: text, caret: 0))
            }
        }
        engine.reset(mode: .normal)
        #expect(engine.handle("l", text: "éx", caret: 0) == .move(1))
        #expect(engine.handle("l", text: "e\u{301}x", caret: 0) == .move(2))
        engine.invalidateTextCache()
        #expect(engine.handle("l", text: "éx", caret: 0) == .move(1))
        let cocoaText = NSMutableString(string: "éx")
        let snapshot = cocoaText as String
        #expect(engine.handle("l", text: snapshot, caret: 0) == .move(1))
        cocoaText.setString("e\u{301}x")
        #expect(engine.handle("l", text: cocoaText as String, caret: 0) == .move(2))
        #expect(engine.handle("l", text: snapshot, caret: 0) == .move(1))
    }

    @Test func cachedSearchSurvivesNormalizationChangesEditsAndUndo() {
        var search = LiteralSearch()
        #expect(search.submit("é", forward: true, text: "é x é", caret: 0)?.range == NSRange(location: 4, length: 1))
        #expect(search.repeatMatch(reverse: false, text: "e\u{301} x e\u{301}", caret: 0)?.range == NSRange(location: 5, length: 2))
        #expect(search.repeatMatch(reverse: false, text: "é x é", caret: 0)?.range == NSRange(location: 4, length: 1))
        #expect(search.repeatMatch(reverse: false, text: "none", caret: 0) == nil)
        #expect(search.repeatMatch(reverse: false, text: "x é", caret: 0)?.range == NSRange(location: 2, length: 1))
        search.invalidateMatches()
        #expect(search.query == "é")
        #expect(search.repeatMatch(reverse: true, text: "é x é", caret: 4)?.range.location == 0)
        #expect(search.submit("x", forward: true, text: "é x é", caret: 0)?.range.location == 2)
    }

    @Test func binarySearchBoundariesCountsAndWrapMatchEnumeration() {
        let text = "a aba a a"
        let positions = [0, 2, 4, 6, 8]
        for forward in [false, true] {
            for caret in 0...text.utf16.count {
                for count in [1, 2, 5, 6, 10_000, Int.max] {
                    var search = LiteralSearch()
                    let actual = search.submit("a", forward: forward, text: text, caret: caret, count: count)
                    let first = forward
                        ? positions.firstIndex(where: { $0 > caret }) ?? positions.count
                        : positions.lastIndex(where: { $0 < caret }) ?? -1
                    let steps = (count - 1) % positions.count
                    let expectedIndex = ((first + (forward ? steps : -steps)) % positions.count + positions.count) % positions.count
                    #expect(actual?.range.location == positions[expectedIndex])
                    #expect(actual?.wrapped == (forward ? count - 1 >= positions.count - first : count - 1 > first))
                }
            }
        }
    }
}
