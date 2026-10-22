import Foundation
import Testing
@testable import SkrivCore

struct LargeFileTests {
    @Test func sparseCheckpointsPreserveEveryUnicodeBoundary() {
        let unit = "a\u{301}👩🏽‍💻🇳🇴क्ष가\t xyz"
        for text in [String(repeating: unit, count: 20), String(repeating: "x", count: 64)] {
            let characters = Array(text)
            var offsets = [0]
            for character in characters { offsets.append(offsets.last! + character.utf16.count) }
            var engine = VimEngine()
            engine.reset(mode: .normal)
            for i in characters.indices {
                for caret in offsets[i]..<offsets[i + 1] {
                    #expect(engine.handle("l", text: text, caret: caret) == .move(offsets[min(i + 1, characters.count - 1)]))
                    #expect(engine.handle("h", text: text, caret: caret) == .move(offsets[max(0, i - 1)]))
                }
            }
            #expect(engine.handle("$", text: text, caret: 0) == .move(offsets[characters.count - 1]))
        }
    }

    @Test func deletionRecomputesJoinedGraphemesAndFinalLineCaret() {
        let prefix = String(repeating: "unaffected\n", count: 1000)
        var engine = VimEngine()
        engine.reset(mode: .normal)
        let text = prefix + "🇳x🇴z\nlast"
        let at = prefix.utf16.count + 2
        #expect(engine.handle("x", text: text, caret: at) == .edit(
            range: NSRange(location: at, length: 1), replacement: "", caret: prefix.utf16.count))
        let final = prefix + "  penultimate\nlast"
        _ = engine.handle("d", text: final, caret: final.utf16.count - 4)
        #expect(engine.handle("d", text: final, caret: final.utf16.count - 4) == .edit(
            range: NSRange(location: final.utf16.count - 5, length: 5), replacement: "", caret: prefix.utf16.count + 2))
    }

    @Test func incrementalLinesMatchRebuildAcrossAllEditBoundaries() {
        let originals = ["", "a\nb\nc\n", "a\r\nb\rc\n", "\r\n\r\n", "a\u{2028}b\u{2029}c",
                         "a👩🏽‍💻\n\nlast", "\n", "\r"]
        for original in originals {
            let source = original as NSString
            for start in 0...source.length {
                for end in start...source.length {
                    // UTF-16 edits may split CRLF; avoid splitting surrogate pairs.
                    let range = NSRange(location: start, length: end - start)
                    guard Range(range, in: original) != nil else { continue }
                    for replacement in ["", "x", "\n", "\r", "\r\n", "👩🏽‍💻\nnew\n", "\u{2028}"] {
                        var index = LineStartIndex(source)
                        let edited = source.replacingCharacters(in: range, with: replacement) as NSString
                        index.update(edited, editedRange: NSRange(location: start, length: replacement.utf16.count),
                                     changeInLength: replacement.utf16.count - range.length)
                        #expect(index.starts == LineStartIndex(edited).starts)
                    }
                }
            }
        }
    }

    @Test func boundedSearchMatchesExhaustiveOracleIncludingOverlapsAndWraps() {
        for (unit, query) in [("aaa ", "aa"), ("é e\u{301} ", "é"), ("👩🏽‍💻x👩💻 ", "👩"), ("a\r\na\n", "a")] {
            let text = String(repeating: unit, count: 4200)
            let source = text as NSString
            var ranges: [NSRange] = []
            var start = 0
            while start < source.length {
                let range = source.range(of: query, range: NSRange(location: start, length: source.length - start))
                if range.location == NSNotFound { break }
                if source.rangeOfComposedCharacterSequences(for: range) == range { ranges.append(range) }
                start = NSMaxRange(source.rangeOfComposedCharacterSequence(at: range.location))
            }
            var search = LiteralSearch()
            for forward in [true, false] {
                for caret in [0, 1, 2, source.length / 2, source.length - 1, source.length] {
                    for count in [1, 2, 5, ranges.count + 1, Int.max] {
                        let actual = search.submit(query, forward: forward, text: text, caret: caret, count: count)
                        #expect(search.cachedMatchCount <= LiteralSearch.matchLimit)
                        if ranges.isEmpty { #expect(actual == nil); continue }
                        let first = forward ? ranges.firstIndex { $0.location > caret } ?? ranges.count
                            : ranges.lastIndex { $0.location < caret } ?? -1
                        let steps = (max(1, count) - 1) % ranges.count
                        let expected = ((first + (forward ? steps : -steps)) % ranges.count + ranges.count) % ranges.count
                        #expect(actual?.range == ranges[expected])
                        #expect(actual?.wrapped == (forward ? count - 1 >= ranges.count - first : count - 1 > first))
                    }
                }
            }
            search.invalidateMatches()
            #expect(search.cachedMatchCount == 0)
            #expect(search.repeatMatch(reverse: false, text: "none", caret: 0) == nil)
        }
    }
}
