import AppKit
import Testing
@testable import SkrivCore

@Suite(.serialized)
@MainActor
struct SettingsPresentationTests {
    init() { _ = TestApplication.documents }

    @Test func newWindowUsesVisibleScreenFrameAndFocusesEditor() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let window = try #require(controller.window)
        if let screen { #expect(window.frame == screen.visibleFrame) }
        #expect(window.initialFirstResponder === controller.textView)
        #expect(window.contentView?.subviews.contains(where: { $0 is NSScrollView }) == true)
    }

    private func editor() throws -> (SkrivDocument, DocumentWindowController) {
        _ = NSApplication.shared
        let document = SkrivDocument()
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        return (document, controller)
    }

    @Test func fontsUseSeparateFamilyAndSize() throws {
        #expect(EditorFont.resolve("SkrivDefinitelyMissingFont", size: 16) == nil)
        #expect(EditorFont.resolve("Menlo", size: 0) == nil)
        let installed = try #require(EditorFont.resolve("Menlo", size: 18))
        #expect(installed.pointSize == 18)
        #expect(installed.familyName == "Menlo")
        let generic = try #require(EditorFont.resolve("monospace", size: 14))
        #expect(generic.pointSize == 14)
    }

    @Test func wrapLinebreakTabSpacingAndFontFallbackCanBeRefreshed() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        let scroll = try #require(view.enclosingScrollView)
        var settings = EditorSettings()
        settings.fontFamily = "SkrivDefinitelyMissingFont"
        settings.fontSize = 19
        settings.wordWrap = true
        settings.tabWidth = 4
        settings.indentWidth = 0
        settings.number = true
        controller.applySettings(settings)
        #expect(view.font?.pointSize == 19)
        #expect(view.defaultParagraphStyle?.lineBreakMode == .byWordWrapping)
        #expect(view.textContainer?.widthTracksTextView == true)
        #expect(scroll.rulersVisible)
        #expect(view.shiftWidth == 4)
        let advance = (" " as NSString).size(withAttributes: [.font: try #require(view.font)]).width
        #expect(view.defaultParagraphStyle?.defaultTabInterval == advance * 4)

        settings.wrap = false
        settings.wordWrap = false
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

    @Test func emptyDocumentHasLayoutForItsFirstNumberedLine() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        var settings = EditorSettings()
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

    @Test func writingColumnAdaptsToConfiguredFontAndUnwrappedMode() throws {
        let (document, controller) = try editor()
        defer { document.close() }
        let view = controller.textView
        controller.window?.setContentSize(NSSize(width: 1600, height: 600))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        var settings = EditorSettings()
        settings.fontSize = 20
        settings.writingWidth = 60
        settings.number = true
        controller.applySettings(settings)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let container = try #require(view.textContainer)
        view.layoutManager?.ensureLayout(for: container)
        let advance = ("0" as NSString).size(withAttributes: [.font: try #require(view.font)]).width
        #expect(abs(container.containerSize.width - 2 * container.lineFragmentPadding - 60 * advance) < 1)

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
    @Test func configurationDocumentReusesUnsavedBufferAndSavesOriginalPath() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.skriv")
        let configuration = ConfigurationController(url: url)
        try configuration.createIfMissing()
        let documents = TestApplication.documents
        defer {
            for document in documents.documents {
                document.close()
                documents.removeDocument(document)
            }
        }
        try documents.openConfiguration(at: url)
        let document = try #require(documents.documents.first as? SkrivDocument)
        #expect(document.fileURL == url)
        #expect(document.fileType == SkrivDocument.configurationTypeName)
        #expect(document.fileNameExtension(forType: SkrivDocument.configurationTypeName,
                                           saveOperation: .saveOperation) == "skriv")
        #expect(document.textStorage.string == SkrivConfiguration.template)
        document.textStorage.mutableString.setString("font-size = 22\n")
        try documents.openConfiguration(at: url)
        #expect(documents.documents.count == 1)
        #expect(document.textStorage.string == "font-size = 22\n")
        document.updateChangeCount(.changeDone)
        try await document.save(to: url, ofType: SkrivDocument.configurationTypeName, for: .saveOperation)
        #expect(document.fileURL == url)
        #expect(!document.isDocumentEdited)
        try configuration.reload()
        #expect(configuration.current.editor.fontSize == 22)
        #expect(!FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("txt").path))
    }

    @Test func parsedConfigurationUpdatesEveryOpenDocumentWithoutEditing() throws {
        let documents = TestApplication.documents
        let previousSettings = documents.currentSettings
        defer { documents.currentSettings = previousSettings }
        let (first, firstController) = try editor()
        let (second, secondController) = try editor()
        documents.addDocument(first)
        documents.addDocument(second)
        defer {
            for document in [first, second] {
                document.close()
                documents.removeDocument(document)
            }
        }
        for document in [first, second] {
            document.textStorage.mutableString.setString("Unchanged æøå 👩🏽‍💻")
            document.updateChangeCount(.changeCleared)
        }
        let parsed = try SkrivConfiguration.parse("""
        font-size = 22
        background = 123456
        foreground = abcdef
        line-numbers = both
        writing-width = 90
        tab-width = 4
        keybind = H=h
        """)
        documents.applySettings(parsed.editor)
        #expect(documents.currentSettings == parsed.editor, "Future documents use the same resolved settings.")
        for controller in [firstController, secondController] {
            #expect(controller.textView.font?.pointSize == 22)
            #expect(controller.textView.backgroundColor == EditorTheme.color(0x123456))
            #expect(controller.textView.textColor == EditorTheme.color(0xABCDEF))
            #expect(controller.textView.writingWidth == 90)
            #expect(controller.textView.tabWidth == 4)
            #expect(controller.textView.enclosingScrollView?.rulersVisible == true)
            #expect(controller.textView.normalKeyMappings == ["H": "h"])
        }
        for document in [first, second] {
            #expect(!document.isDocumentEdited)
            #expect(document.textStorage.string == "Unchanged æøå 👩🏽‍💻")
        }
    }

}
