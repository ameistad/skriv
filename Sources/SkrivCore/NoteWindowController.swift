import AppKit

@MainActor
final class NoteWindowController: NSWindowController, NSTextViewDelegate, NSTextFieldDelegate {
    static var currentSettings: NeovimSettings?
    let textView: VimTextView
    private let scrollView: NSScrollView
    private let modeLabel = NSTextField(labelWithString: "INSERT")
    private var numberRuler: LineNumberRuler?
    private var editorBottom: NSLayoutConstraint?
    private var searchBottom: NSLayoutConstraint?
    private var searchBar: NSView?
    private var searchField: NSTextField?
    private var searchDirectionLabel: NSTextField?
    private var searchForward = true
    private var searchCount = 1

    init(document: ScratchDocument) {
        LaunchMetrics.shared.markPhase("beforeWindow")
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: NSWindow.contentRect(forFrameRect: frame, styleMask: style),
            styleMask: style,
            backing: .buffered,
            defer: true
        )
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.backgroundColor = EditorTheme.background
        LaunchMetrics.shared.markPhase("window")

        scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = EditorTheme.background

        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        document.textStorage.addLayoutManager(layout)
        textView = VimTextView(frame: scrollView.contentView.bounds, textContainer: container)
        LaunchMetrics.shared.markPhase("textView")
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textColor = EditorTheme.foreground
        textView.backgroundColor = EditorTheme.background
        textView.insertionPointColor = EditorTheme.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: EditorTheme.selectionBackground,
            .foregroundColor: EditorTheme.foreground,
        ]
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Note")
        LaunchMetrics.shared.markPhase("editorConfiguration")

        scrollView.documentView = textView
        let content = NSView(frame: window.contentView!.bounds)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        modeLabel.textColor = .secondaryLabelColor
        modeLabel.setAccessibilityLabel("Editing mode")
        content.addSubview(scrollView)
        content.addSubview(modeLabel)
        let editorBottom = scrollView.bottomAnchor.constraint(equalTo: modeLabel.topAnchor, constant: -5)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editorBottom,
            modeLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            modeLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
            modeLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
        window.contentView = content
        LaunchMetrics.shared.markPhase("viewHierarchy")
        super.init(window: window)
        self.editorBottom = editorBottom
        shouldCascadeWindows = false
        textView.delegate = self
        window.initialFirstResponder = textView
        textView.onModeChange = { [weak self] mode in self?.modeLabel.stringValue = mode }
        textView.onSearchRequest = { [weak self] forward, count in self?.showSearch(forward: forward, count: count) }
        textView.onSearchResult = { [weak self] message in
            guard let self else { return }
            self.modeLabel.stringValue = self.textView.engine.mode.label + (message.isEmpty ? "" : " — " + message)
        }
        applySettings(Self.currentSettings)
        LaunchMetrics.shared.markPhase("settings")
    }

    private func showSearch(forward: Bool, count: Int) {
        guard let content = window?.contentView else { return }
        if searchBar == nil {
            let bar = NSView()
            let field = NSTextField()
            let direction = NSTextField(labelWithString: "/")
            let submit = NSButton(title: "Find", target: self, action: #selector(submitSearch(_:)))
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSearch(_:)))
            field.placeholderString = "Find literal text"
            field.setAccessibilityLabel("Vim literal search")
            field.target = self
            field.action = #selector(submitSearch(_:))
            field.delegate = self
            for view in [direction, field, submit, cancel] {
                view.translatesAutoresizingMaskIntoConstraints = false
                bar.addSubview(view)
                view.centerYAnchor.constraint(equalTo: bar.centerYAnchor).isActive = true
            }
            bar.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                bar.bottomAnchor.constraint(equalTo: modeLabel.topAnchor, constant: -5),
                bar.heightAnchor.constraint(equalToConstant: 34),
                direction.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                direction.widthAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: direction.trailingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: submit.leadingAnchor, constant: -8),
                submit.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
                cancel.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            ])
            searchBottom = scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -4)
            searchBar = bar
            searchField = field
            searchDirectionLabel = direction
        }
        searchForward = forward
        searchCount = count
        searchDirectionLabel?.stringValue = forward ? "/" : "?"
        searchField?.stringValue = ""
        searchBar?.isHidden = false
        editorBottom?.isActive = false
        searchBottom?.isActive = true
        window?.makeFirstResponder(searchField)
    }

    @objc private func submitSearch(_ sender: Any?) {
        let query = searchField?.stringValue ?? ""
        closeSearch()
        textView.submitSearch(query, forward: searchForward, count: searchCount)
    }

    @objc private func cancelSearch(_ sender: Any?) { closeSearch() }

    private func closeSearch() {
        searchBottom?.isActive = false
        editorBottom?.isActive = true
        searchBar?.isHidden = true
        window?.makeFirstResponder(textView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeSearch()
            return true
        }
        return false
    }

    required init?(coder: NSCoder) {
        fatalError("Skriv creates windows programmatically.")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(textView)
        LaunchMetrics.shared.markPhase("showAndFocus")
        LaunchMetrics.shared.markInputReady()
        window?.displayIfNeeded()
        LaunchMetrics.shared.markDisplaySubmitted()
    }

    func applySettings(_ imported: NeovimSettings?) {
        let settings = imported ?? NeovimSettings()
        let background = settings.normal.background.map(EditorTheme.color) ?? EditorTheme.background
        let foreground = settings.normal.foreground.map(EditorTheme.color) ?? EditorTheme.foreground
        window?.backgroundColor = background
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.textColor = foreground
        textView.insertionPointColor = settings.cursor.background.map(EditorTheme.color) ?? EditorTheme.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: settings.visual.background.map(EditorTheme.color) ?? EditorTheme.selectionBackground,
            .foregroundColor: settings.visual.foreground.map(EditorTheme.color) ?? foreground,
        ]
        textView.font = EditorFont.resolve(settings.guifont) ?? .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.normalKeyMappings = settings.normalKeyMappings
        textView.expandTab = settings.expandtab
        textView.tabWidth = settings.tabstop
        textView.shiftWidth = settings.shiftwidth == 0 ? settings.tabstop : settings.shiftwidth
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = settings.linebreak ? .byWordWrapping : .byCharWrapping
        let advance = (" " as NSString).size(withAttributes: [.font: textView.font!]).width
        style.tabStops = []
        style.defaultTabInterval = CGFloat(settings.tabstop) * advance
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.paragraphStyle] = style
        // Presentation-only attributes must not create document edits or undo entries.
        textView.textStorage?.addAttribute(.paragraphStyle, value: style,
            range: NSRange(location: 0, length: (textView.string as NSString).length))
        scrollView.hasHorizontalScroller = !settings.wrap
        textView.isHorizontallyResizable = !settings.wrap
        textView.autoresizingMask = settings.wrap ? [.width] : []
        textView.textContainer?.widthTracksTextView = settings.wrap
        textView.textContainer?.containerSize = NSSize(
            width: settings.wrap ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        if settings.wrap { textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height)) }
        let showNumbers = settings.number || settings.relativenumber
        if showNumbers, numberRuler == nil {
            numberRuler = LineNumberRuler(scrollView: scrollView, editor: textView)
            scrollView.verticalRulerView = numberRuler
        }
        numberRuler?.relative = settings.relativenumber
        numberRuler?.absolute = settings.number
        numberRuler?.numberColor = settings.lineNr.foreground.map(EditorTheme.color) ?? .secondaryLabelColor
        numberRuler?.editorBackground = settings.lineNr.background.map(EditorTheme.color) ?? background
        scrollView.hasVerticalRuler = showNumbers
        scrollView.rulersVisible = showNumbers
        textView.needsDisplay = true
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        (document as? NSDocument)?.undoManager
    }

    @objc func discardNote(_ sender: Any?) {
        guard let document = document as? NSDocument, let window else { return }
        guard document.isDocumentEdited else {
            document.close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Discard changes to this note?"
        alert.informativeText = "Unsaved text will be lost. Any previously saved file will remain."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                document.close()
            }
        }
    }
}
