import AppKit
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct SettingsPresentationTests {
    @Test func newWindowUsesVisibleScreenFrameAndFocusesEditor() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let window = try #require(controller.window)
        if let screen { #expect(window.frame == screen.visibleFrame) }
        #expect(window.initialFirstResponder === controller.textView)
        #expect(window.contentView?.subviews.contains(where: { $0 is NSScrollView }) == true)
    }

    private func editor() throws -> (ScratchDocument, NoteWindowController) {
        _ = NSApplication.shared
        let document = ScratchDocument()
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? NoteWindowController)
        return (document, controller)
    }

    @Test func fontsTryFallbacksAndRejectUnsupportedOptions() throws {
        #expect(EditorFont.resolve("") == nil)
        #expect(EditorFont.resolve("SkrivDefinitelyMissingFont:h16") == nil)
        #expect(EditorFont.resolve("Menlo:h0") == nil)
        #expect(EditorFont.resolve("Menlo:h18:b") == nil)
        let fallback = try #require(EditorFont.resolve("SkrivDefinitelyMissingFont:h16,Menlo:h18"))
        #expect(fallback.pointSize == 18)
        #expect(fallback.familyName == "Menlo")
        let generic = try #require(EditorFont.resolve("monospace:h14"))
        #expect(generic.pointSize == 14)
    }

    @Test func wrapLinebreakTabSpacingAndFontFallbackCanBeRefreshed() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        let scroll = try #require(view.enclosingScrollView)
        var settings = NeovimSettings()
        settings.guifont = "SkrivDefinitelyMissingFont:h16"
        settings.linebreak = true
        settings.tabstop = 4
        settings.shiftwidth = 0
        settings.number = true
        controller.applySettings(settings)
        #expect(view.font?.pointSize == 16)
        #expect(view.defaultParagraphStyle?.lineBreakMode == .byWordWrapping)
        #expect(view.textContainer?.widthTracksTextView == true)
        #expect(scroll.rulersVisible)
        #expect(view.shiftWidth == 4)
        let advance = (" " as NSString).size(withAttributes: [.font: try #require(view.font)]).width
        #expect(view.defaultParagraphStyle?.defaultTabInterval == advance * 4)

        settings.wrap = false
        settings.linebreak = false
        settings.number = false
        controller.applySettings(settings)
        #expect(view.defaultParagraphStyle?.lineBreakMode == .byCharWrapping)
        #expect(view.textContainer?.widthTracksTextView == false)
        #expect(scroll.hasHorizontalScroller)
        #expect(!scroll.rulersVisible)

        controller.applySettings(nil)
        #expect(view.textContainer?.widthTracksTextView == true)
        #expect(!scroll.hasHorizontalScroller)
        #expect(view.frame.width == scroll.contentSize.width)
    }

    @Test func emptyNoteHasLayoutForItsFirstNumberedLine() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        var settings = NeovimSettings()
        settings.number = true
        controller.applySettings(settings)
        let layout = try #require(controller.textView.layoutManager)
        let container = try #require(controller.textView.textContainer)
        layout.ensureLayout(for: container)
        #expect(layout.extraLineFragmentTextContainer === container)
        #expect(layout.extraLineFragmentRect.height > 0)
        #expect(controller.textView.enclosingScrollView?.verticalRulerView is LineNumberRuler)
    }

    @Test func writingColumnReflowsOnResizeWithoutEditingText() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        let window = try #require(controller.window)
        let container = try #require(view.textContainer)
        let layout = try #require(view.layoutManager)
        controller.applySettings(nil)
        let text = String(repeating: "Writing should be comfortable to read. ", count: 30)
        document.textStorage.mutableString.setString(text)
        document.updateChangeCount(.changeCleared)
        view.setSelectedRange(NSRange(location: 12, length: 5))

        func resize(_ width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 600))
            window.contentView?.layoutSubtreeIfNeeded()
            layout.ensureLayout(for: container)
        }
        resize(1400)
        let advance = ("0" as NSString).size(withAttributes: [.font: try #require(view.font)]).width
        let wideWidth = container.containerSize.width
        #expect(abs(wideWidth - 2 * container.lineFragmentPadding - 72 * advance) < 1)
        #expect(view.textContainerInset.width > 24)
        #expect(abs(view.textContainerOrigin.x - (view.bounds.width - wideWidth) / 2) < 1)
        #expect(view.defaultParagraphStyle?.lineBreakMode == .byWordWrapping)
        var firstLine = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &firstLine)
        let firstCharacters = layout.characterRange(forGlyphRange: firstLine, actualGlyphRange: nil)
        #expect(firstCharacters.length < (text as NSString).length)
        #expect((text as NSString).substring(with: firstCharacters).hasSuffix(" "))

        resize(440)
        #expect(view.textContainerInset.width == 24)
        #expect(container.containerSize.width < wideWidth)
        #expect(view.enclosingScrollView?.hasHorizontalScroller == false)
        resize(1400)
        #expect(abs(container.containerSize.width - wideWidth) < 1)
        #expect(view.string == text)
        #expect(view.selectedRange() == NSRange(location: 12, length: 5))
        #expect(!document.isDocumentEdited)
    }

    @Test func writingColumnAdaptsToImportedFontAndUnwrappedMode() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        controller.window?.setContentSize(NSSize(width: 1600, height: 600))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        var settings = NeovimSettings()
        settings.guifont = "monospace:h20"
        settings.number = true
        controller.applySettings(settings)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let container = try #require(view.textContainer)
        view.layoutManager?.ensureLayout(for: container)
        let advance = ("0" as NSString).size(withAttributes: [.font: try #require(view.font)]).width
        #expect(abs(container.containerSize.width - 2 * container.lineFragmentPadding - 72 * advance) < 1)

        settings.wrap = false
        controller.applySettings(settings)
        #expect(view.textContainerInset.width == 24)
        #expect(view.enclosingScrollView?.hasHorizontalScroller == true)
        controller.applySettings(nil)
        view.layoutManager?.ensureLayout(for: container)
        #expect(view.textContainerInset.width > 24)
        #expect(container.containerSize.width < 800)
        #expect(!document.isDocumentEdited)
    }
}
