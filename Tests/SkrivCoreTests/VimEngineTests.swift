import Foundation
import Testing
@testable import SkrivCore

struct VimEngineTests {
    private struct Session {
        var engine = VimEngine()
        var text: String
        var caret: Int
        init(_ text: String, caret: Int = 0) {
            self.text = text
            self.caret = caret
            engine.reset(mode: .normal)
        }
        @discardableResult mutating func key(_ key: String) -> VimEffect {
            let effect = engine.handle(key, text: text, caret: caret)
            switch effect {
            case .move(let offset): caret = offset
            case .edit(let range, let replacement, let offset):
                #expect(range.location >= 0 && NSMaxRange(range) <= text.utf16.count)
                text = (text as NSString).replacingCharacters(in: range, with: replacement)
                caret = offset
            default: break
            }
            #expect(caret >= 0 && caret <= text.utf16.count)
            return effect
        }
        mutating func keys(_ keys: String) { for key in keys { self.key(String(key)) } }
    }

    @Test func initialInsertAndEscapeAreGraphemeSafe() {
        var engine = VimEngine()
        #expect(engine.mode == .insert)
        #expect(engine.handle("x", text: "hello", caret: 5) == .passThrough)
        let text = "A👩🏽‍💻"
        #expect(engine.handle("<Esc>", text: text, caret: text.utf16.count) == .move(1))
        #expect(engine.mode == .normal)
        #expect(engine.handle("<Esc>", text: "a\nb", caret: 2) == .move(2))
    }

    @Test func unicodeHorizontalMovementAndDeletion() {
        var s = Session("👩🏽‍💻e\u{301}🇳🇴z")
        s.keys("l")
        #expect(s.caret == "👩🏽‍💻".utf16.count)
        s.keys("x")
        #expect(s.text == "👩🏽‍💻🇳🇴z")
        #expect(s.engine.register.text == "e\u{301}")
        s.keys("X")
        #expect(s.text == "🇳🇴z")
        #expect(s.caret == 0)
    }

    @Test func verticalMovementKeepsGraphemeColumnAcrossShortLines() {
        var s = Session("a👩🏽‍💻cd\nx\n🇳🇴xyz")
        s.keys("3ljj")
        #expect(s.caret == "a👩🏽‍💻cd\nx\n🇳🇴xy".utf16.count)
        s.keys("kk")
        #expect(s.caret == "a👩🏽‍💻c".utf16.count)
        s.keys("$jj")
        #expect(s.caret == s.text.utf16.count - 1)
    }

    @Test func motionsCountsAndPunctuation() {
        var s = Session("one.two three four")
        s.keys("w")
        #expect(s.caret == 3)
        s.keys("w")
        #expect(s.caret == 4)
        s.keys("b")
        #expect(s.caret == 3)
        s.keys("0W")
        #expect(s.caret == 8)
        s.keys("B")
        #expect(s.caret == 0)
        s.keys("e")
        #expect(s.caret == 2)
        s.keys("0E")
        #expect(s.caret == 6)
        s.keys("02w")
        #expect(s.caret == 4)
    }

    @Test func emptyLinesAreWords() {
        var s = Session("one\n\nthree")
        s.keys("w")
        #expect(s.caret == 4)
        s.keys("w")
        #expect(s.caret == 5)
        s.keys("b")
        #expect(s.caret == 4)
    }

    @Test func operatorCountsMultiplyAndWordDeleteRetainsLineBreak() {
        var s = Session("a b c d e f g")
        s.keys("2d3w")
        #expect(s.text == "g")
        #expect(s.engine.register.text == "a b c d e f ")
        s = Session("one\ntwo")
        s.keys("dw")
        #expect(s.text == "\ntwo")
        s = Session("one, two")
        s.keys("cw")
        #expect(s.text == ", two")
        #expect(s.engine.mode == .insert)
    }

