import AppKit

@MainActor
final class LineNumberRuler: NSRulerView {
    var relative = false { didSet { needsDisplay = true } }
    var absolute = true { didSet { needsDisplay = true } }
    var numberColor = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    var editorBackground = EditorTheme.background { didSet { needsDisplay = true } }
    private weak var editor: NSTextView?
    private var lineStarts: [Int] = [0]
    private var thicknessUpdatePending = false

    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 54
        clipsToBounds = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textChanged), name: NSTextStorage.didProcessEditingNotification, object: editor.textStorage)
        center.addObserver(self, selector: #selector(selectionChanged), name: NSTextView.didChangeSelectionNotification, object: editor)
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(selectionChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        rebuildLines()
    }

    required init(coder: NSCoder) { fatalError("Programmatic ruler") }

    @objc private func textChanged(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        rebuildLines()
    }
    @objc private func selectionChanged(_ notification: Notification) { needsDisplay = true }

    private func rebuildLines() {
        guard let editor else { return }
        let text = editor.string as NSString
        lineStarts = [0]
        var start = 0
        while start < text.length {
            let end = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            guard end > start else { break }
            // A newline-terminated final line is followed by one more, empty, numbered line.
            if end < text.length || text.character(at: end - 1) == 0x0A {
                lineStarts.append(end)
            }
            start = end
        }
        let thickness = max(54, CGFloat(String(lineStarts.count).count * 9 + 22))
        if thickness != ruleThickness, !thicknessUpdatePending {
            thicknessUpdatePending = true
            // Resizing the viewport inside text-storage processing can reenter text
            // layout. Coalesce width changes after AppKit finishes the current edit.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.thicknessUpdatePending = false
                self.ruleThickness = max(54, CGFloat(String(self.lineStarts.count).count * 9 + 22))
                self.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    private func lineIndex(at offset: Int) -> Int {
        max(0, lineStarts.partitionIndex { $0 <= offset } - 1)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        editorBackground.setFill()
        bounds.intersection(rect).fill()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let currentLine = lineIndex(at: editor.selectedRange().location)
        let visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: numberColor,
        ]
        func drawNumber(_ index: Int, y: CGFloat) {
            let value = relative ? (index == currentLine && absolute ? index + 1 : abs(index - currentLine)) : index + 1
            let label = NSAttributedString(string: String(value), attributes: attributes)
            let origin = convert(NSPoint(x: 0, y: y + editor.textContainerOrigin.y), from: editor)
            label.draw(at: NSPoint(x: ruleThickness - label.size().width - 10, y: origin.y + 2))
        }
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            let index = self.lineIndex(at: character)
            if self.lineStarts[index] == character { drawNumber(index, y: used.minY) }
        }
        if layout.extraLineFragmentTextContainer != nil,
           let last = lineStarts.last, last == (editor.string as NSString).length {
            drawNumber(lineStarts.count - 1, y: layout.extraLineFragmentRect.minY)
        }
    }
}
