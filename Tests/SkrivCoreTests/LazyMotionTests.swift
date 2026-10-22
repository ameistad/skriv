import Foundation
import Testing
@testable import SkrivCore

struct LazyMotionTests {
    @Test func distantLineJumpsAndSelectionsKeepNativeOffsets() {
        let line = "  e\u{301} 👩🏽‍💻 🇳🇴 z\r\n"
        let stride = line.utf16.count
        let source = (String(repeating: line, count: 20_000) + "  tail") as NSString
        var engine = VimEngine()
        engine.reset(mode: .normal)
        #expect(engine.handle("G", storage: source, caret: 0) == .move(20_000 * stride + 2))
        #expect(engine.cacheMetrics.indexedUTF16Length < 100_000)
        #expect(engine.handle("g", storage: source, caret: source.length - 1) == .handled)
        #expect(engine.handle("g", storage: source, caret: source.length - 1) == .move(2))
        for key in ["1", "0", "0", "0", "0"] {
            #expect(engine.handle(key, storage: source, caret: 2) == .handled)
        }
        let middle = 9_999 * stride + 2
        #expect(engine.handle("G", storage: source, caret: 2) == .move(middle))
        #expect(engine.handle("v", storage: source, caret: middle) == .select(
            range: NSRange(location: middle, length: 2), caret: middle))
        #expect(engine.handle("l", storage: source, caret: middle) == .select(
            range: NSRange(location: middle, length: 3), caret: middle + 2))
        #expect(engine.handle("l", storage: source, caret: middle + 2) == .select(
            range: NSRange(location: middle, length: 10), caret: middle + 3))
        #expect(engine.handle("y", storage: source, caret: middle + 3) == .move(middle))
        #expect(engine.register == .init(text: "e\u{301} 👩🏽‍💻", linewise: false))
        #expect(engine.cacheMetrics.indexedUTF16Length < 100_000)
    }

    @Test func uncachedUnicodeLinesUseCompleteGraphemesForEveryNativeCaret() {
        let prefix = String(repeating: "untouched\r\n", count: 2_000)
        // Include regional indicators, joining emoji, Indic conjuncts, and
        // Hangul: scalar or UTF-16 stepping would split these characters.
        let tail = "a\u{301}👩🏽‍💻🇳🇴क्ष가🇳🇴🇸🇪 z"
        let source = (prefix + tail) as NSString
        let base = prefix.utf16.count
        var offsets = [base]
        for character in tail { offsets.append(offsets.last! + character.utf16.count) }
        var engine = VimEngine()
        engine.reset(mode: .normal)
        for index in 0..<(offsets.count - 1) {
            for caret in offsets[index]..<offsets[index + 1] {
                #expect(engine.handle("l", storage: source, caret: caret) == .move(offsets[min(index + 1, offsets.count - 2)]))
                #expect(engine.handle("h", storage: source, caret: caret) == .move(offsets[max(index - 1, 0)]))
            }
        }
        #expect(engine.handle("x", storage: source, caret: base + 2) == .edit(
            range: NSRange(location: base + 2, length: 7), replacement: "", caret: base + 2))
    }

    @Test func editsInUnvisitedTextPreserveCRLFAndJoiningCharacterBoundaries() {
        let prefix = String(repeating: "untouched\n", count: 3_000)
        let source = NSMutableString(string: prefix + "e\nx\r\ntail")
        let base = prefix.utf16.count
        var engine = VimEngine()
        engine.reset(mode: .normal)
        _ = engine.handle("l", storage: source, caret: 0)

        let indexedBeforeEdit = engine.cacheMetrics.indexedUTF16Length
        // Insert a combining mark in a line no command has visited yet.
        source.replaceCharacters(in: NSRange(location: base + 1, length: 0), with: "\u{301}")
        engine.textDidChange(source, editedRange: NSRange(location: base + 1, length: 1), changeInLength: 1)
        #expect(engine.cacheMetrics.indexedUTF16Length == indexedBeforeEdit)
        #expect(engine.handle("$", storage: source, caret: base) == .move(base))
        #expect(engine.handle("a", storage: source, caret: base) == .move(base + 2))
        engine.reset(mode: .normal)
        #expect(engine.handle("j", storage: source, caret: base) == .move(base + 3))
        #expect(engine.handle("j", storage: source, caret: base + 3) == .move(base + 6))

        // Removing CR from CRLF changes offsets without adding a line.
        source.replaceCharacters(in: NSRange(location: base + 4, length: 1), with: "")
        engine.textDidChange(source, editedRange: NSRange(location: base + 4, length: 0), changeInLength: -1)
        #expect(engine.handle("G", storage: source, caret: 0) == .move(base + 5))
        #expect(engine.handle("k", storage: source, caret: base + 5) == .move(base + 3))

        // Re-form CRLF across an edit boundary.
        source.replaceCharacters(in: NSRange(location: base + 4, length: 0), with: "\r")
        engine.textDidChange(source, editedRange: NSRange(location: base + 4, length: 1), changeInLength: 1)
        #expect(engine.handle("G", storage: source, caret: 0) == .move(base + 6))
        #expect(engine.handle("k", storage: source, caret: base + 6) == .move(base + 3))
    }

    @Test func traversingAndRevisitingTextKeepsCharacterCacheWithinBudget() {
        let line = "e\u{301} 👩🏽‍💻 z\n"
        let stride = line.utf16.count
        let source = (String(repeating: line, count: 50_000) + "end") as NSString
        var engine = VimEngine()
        engine.cacheBudgetBytes = 64 * 1024
        engine.reset(mode: .normal)
        #expect(engine.handle("l", storage: source, caret: 0) == .move(2))
        let initial = engine.cacheMetrics.indexedUTF16Length
        for row in Swift.stride(from: 2_000, through: 48_000, by: 2_000) {
            let start = row * stride
            #expect(engine.handle("l", storage: source, caret: start) == .move(start + 2))
            #expect(engine.cacheMetrics.cachedBytes <= engine.cacheMetrics.budgetBytes)
        }
        #expect(engine.cacheMetrics.evictionCount > 0)
        let beforeRevisit = engine.cacheMetrics.indexedUTF16Length
        #expect(beforeRevisit > initial)
        #expect(engine.handle("l", storage: source, caret: 0) == .move(2))
        #expect(engine.cacheMetrics.indexedUTF16Length > beforeRevisit)
        #expect(engine.cacheMetrics.cachedBytes <= 64 * 1024)
        #expect(engine.handle("v", storage: source, caret: 3) == .select(
            range: NSRange(location: 3, length: 7), caret: 3))
        #expect(engine.handle("y", storage: source, caret: 3) == .move(3))
        #expect(engine.register.text == "👩🏽‍💻")
        engine.cacheBudgetBytes = 0
        #expect(engine.cacheMetrics.cachedBytes == 0)
        #expect(engine.handle("l", storage: source, caret: 0) == .move(2))
        #expect(engine.cacheMetrics.cachedBytes == 0)
        #expect(engine.cacheMetrics.entryCount == 0)
    }

    @Test func oversizedLineIndexIsNotRetainedOutsideItsCommand() {
        let source = (String(repeating: "e\u{301}👩🏽‍💻", count: 20_000) + "z") as NSString
        var engine = VimEngine()
        engine.cacheBudgetBytes = 32 * 1024
        engine.reset(mode: .normal)
        #expect(engine.handle("l", storage: source, caret: 0) == .move(2))
        #expect(engine.cacheMetrics.cachedBytes <= engine.cacheMetrics.budgetBytes)
        #expect(engine.handle("h", storage: source, caret: source.length - 1) == .move(source.length - 8))
        #expect(engine.cacheMetrics.cachedBytes <= engine.cacheMetrics.budgetBytes)
        #expect(engine.cacheMetrics.indexedUTF16Length == 0)
    }

    @Test func longUnicodeWordScansPreserveOffsetsInBothDirections() {
        let length = 20_000
        let source = (String(repeating: "e\u{301}", count: length) + " 👩🏽‍💻 tail") as NSString
        let emoji = length * 2 + 1
        let tail = emoji + 8
        var engine = VimEngine()
        engine.reset(mode: .normal)
        #expect(engine.handle("w", storage: source, caret: 0) == .move(emoji))
        #expect(engine.handle("e", storage: source, caret: 0) == .move((length - 1) * 2))
        #expect(engine.handle("b", storage: source, caret: emoji) == .move(0))
        #expect(engine.handle("B", storage: source, caret: tail) == .move(emoji))
        #expect(engine.handle("2", storage: source, caret: 0) == .handled)
        #expect(engine.handle("w", storage: source, caret: 0) == .move(tail))
        #expect(engine.handle("b", storage: source, caret: length) == .move(0))
    }

    @Test func oversizedNativeLinesMatchSwiftGraphemeBoundaries() {
        let fixtures = [
            "a" + String(repeating: "\u{301}", count: 70_000) + "x",
            String(repeating: "🇳", count: 40_001) + "x",
            String(repeating: "क्ष👩🏽‍💻가", count: 7_000) + "x",
        ]
        for text in fixtures {
            let source = text as NSString
            #expect(source.length > 65_536)
            var offsets = [0]
            for character in text { offsets.append(offsets.last! + character.utf16.count) }
            let indices = Set([0, 1, offsets.count / 2, offsets.count - 3, offsets.count - 2])
                .filter { $0 >= 0 && $0 < offsets.count - 1 }.sorted()
            var engine = VimEngine()
            engine.reset(mode: .normal)
            for index in indices {
                for caret in Set([offsets[index], (offsets[index] + offsets[index + 1]) / 2, offsets[index + 1] - 1]) {
                    #expect(engine.handle("l", storage: source, caret: caret) == .move(offsets[min(index + 1, offsets.count - 2)]))
                    #expect(engine.handle("h", storage: source, caret: caret) == .move(offsets[max(index - 1, 0)]))
                }
            }
            #expect(engine.cacheMetrics.cachedBytes <= engine.cacheMetrics.budgetBytes)
        }
    }

    @Test func copiedEnginesKeepIndependentImmutableTextAndCommandState() {
        let first = "e\u{301} 👩🏽‍💻 x\nend"
        // Same UTF-16 length, different grapheme boundaries.
        let second = "éx 👩🏽‍💻 x\nend"
        var original = VimEngine()
        original.reset(mode: .normal)
        #expect(original.handle("l", text: first, caret: 0) == .move(2))
        var copy = original
        let originalBudget = original.cacheMetrics.budgetBytes
        copy.cacheBudgetBytes = 0
        #expect(copy.cacheMetrics.budgetBytes == 0)
        #expect(original.cacheMetrics.budgetBytes == originalBudget)
        #expect(copy.handle("l", text: second, caret: 0) == .move(1))
        #expect(original.handle("l", text: first, caret: 0) == .move(2))
        #expect(copy.handle("v", text: second, caret: 0) == .select(
            range: NSRange(location: 0, length: 1), caret: 0))
        #expect(original.mode == .normal)
        #expect(original.handle("G", text: first, caret: 0) == .move(first.utf16.count - 3))
        #expect(copy.handle("y", text: second, caret: 0) == .move(0))
        #expect(copy.register.text == "é")
        #expect(original.register.text.isEmpty)
    }

    @Test func copiedNativeEngineDetachesMetadataBeforeAnIndependentEdit() {
        let first = "e\u{301}x\nlast" as NSString
        let second = "éx\nlast" as NSString
        var original = VimEngine()
        original.reset(mode: .normal)
        #expect(original.handle("l", storage: first, caret: 0) == .move(2))
        var copy = original
        copy.textDidChange(second, editedRange: NSRange(location: 0, length: 1), changeInLength: -1)
        #expect(copy.handle("l", storage: second, caret: 0) == .move(1))
        #expect(copy.handle("G", storage: second, caret: 0) == .move(3))
        #expect(original.handle("l", storage: first, caret: 0) == .move(2))
        #expect(original.handle("G", storage: first, caret: 0) == .move(4))
    }

}
