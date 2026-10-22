import Foundation
import Testing
@testable import SkrivCore

struct IncrementalMotionTests {
    @Test func editedChunksMatchFreshIndexesAcrossUnicodeAndLineBoundaries() {
        let source = NSMutableString(string: String(repeating: "one e\u{301} 👩🏽‍💻 🇳🇴\r\ntwo\rthree\n", count: 2500))
        var engine = VimEngine()
        engine.reset(mode: .normal)
        _ = engine.handle("l", storage: source, caret: 0)
        let sequences = [["h"], ["l"], ["j"], ["k"], ["G"], ["g", "g"], ["w"], ["b"], ["e"],
                         ["2", "$"], ["2", "d", "d"], ["v", "j", "o", "l", "y"], ["V", "k", "d"], ["a"]]
        let replacements = ["", "x", "\n", "\r", "\r\n", "🇳", "\u{301}", "e\u{301}\n"]
        for step in 0..<48 {
            let positions = [0, 16_383, 16_384, 32_768, source.length / 2, source.length - 1]
            let position = min(source.length - 1, positions[step % positions.count])
            let composed = source.rangeOfComposedCharacterSequence(at: position)
            let range = NSRange(location: composed.location, length: step.isMultiple(of: 3) ? 0 : composed.length)
            let replacement = replacements[step % replacements.count]
            source.replaceCharacters(in: range, with: replacement)
            engine.textDidChange(source, editedRange: NSRange(location: range.location, length: replacement.utf16.count),
                                 changeInLength: replacement.utf16.count - range.length)
            #expect(engine.lastReindexedUTF16Length < 70_000)
            var fresh = VimEngine()
            var text = source as String
            text.makeContiguousUTF8()
            for initial in [0, max(0, range.location - 1), min(range.location + replacement.utf16.count, source.length), source.length] {
                for sequence in sequences {
                    engine.reset(mode: .normal)
                    fresh.reset(mode: .normal)
                    engine.setRegister(text: "", linewise: false)
                    fresh.setRegister(text: "", linewise: false)
                    var caret = initial
                    for key in sequence {
                        let actual = engine.handle(key, storage: source, caret: caret)
                        let expected = fresh.handle(key, text: text, caret: caret)
                        #expect(actual == expected, "step \(step), caret \(caret), key \(key)")
                        #expect(engine.mode == fresh.mode)
                        #expect(engine.register == fresh.register)
                        switch actual {
                        case .move(let next), .select(_, let next): caret = next
                        default: break
                        }
                    }
                }
            }
        }
    }

    @Test func deletingAcrossChunksAndReplacingEverythingKeepsFinalLineAndOffsets() {
        let source = NSMutableString(string: String(repeating: "abcdef\r\n", count: 20_000))
        var engine = VimEngine()
        engine.reset(mode: .normal)
        _ = engine.handle("G", storage: source, caret: 0)
        for (range, replacement) in [(NSRange(location: 16_383, length: 80_001), "🇳\r"),
                                      (NSRange(location: 0, length: 0), "\n👩🏽‍💻\n")] {
            source.replaceCharacters(in: range, with: replacement)
            engine.textDidChange(source, editedRange: NSRange(location: range.location, length: replacement.utf16.count),
                                 changeInLength: replacement.utf16.count - range.length)
            var fresh = VimEngine()
            fresh.reset(mode: .normal)
            for key in ["G", "j", "k", "$", "w"] {
                #expect(engine.handle(key, storage: source, caret: source.length) == fresh.handle(key, text: source as String, caret: source.length))
            }
        }
        for replacement in ["", "x\r\n", "e\u{301}x", "\r", ""] {
            let oldLength = source.length
            source.setString(replacement)
            engine.textDidChange(source, editedRange: NSRange(location: 0, length: source.length), changeInLength: source.length - oldLength)
            var fresh = VimEngine()
            fresh.reset(mode: .normal)
            #expect(engine.handle("G", storage: source, caret: 0) == fresh.handle("G", text: replacement, caret: 0))
        }
    }
}
