import AppKit

/// Presentation-only overlay. The document owns the characters; this cache is disposable.
@MainActor
final class MarkdownHighlighter: NSObject {
    static let maximumLength = 1_048_576
    private weak var layout: NSLayoutManager?
    private weak var storage: NSTextStorage?
    private var enabled = false
    private(set) var isActive = false
    private var scheduled = false
    private var cache = MarkdownScanCache()
    private var colors: [MarkdownScanner.Kind: NSColor] = [:]
    #if MARKDOWN_DIAGNOSTICS
    private(set) var batchMilliseconds: [Double] = []
    #endif
    var hasPendingWork: Bool { isActive && cache.hasPendingWork }
    var cachedLineCount: Int { cache.cachedLineCount }
    var retainedLineBytes: Int { cache.retainedLineBytes }

    init(layout: NSLayoutManager) {
        self.layout = layout
        super.init()
        for kind in MarkdownScanner.Kind.allCases { colors[kind] = EditorTheme.markdownColor(kind) }
        observeStorage()
    }

    private func observeStorage() {
        guard storage !== layout?.textStorage else { return }
        if let storage { NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: storage) }
        storage = layout?.textStorage
        if let storage {
            NotificationCenter.default.addObserver(self, selector: #selector(edited(_:)),
                name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        isActive = false
        cache = MarkdownScanCache()
    }

    func configure(enabled: Bool, fileURL: URL?) {
        observeStorage()
        self.enabled = enabled && ["md", "markdown"].contains(fileURL?.pathExtension.lowercased() ?? "")
        updateActivation()
    }

    func stop() {
        enabled = false
        updateActivation()
    }

    private func updateActivation() {
        let active = enabled && (storage?.length ?? Int.max) <= Self.maximumLength
        if active != isActive {
            isActive = active
            cache = MarkdownScanCache()
            // Only this overlay owns temporary foreground colors. Leave Find backgrounds and underlines intact.
            if let storage { layout?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length)) }
        }
        schedule()
    }

    @objc private func edited(_ notification: Notification) {
        guard let storage, storage.editedMask.contains(.editedCharacters) else { return }
        let wasActive = isActive
        // Capture native edit coordinates while they are valid; never change attributes here.
        if wasActive { cache.edited(range: storage.editedRange, delta: storage.changeInLength) }
        // Clearing temporary attributes also waits until AppKit has finished the edit.
        if enabled && storage.length <= Self.maximumLength && !isActive {
            isActive = true
            cache = MarkdownScanCache()
        }
        if wasActive || isActive { schedule(force: true) }
    }

    private func schedule(force: Bool = false) {
        guard !scheduled, force || hasPendingWork else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.processPendingBatch()
            self.schedule()
        }
    }

    /// Internal seam used by correctness tests and the release benchmark; production uses queued batches.
    func processPendingBatch(budgetNanoseconds: UInt64 = 2_000_000) {
        guard let storage, let layout else { return }
        if !enabled || storage.length > Self.maximumLength {
            if isActive {
                isActive = false
                cache = MarkdownScanCache()
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            }
            return
        }
        guard isActive else { return }
        #if MARKDOWN_DIAGNOSTICS
        let began = DispatchTime.now().uptimeNanoseconds
        defer { batchMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000) }
        #endif
        cache.process(storage.mutableString, budgetNanoseconds: budgetNanoseconds) { range, spans in
            if range.length > 0 { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range) }
            for span in spans {
                layout.addTemporaryAttribute(.foregroundColor, value: colors[span.kind]!, forCharacterRange: span.range)
            }
        }
    }
}