    @Test func lineDeleteChangeAndRegisters() {
        var s = Session("one\ntwo\nthree", caret: 4)
        s.keys("dd")
        #expect(s.text == "one\nthree")
        #expect(s.engine.register == VimEngine.Register(text: "two\n", linewise: true))
        s.keys("Gdd")
        #expect(s.text == "one")
        #expect(s.caret == 0)
        s.keys("dd")
        #expect(s.text.isEmpty)
        s = Session("one\ntwo\nthree", caret: 4)
        s.keys("cc")
        #expect(s.text == "one\n\nthree")
        #expect(s.caret == 4)
        #expect(s.engine.mode == .insert)
    }

    @Test func linewiseVerticalOperatorsAndGoto() {
        var s = Session("one\ntwo\nthree\nfour")
        s.keys("dj")
        #expect(s.text == "three\nfour")
        s = Session("one\ntwo\nthree\nfour")
        s.keys("3G")
        #expect(s.caret == 8)
        s.keys("2gg")
        #expect(s.caret == 4)
        s.keys("dG")
        #expect(s.text == "one")
        s = Session("one\ntwo\nthree\nfour", caret: 8)
        s.keys("dgg")
        #expect(s.text == "four")
    }

    @Test func yankDoesNotEditAndPastePreservesLinewiseShape() {
        var s = Session("one\ntwo")
        s.keys("yyGp")
        #expect(s.text == "one\ntwo\none")
        #expect(s.caret == 8)
        s.keys("P")
        #expect(s.text == "one\ntwo\none\none")
        s = Session("one\ntwo")
        s.keys("yyp")
        #expect(s.text == "one\none\ntwo")
        s = Session("")
        s.engine.setRegister(text: "line\n", linewise: true)
        s.keys("p")
        #expect(s.text == "\nline")
        #expect(s.caret == 1)
    }

    @Test func characterwisePasteAndExternalRegister() {
        var s = Session("abc")
        s.keys("yl$p")
        #expect(s.text == "abca")
        #expect(s.caret == 3)
        s.engine.setRegister(text: "🇳🇴", linewise: false)
        s.keys("02P")
        #expect(s.text == "🇳🇴🇳🇴abca")
        #expect(s.caret == 4)
        #expect(s.engine.registerGeneration == 1)
    }

    @Test func blankLastLineAndCRLFRemainSafe() {
        var s = Session("one\n")
        s.keys("Gdd")
        #expect(s.text == "one")
        #expect(s.engine.register.text == "\n")
        s = Session("one\r\ntwo", caret: 5)
        s.keys("dd")
        #expect(s.text == "one")
        s = Session("one\r\ntwo")
        s.keys("j")
        #expect(s.caret == 5)
    }

    @Test func insertCommandsAndOpenLines() {
        var s = Session("  abc\ndef", caret: 3)
        s.keys("I")
        #expect(s.caret == 2 && s.engine.mode == .insert)
        s.engine.reset(mode: .normal)
        s.keys("A")
        #expect(s.caret == 5)
        s.engine.reset(mode: .normal)
        s.caret = 2
        s.keys("o")
        #expect(s.text == "  abc\n\ndef")
        #expect(s.caret == 6)
        s = Session("abc")
        s.keys("O")
        #expect(s.text == "\nabc")
        #expect(s.caret == 0)
    }

    @Test func unsupportedCommandsCancelOperatorsAndEscapeCancelsCounts() {
        var s = Session("abc")
        s.keys("dzx")
        #expect(s.text == "bc")
        s.keys("2d")
        s.key("<Esc>")
        s.keys("x")
        #expect(s.text == "c")
        #expect(s.key("u") == .undo)
        #expect(s.key("<C-r>") == .redo)
    }

    @Test func changeWordAtFinalCharacterDoesNotConsumeNextWord() {
        var s = Session("a b c")
        s.keys("cw")
        #expect(s.text == " b c")
        s = Session("one two", caret: 2)
        s.keys("cw")
        #expect(s.text == "on two")
        s = Session("a b c")
        s.keys("c2w")
        #expect(s.text == " c")
    }

