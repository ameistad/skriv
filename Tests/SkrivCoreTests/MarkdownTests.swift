import AppKit
import Testing
@testable import SkrivCore

struct MarkdownScannerTests {
    private func scan(_ text: String) -> [MarkdownScanner.Span] {
        MarkdownScanner.scan(text as NSString, range: NSRange(location: 0, length: text.utf16.count), incoming: nil).spans
    }

    @Test func basicSyntaxAndEscapes() {
        for (text, kind) in [("# Heading", MarkdownScanner.Kind.heading), ("- item", .marker),
                             ("1. item", .marker), ("> quote", .marker), ("**strong**", .emphasis),
                             ("_emphasis_", .emphasis), ("[label](https://example.test/a(b))", .link),
                             ("![image](image.png)", .link), ("`code`", .code), ("``a ` b``", .code)] {
            #expect(scan(text).contains { $0.kind == kind })
        }
        for text in ["#hashtag", "####### no", "snake_case_name", "\\*escaped\\*", "text *unfinished", "[unfinished](", "`unfinished"] {
            #expect(scan(text).isEmpty)
        }
        #expect(scan("`**plain** [x](y)`").map(\.kind) == [.code])
        #expect(scan("👩🏽‍💻 æøå **bold**").first?.range == NSRange(location: 12, length: 8))
    }

    @Test func fenceCharacterLengthIndentationAndTrailingContent() {
        func line(_ text: String, _ fence: MarkdownScanner.Fence?) -> MarkdownScanner.Result {
            MarkdownScanner.scan(text as NSString, range: NSRange(location: 0, length: text.utf16.count), incoming: fence)
        }
        let open = line("  ````swift", nil).fence
        #expect(open == .init(character: 96, count: 4))
        for text in ["```", "~~~~", "```` trailing", "    ````", "# heading"] {
            let result = line(text, open)
            #expect(result.fence == open)
            #expect(result.spans.map(\.kind) == [.code])
        }
        #expect(line(" ````` \t", open).fence == nil)
        #expect(line("```bad`info", nil).fence == nil)
        #expect(line("~~~lang", nil).fence == .init(character: 126, count: 3))
    }

    @Test func longLinesHaveBoundedInlineWork() {
        let text = "**" + String(repeating: "x", count: 20_000) + "**"
        #expect(scan(text).isEmpty)
        let fence = MarkdownScanner.Fence(character: 96, count: 3)
        let result = MarkdownScanner.scan(text as NSString, range: NSRange(location: 0, length: text.utf16.count), incoming: fence)
        #expect(result.spans.map(\.kind) == [.code])
        #expect(result.fence == fence)
    }

    @Test func incrementalColorsMatchFreshScanAcrossEditsAndInterruptedBatches() {
        // Store resulting colors as an attributed string so native edit range shifting is exercised too.
        let originals = ["", "# title\r\nhello **world**\r\nlast", "before\n```swift\n# code\n```\nafter\n",
                         "~~~\nx\n~~~\n# title", "👩🏽‍💻\r\né\re\u{301}\n_end_", "a\u{2028}# b\u{2029}c"]
        let replacements = ["", "x", "\n", "\r", "\r\n", "```\n", "~~~\n", "👩🏽‍💻 **x**"]
        let key = NSAttributedString.Key("test.markdown.kind")
        func drain(_ cache: inout MarkdownScanCache, _ text: NSMutableAttributedString) {
            while cache.hasPendingWork {
                cache.process(text.mutableString, budgetNanoseconds: 0) { range, spans in
                    text.removeAttribute(key, range: range)
                    for span in spans { text.addAttribute(key, value: String(describing: span.kind), range: span.range) }
                }
            }
        }
        for original in originals {
            let units = Array(original.utf16)
            let boundaries = (0...units.count).filter { $0 == units.count || !(0xDC00...0xDFFF).contains(units[$0]) }
            for start in boundaries {
                for end in boundaries where end >= start {
                    for replacement in replacements {
                        for interrupted in [false, true] {
                            let text = NSMutableAttributedString(string: original)
                            var cache = MarkdownScanCache()
                            if interrupted {
                                cache.process(text.mutableString, budgetNanoseconds: 0) { range, spans in
                                    text.removeAttribute(key, range: range)
                                    for span in spans { text.addAttribute(key, value: String(describing: span.kind), range: span.range) }
                                }
                            }
                            else { drain(&cache, text) }
                            text.replaceCharacters(in: NSRange(location: start, length: end - start), with: replacement)
                            cache.edited(range: NSRange(location: start, length: replacement.utf16.count),
                                         delta: replacement.utf16.count - (end - start))
                            drain(&cache, text)
                            var fresh = MarkdownScanCache()
                            let expected = NSMutableAttributedString(string: text.string)
                            drain(&fresh, expected)
                            #expect(text.isEqual(to: expected), "Original: \(original.debugDescription), edit \(start)..<\(end), replacement \(replacement.debugDescription), interrupted \(interrupted)")
                        }
                    }
                }
            }
        }
    }

