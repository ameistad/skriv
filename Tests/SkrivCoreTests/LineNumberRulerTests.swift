import AppKit
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct LineNumberRulerTests {
    init() { _ = TestApplication.documents }

    private func editor(_ text: String = "") throws -> (SkrivDocument, DocumentWindowController, LineNumberRuler) {
        _ = NSApplication.shared
        let document = SkrivDocument()
        document.textStorage.mutableString.setString(text)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        var settings = EditorSettings()
        settings.number = true
        controller.applySettings(settings)
        let ruler = try #require(controller.textView.enclosingScrollView?.verticalRulerView as? LineNumberRuler)
        return (document, controller, ruler)
    }

    private func isBold(_ label: NSAttributedString) throws -> Bool {
        let font = try #require(label.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 12)
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    @Test func caretAndSearchMoveEmphasisInEveryNumberingMode() throws {
        let (document, controller, ruler) = try editor("one\ntwo\nthree\n")
        defer { document.close() }
        let view = controller.textView
        ruler.numberColor = .orange
        let originalThickness = ruler.ruleThickness
        for (absolute, relative, expected) in [(true, false, "2"), (false, true, "0"), (true, true, "2")] {
            ruler.absolute = absolute
            ruler.relative = relative
            view.setSelectedRange(NSRange(location: 4, length: 0))
            let label = ruler.label(forLine: 1)
            #expect(label.string == expected)
            #expect(try isBold(label))
            #expect(try !isBold(ruler.label(forLine: 0)))
            #expect(try !isBold(ruler.label(forLine: 2)))
            #expect(label.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .orange)
            view.submitSearch("three", forward: true)
            #expect(try isBold(ruler.label(forLine: 2)))
            #expect(try !isBold(ruler.label(forLine: 1)))
        }
        // Native selections retain the existing selection-start convention.
        view.setSelectedRange(NSRange(location: 4, length: 6))
        #expect(try isBold(ruler.label(forLine: 1)))
        #expect(ruler.ruleThickness == originalThickness)
        #expect(document.textStorage.string == "one\ntwo\nthree\n")
        #expect(!document.isDocumentEdited)
    }

    @Test func visualEmphasisFollowsActiveEndpointEvenWhenSelectionDoesNotChange() throws {
        for mode in ["v", "V"] {
            let (document, controller, ruler) = try editor("one\ntwo\nthree\n")
            defer { document.close() }
            let view = controller.textView
            view.setSelectedRange(NSRange(location: 0, length: 0))
            for key in ["<Esc>", mode, "j"] { #expect(view.handleVimKey(key)) }
            #expect(try isBold(ruler.label(forLine: 1)))
            #expect(try !isBold(ruler.label(forLine: 0)))
            let selection = view.selectedRange()
            ruler.needsDisplay = false
            #expect(view.handleVimKey("o"))
            #expect(view.selectedRange() == selection)
            #expect(ruler.needsDisplay)
            #expect(try isBold(ruler.label(forLine: 0)))
            #expect(try !isBold(ruler.label(forLine: 1)))
            #expect(view.handleVimKey("<Esc>"))
            #expect(view.handleVimKey("j"))
            #expect(try isBold(ruler.label(forLine: 1)))
            #expect(!document.isDocumentEdited)
        }
    }

    @Test func emptyAndTrailingLinesFollowNativeTypingAndUndo() throws {
        let (document, controller, ruler) = try editor()
        defer { document.close() }
        let view = controller.textView
        #expect(try isBold(ruler.label(forLine: 0)))
        view.insertText("æøå 👩🏽‍💻\n", replacementRange: view.selectedRange())
        #expect(try isBold(ruler.label(forLine: 1)))
        #expect(try !isBold(ruler.label(forLine: 0)))
        #expect(ruler.label(forLine: 1).string == "2")
        let layout = try #require(view.layoutManager)
        layout.ensureLayout(for: try #require(view.textContainer))
        #expect(layout.extraLineFragmentTextContainer != nil)
        view.breakUndoCoalescing()
        document.undoManager?.undo()
        #expect(view.string.isEmpty)
        #expect(try isBold(ruler.label(forLine: 0)))
    }

    @Test func wrappedLinesAndConfigurationRefreshPreserveEmphasisAndText() throws {
        let text = String(repeating: "Writing wraps across visual rows. ", count: 20) + "\nLast line"
        let (document, controller, ruler) = try editor(text)
        defer { document.close() }
        let view = controller.textView
        controller.window?.setContentSize(NSSize(width: 440, height: 500))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let layout = try #require(view.layoutManager)
        layout.ensureLayout(for: try #require(view.textContainer))
        var firstFragment = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &firstFragment)
        let firstCharacters = layout.characterRange(forGlyphRange: firstFragment, actualGlyphRange: nil)
        view.setSelectedRange(NSRange(location: firstCharacters.length + 1, length: 0))
        #expect(try isBold(ruler.label(forLine: 0)))
        #expect(try !isBold(ruler.label(forLine: 1)))
        view.scrollRangeToVisible(view.selectedRange())
        var settings = EditorSettings()
        settings.relativeNumber = true
        controller.applySettings(settings)
        #expect(ruler.label(forLine: 0).string == "0")
        #expect(try isBold(ruler.label(forLine: 0)))
        controller.applySettings(EditorSettings())
        #expect(view.enclosingScrollView?.rulersVisible == false)
        #expect(view.string == text)
        #expect(!document.isDocumentEdited)
    }
}
