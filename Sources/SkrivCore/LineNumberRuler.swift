import AppKit

@MainActor
final class LineNumberRuler: NSRulerView {
    var relative = false { didSet { needsDisplay = true } }
    var absolute = true { didSet { needsDisplay = true } }
    var numberColor = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    var editorBackground = EditorTheme.background { didSet { needsDisplay = true } }
    private weak var editor: VimTextView?
    private var lineIndex = LineStartIndex(NSString())
    private var lineStarts: [Int] { lineIndex.starts }
    private var thicknessUpdatePending = false
    private let regularFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)

    init(scrollView: NSScrollView, editor: VimTextView) {
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
        lineIndex.update(storage.mutableString, editedRange: storage.editedRange, changeInLength: storage.changeInLength)
        updateThickness()
    }
    @objc private func selectionChanged(_ notification: Notification) { needsDisplay = true }

    private func rebuildLines() {
        guard let editor else { return }
        guard let storage = editor.textStorage else { return }
        lineIndex.rebuild(storage.mutableString)
        updateThickness()
    }

    private func updateThickness() {
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
        lineIndex.line(at: offset)
    }

    /// Shared by every drawn label, including the empty final line.
    func label(forLine index: Int) -> NSAttributedString {
        let currentLine = lineIndex(at: editor?.activeLineOffset ?? 0)
        let isCurrent = index == currentLine
        let value = relative ? (isCurrent && absolute ? index + 1 : abs(index - currentLine)) : index + 1
        return NSAttributedString(string: String(value), attributes: [
            .font: isCurrent ? boldFont : regularFont,
            .foregroundColor: numberColor,
        ])
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        editorBackground.setFill()
        bounds.intersection(rect).fill()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        func drawNumber(_ index: Int, y: CGFloat) {
            let label = self.label(forLine: index)
            let origin = convert(NSPoint(x: 0, y: y + editor.textContainerOrigin.y), from: editor)
            label.draw(at: NSPoint(x: ruleThickness - label.size().width - 10, y: origin.y + 2))
        }
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            let index = self.lineIndex(at: character)
            if self.lineStarts[index] == character { drawNumber(index, y: used.minY) }
        }
        if layout.extraLineFragmentTextContainer != nil,
           let last = lineStarts.last, last == editor.textStorage?.length {
            drawNumber(lineStarts.count - 1, y: layout.extraLineFragmentRect.minY)
        }
    }
}