    @Test func coalescedEditsAndPartialBatchesMatchFreshColors() {
        let key = NSAttributedString.Key("test.markdown.kind")
        let text = NSMutableAttributedString(string: String(repeating: "# h\n**text**\n```\ncode\n```\n", count: 20))
        var cache = MarkdownScanCache()
        var seed: UInt64 = 37
        func random(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(count))
        }
        func batch(_ cache: inout MarkdownScanCache, _ target: NSMutableAttributedString) {
            cache.process(target.mutableString, budgetNanoseconds: 0) { range, spans in
                target.removeAttribute(key, range: range)
                for span in spans { target.addAttribute(key, value: String(describing: span.kind), range: span.range) }
            }
        }
        for step in 0..<500 {
            let start = random(text.length + 1)
            let length = random(min(12, text.length - start) + 1)
            let replacement = ["", "x", "**b**", "\n", "\r", "```\n", "~~~\n"][random(7)]
            text.replaceCharacters(in: NSRange(location: start, length: length), with: replacement)
            cache.edited(range: NSRange(location: start, length: replacement.utf16.count), delta: replacement.utf16.count - length)
            if step.isMultiple(of: 3) { batch(&cache, text) }
            if step.isMultiple(of: 17) {
                while cache.hasPendingWork { batch(&cache, text) }
                var fresh = MarkdownScanCache()
                let expected = NSMutableAttributedString(string: text.string)
                while fresh.hasPendingWork { batch(&fresh, expected) }
                #expect(text.isEqual(to: expected), "Random edit step \(step)")
            }
        }
    }

    @Test func editingAnAlreadyColoredPrefixDoesNotAbandonInitialScan() {
        let text = NSMutableString(string: String(repeating: "# heading\n", count: 100))
        var cache = MarkdownScanCache()
        for _ in 0..<20 { cache.process(text, budgetNanoseconds: 0) { _, _ in } }
        #expect(cache.hasPendingWork)
        text.replaceCharacters(in: NSRange(location: 2, length: 1), with: "H")
        cache.edited(range: NSRange(location: 2, length: 1), delta: 0)
        while cache.hasPendingWork { cache.process(text, budgetNanoseconds: 0) { _, _ in } }
        #expect(cache.cachedLineCount == 100)
    }

    @Test func ordinaryEditStopsAtUnchangedFenceState() {
        let text = NSMutableString(string: String(repeating: "ordinary **text**\n", count: 10_000))
        var cache = MarkdownScanCache()
        while cache.hasPendingWork { cache.process(text) { _, _ in } }
        text.replaceCharacters(in: NSRange(location: 5, length: 1), with: "!")
        cache.edited(range: NSRange(location: 5, length: 1), delta: 0)
        var scanned = 0
        while cache.hasPendingWork { scanned += cache.process(text) { _, _ in } }
        #expect(scanned < 100)
        #expect(cache.cachedLineCount == 10_000)
    }
}

@Suite(.serialized)
@MainActor
struct MarkdownHighlighterTests {
    init() { _ = TestApplication.documents }

    private func drain(_ highlighter: MarkdownHighlighter) {
        while highlighter.hasPendingWork { highlighter.processPendingBatch() }
        highlighter.processPendingBatch()
    }

