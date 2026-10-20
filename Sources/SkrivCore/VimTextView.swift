import AppKit

/// Keeps AppKit in charge of text storage, marked text, clipboard and undo.
/// The command engine only describes edits against the current native buffer.
@MainActor
final class VimTextView: NSTextView {
    private(set) var engine = VimEngine()
    var onModeChange: ((String) -> Void)?
    var onSearchRequest: ((Bool, Int) -> Void)?
    var onSearchResult: ((String) -> Void)?
    private(set) var search = LiteralSearch()
    var normalKeyMappings: [String: String] = [:]
    var expandTab = false
    var tabWidth = 8
    var shiftWidth = 8
    var wrapsToWritingColumn = false {
        didSet { updateWritingInsets() }
    }
    private var updatingWritingInsets = false
    private var exportedClipboardChangeCount: Int?
    private static let linewiseClipboardType = NSPasteboard.PasteboardType("no.skriv.linewise")

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateWritingInsets()
    }

    /// Keep the native editor and scrollbar full-width while centering the text.
    /// Font-relative width preserves a readable measure when an imported font changes.
    func updateWritingInsets() {
        guard !updatingWritingInsets else { return }
        updatingWritingInsets = true
        defer { updatingWritingInsets = false }
        let font = font ?? .monospacedSystemFont(ofSize: 16, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let columnWidth = 72 * advance + 2 * (textContainer?.lineFragmentPadding ?? 0)
        let horizontalInset = wrapsToWritingColumn ? max(24, (bounds.width - columnWidth) / 2) : 24
        let inset = NSSize(width: horizontalInset, height: 24)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func keyDown(with event: NSEvent) {
        // Let the input manager finish/cancel composition before interpreting Vim keys.
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        let key: String
        switch event.keyCode {
        case 53: key = "<Esc>"
        case 123: key = "<Left>"
        case 124: key = "<Right>"
        case 125: key = "<Down>"
        case 126: key = "<Up>"
        default:
            if flags.contains(.control), event.charactersIgnoringModifiers == "r" {
                key = "<C-r>"
            } else if engine.mode == .insert {
                super.keyDown(with: event)
                return
            } else {
                guard !flags.contains(.control), !flags.contains(.option),
                      let characters = event.characters, !characters.isEmpty else { return }
                key = characters
            }
        }
        if !handleVimKey(key) { super.keyDown(with: event) }
    }

    /// Also used by integration tests, without synthesizing system keyboard events.
    @discardableResult
    func handleVimKey(_ key: String) -> Bool {
        guard !hasMarkedText() else { return false }
        let mapped = engine.canApplyNormalMapping ? normalKeyMappings[key] ?? key : key
        if engine.mode == .normal, mapped == "p" || mapped == "P" {
            let clipboard = NSPasteboard.general
            if exportedClipboardChangeCount != clipboard.changeCount {
                engine.setRegister(text: clipboard.string(forType: .string) ?? "",
                    linewise: clipboard.string(forType: Self.linewiseClipboardType) == "1")
            }
        }
        let oldGeneration = engine.registerGeneration
        let oldMode = engine.mode
        let effect = engine.handle(mapped, text: string, caret: selectedRange().location)
        if engine.registerGeneration != oldGeneration {
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            clipboard.setString(engine.register.text, forType: .string)
            clipboard.setString(engine.register.linewise ? "1" : "0", forType: Self.linewiseClipboardType)
            exportedClipboardChangeCount = clipboard.changeCount
        }
        switch effect {
        case .passThrough: return false
        case .handled: break
        case .move(let caret): setSelectedRange(NSRange(location: caret, length: 0))
        case .edit(let range, let replacement, let caret):
            breakUndoCoalescing()
            insertText(replacement, replacementRange: range)
            setSelectedRange(NSRange(location: min(caret, (string as NSString).length), length: 0))
            breakUndoCoalescing()
        case .undo:
            breakUndoCoalescing()
            undoManager?.undo()
            normalizeNormalCaret()
        case .redo:
            breakUndoCoalescing()
            undoManager?.redo()
            normalizeNormalCaret()
        case .select(let range, let caret):
            setSelectedRange(range)
            scrollRangeToVisible(NSRange(location: caret, length: 0))
        case .beginSearch(let forward, let count):
            onSearchRequest?(forward, count)
        case .repeatSearch(let reverse, let count):
            showSearchMatch(search.repeatMatch(reverse: reverse, text: string, caret: selectedRange().location, count: count))
        }
        if oldMode != engine.mode {
            if engine.mode == .insert { engine.invalidateTextCache() }
            breakUndoCoalescing()
            onModeChange?(engine.mode.label)
        }
        if case .select = effect {} else { scrollRangeToVisible(selectedRange()) }
        return true
    }

    func submitSearch(_ query: String, forward: Bool, count: Int = 1) {
        showSearchMatch(search.submit(query, forward: forward, text: string, caret: selectedRange().location, count: count))
    }

    private func showSearchMatch(_ match: LiteralSearch.Match?) {
        guard let match else {
            onSearchResult?(search.query.isEmpty ? "No previous search" : "No match")
            return
        }
        setSelectedRange(NSRange(location: match.range.location, length: 0))
        scrollRangeToVisible(match.range)
        showFindIndicator(for: match.range)
        onSearchResult?(match.wrapped ? "Search wrapped" : "")
    }

    override func mouseDown(with event: NSEvent) {
        engine.reset(mode: engine.mode == .insert ? .insert : .normal)
        onModeChange?(engine.mode.label)
        super.mouseDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        engine.invalidateTextCache()
        search.invalidateMatches()
        // Native paste, cut, replacement and undo can invalidate a Visual anchor.
        if engine.mode.isVisual {
            engine.reset(mode: .normal)
            onModeChange?(engine.mode.label)
        }
    }

    override func performTextFinderAction(_ sender: Any?) {
        engine.reset(mode: engine.mode == .insert ? .insert : .normal)
        onModeChange?(engine.mode.label)
        super.performTextFinderAction(sender)
    }

    override func insertTab(_ sender: Any?) {
        guard expandTab, !hasMarkedText() else {
            super.insertTab(sender)
            return
        }
        let text = string as NSString
        let location = min(selectedRange().location, text.length)
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let prefix = text.substring(with: NSRange(location: line.location, length: location - line.location))
        let width = max(1, tabWidth)
        let font = self.font ?? .monospacedSystemFont(ofSize: 16, weight: .regular)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let column = prefix.reduce(0) { column, character in
            if character == "\t" { return column + width - column % width }
            let glyphWidth = (String(character) as NSString).size(withAttributes: [.font: font]).width
            return column + max(1, Int((glyphWidth / max(1, spaceWidth)).rounded()))
        }
        insertText(String(repeating: " ", count: width - column % width), replacementRange: selectedRange())
    }

    @objc func shiftRight(_ sender: Any?) { shiftIndent(right: true) }
    @objc func shiftLeft(_ sender: Any?) { shiftIndent(right: false) }

    private func shiftIndent(right: Bool) {
        guard !hasMarkedText() else { return }
        let text = string as NSString
        let selection = selectedRange()
        let covered = NSRange(location: selection.location, length: max(0, selection.length - (selection.length > 0 ? 1 : 0)))
        let range = text.lineRange(for: covered)
        let source = text.substring(with: range)
        var result = ""
        var cursor = source.startIndex
        var firstDelta = 0
        var firstLine = true
        while cursor < source.endIndex || firstLine {
            let end = source[cursor...].firstIndex(where: { $0.isNewline }) ?? source.endIndex
            let line = source[cursor..<end]
            let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
            let tab = max(1, tabWidth)
            let columns = indentation.reduce(0) { $1 == "\t" ? $0 + tab - $0 % tab : $0 + 1 }
            let target = max(0, columns + (right ? max(1, shiftWidth) : -max(1, shiftWidth)))
            let replacement = expandTab ? String(repeating: " ", count: target)
                : String(repeating: "\t", count: target / tab) + String(repeating: " ", count: target % tab)
            if firstLine { firstDelta = replacement.utf16.count - indentation.utf16.count }
            result += replacement + line.dropFirst(indentation.count)
            firstLine = false
            guard end < source.endIndex else { break }
            result.append(source[end])
            cursor = source.index(after: end)
        }
        guard result != source else { return }
        breakUndoCoalescing()
        insertText(result, replacementRange: range)
        if selection.length > 0 {
            setSelectedRange(NSRange(location: range.location, length: result.utf16.count))
        } else {
            setSelectedRange(NSRange(location: max(range.location, min((string as NSString).length, selection.location + firstDelta)), length: 0))
        }
        breakUndoCoalescing()
    }

    private func normalizeNormalCaret() {
        let text = string as NSString
        var caret = min(selectedRange().location, text.length)
        if caret == text.length, caret > 0 {
            let previous = text.rangeOfComposedCharacterSequence(at: caret - 1)
            if !text.substring(with: previous).contains("\n") { caret = previous.location }
        } else if caret < text.length {
            caret = text.rangeOfComposedCharacterSequence(at: caret).location
        }
        setSelectedRange(NSRange(location: caret, length: 0))
    }
}