    @Test func mappingsAreDisabledWithinCommandsAndGotoUsesOperatorCount() {
        var s = Session("one\ntwo\nthree")
        #expect(s.engine.canApplyNormalMapping)
        s.keys("2")
        #expect(s.engine.canApplyNormalMapping)
        s.keys("d")
        #expect(!s.engine.canApplyNormalMapping)
        s.keys("G")
        #expect(s.text == "three")
        #expect(s.engine.canApplyNormalMapping)
        s.keys("g")
        #expect(!s.engine.canApplyNormalMapping)
        s.key("<Esc>")
        #expect(s.engine.canApplyNormalMapping)
        s.keys("i")
        #expect(!s.engine.canApplyNormalMapping)
    }

    @Test func failedVerticalOperatorsDoNotDeleteOrCaptureCurrentLine() {
        for command in ["dj", "dk", "2dd", "3cc", "2yy"] {
            var s = Session("keep me", caret: 2)
            s.keys(command)
            #expect(s.text == "keep me")
            #expect(s.engine.registerGeneration == 0)
            #expect(s.engine.mode == .normal)
        }
        var s = Session("one\ntwo")
        s.keys("9dd")
        #expect(s.text.isEmpty)
    }

    @Test func fullLineWordDeleteAndWhitespaceAtLineEndMatchVim() {
        var s = Session("one\ntwo\nthree")
        s.keys("d2w")
        #expect(s.text == "three")
        #expect(s.engine.register == VimEngine.Register(text: "one\ntwo\n", linewise: true))
        for command in ["dw", "cw"] {
            s = Session("one  \ntwo", caret: 4)
            s.keys(command)
            #expect(s.text == "one \ntwo")
        }
    }

    @Test func wordEndReachesFinalBlankLineAndYankIncludesIt() {
        var s = Session("one\n", caret: 2)
        s.keys("e")
        #expect(s.caret == 4)
        s = Session("one\n")
        s.keys("yG")
        #expect(s.engine.register.text == "one\n\n")
        s = Session("\n")
        s.keys("cw")
        #expect(s.text == "\n")
        #expect(s.engine.mode == .insert)
    }

    @Test func linewisePasteUsesFirstNonblankAndYankMovesBackward() {
        var s = Session("  one\ntwo")
        s.keys("yyp")
        #expect(s.caret == 8)
        s = Session("one\ntwo\nthree", caret: 6)
        s.keys("yk")
        #expect(s.caret == 2)
        #expect(s.engine.register.text == "one\ntwo\n")
        s.keys("ygg")
        #expect(s.caret == 0)
        s = Session("")
        s.keys("yyp")
        #expect(s.text == "\n")
        #expect(s.caret == 1)
    }

    @Test func backwardWordYankOfEmptyLineKeepsLinewiseRegister() {
        for command in ["db", "yb"] {
            var s = Session("one\n\nthree", caret: 5)
            s.keys(command)
            #expect(s.engine.register == VimEngine.Register(text: "\n", linewise: true))
            #expect(s.caret == 4)
        }
    }

    @Test func everySupportedCommandStaysInBoundsOnSmallUnicodeDocuments() {
        let documents = ["", "\n", "👩🏽‍💻", "\r\n", "a\n\nb", "e\u{301} 🇳🇴\n"]
        let commands = ["h", "l", "j", "k", "w", "b", "e", "W", "B", "E", "0", "^", "$", "gg", "G", "x", "X", "dd", "cc", "yy", "dw", "cw", "db", "de", "d$", "dj", "dk", "D", "C", "Y", "p", "P"]
        for text in documents {
            for caret in 0...text.utf16.count {
                for command in commands {
                    var s = Session(text, caret: caret)
                    s.keys("9" + command)
                    #expect(s.caret >= 0 && s.caret <= s.text.utf16.count)
                }
            }
        }
    }
}