    @Test func configurationDefaultsValidationAndReset() throws {
        #expect(EditorSettings().markdownHighlighting)
        #expect(try !SkrivConfiguration.parse("markdown-highlighting = false").editor.markdownHighlighting)
        #expect(try SkrivConfiguration.parse("markdown-highlighting = false\nmarkdown-highlighting =").editor.markdownHighlighting)
        #expect(throws: ConfigurationError.self) { try SkrivConfiguration.parse("markdown-highlighting = yes") }
    }

    @Test func filenameSettingsUndoAndSavedBytes() async throws {
        let document = SkrivDocument()
        document.fileURL = URL(fileURLWithPath: "/tmp/highlighting.MD")
        document.textStorage.mutableString.setString("# Heading\n**bold** `code`\n")
        document.makeWindowControllers()
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let highlighter = try #require(controller.markdownHighlighter)
        let layout = try #require(controller.textView.layoutManager)
        let bytes = try document.data(ofType: SkrivDocument.typeName)
        let selection = controller.textView.selectedRange()
        let dirty = document.isDocumentEdited
        drain(highlighter)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
        #expect(document.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == controller.textView.textColor)
        #expect(try document.data(ofType: SkrivDocument.typeName) == bytes)
        #expect(document.isDocumentEdited == dirty)
        #expect(controller.textView.selectedRange() == selection)
        #expect(document.undoManager?.canUndo == false)

        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        controller.textView.insertText("plain", replacementRange: NSRange(location: 0, length: 1))
        document.undoManager?.endUndoGrouping()
        drain(highlighter)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        document.undoManager?.undo()
        drain(highlighter)
        #expect(try document.data(ofType: SkrivDocument.typeName) == bytes)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
        document.undoManager?.redo()
        drain(highlighter)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        document.undoManager?.undo()
        drain(highlighter)

        // Find/spelling overlays remain owned by AppKit.
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.yellow, forCharacterRange: NSRange(location: 0, length: 1))
        var settings = EditorSettings()
        settings.markdownHighlighting = false
        controller.applySettings(settings)
        #expect(!highlighter.isActive)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
        controller.applySettings(EditorSettings())
        drain(highlighter)
        #expect(highlighter.isActive)
        document.fileURL = URL(fileURLWithPath: "/tmp/highlighting.txt")
        await Task.yield()
        #expect(!highlighter.isActive)
        document.fileURL = URL(fileURLWithPath: "/tmp/highlighting.markdown")
        await Task.yield()
        drain(highlighter)
        #expect(highlighter.isActive)
        document.fileURL = nil
        await Task.yield()
        #expect(!highlighter.isActive)
        document.updateChangeCount(.changeCleared)
    }

    @Test func sizeLimitAndQueuedEdits() throws {
        let storage = NSTextStorage(string: "# heading\n")
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let highlighter = MarkdownHighlighter(layout: layout)
        highlighter.configure(enabled: true, fileURL: URL(fileURLWithPath: "/tmp/test.md"))
        drain(highlighter)
        storage.append(NSAttributedString(string: String(repeating: "x", count: MarkdownHighlighter.maximumLength)))
        highlighter.processPendingBatch()
        #expect(!highlighter.isActive)
        #expect(highlighter.cachedLineCount == 0)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        storage.replaceCharacters(in: NSRange(location: 10, length: storage.length - 10), with: "")
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "##")
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "#")
        drain(highlighter)
        #expect(highlighter.isActive)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
    }

    @Test func markedTextIsPreservedWhileColorsUpdate() throws {
        let document = SkrivDocument()
        document.fileURL = URL(fileURLWithPath: "/tmp/composition.md")
        document.makeWindowControllers()
        defer { document.updateChangeCount(.changeCleared); document.close() }
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let view = controller.textView
        view.setMarkedText("# 日本語", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = view.markedRange(), selected = view.selectedRange()
        drain(try #require(controller.markdownHighlighter))
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == marked)
        #expect(view.selectedRange() == selected)
        #expect(view.string == "# 日本語")
        view.unmarkText()
    }
}
