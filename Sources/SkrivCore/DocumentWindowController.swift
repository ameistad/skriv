import AppKit

@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private let savedFrameName: NSWindow.FrameAutosaveName
    private var isInFullScreen = false
    let textView: VimTextView
    private let scrollView: NSScrollView
    private let modeLabel = NSTextField(labelWithString: "INSERT")
    private var numberRuler: LineNumberRuler?
    private var editorBottom: NSLayoutConstraint?
    private var promptBottom: NSLayoutConstraint?
    private var promptBar: NSView?
    private var promptField: NSTextField?
    private var promptLabel: NSTextField?
    private enum Prompt {
        case search(forward: Bool, count: Int)
        case command
    }
    private var prompt: Prompt = .command
    private var promptSubmit: NSButton?
    private var closeAfterCommandSave: Bool?

    init(document: SkrivDocument, settings: EditorSettings?,
         savedFrameName: NSWindow.FrameAutosaveName = "SkrivDocument") {
        self.savedFrameName = savedFrameName
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
        window.setFrameUsingName(savedFrameName)
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
        textView.setAccessibilityLabel("Document")
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
        window.delegate = self
        textView.delegate = self
        window.initialFirstResponder = textView
        textView.onModeChange = { [weak self] mode in self?.modeLabel.stringValue = mode }
        textView.onSearchRequest = { [weak self] forward, count in self?.showPrompt(.search(forward: forward, count: count)) }
        textView.onCommandRequest = { [weak self] in self?.showPrompt(.command) }
        textView.onSearchResult = { [weak self] message in
            guard let self else { return }
            self.modeLabel.stringValue = self.textView.engine.mode.label + (message.isEmpty ? "" : " — " + message)
        }
        applySettings(settings)
        LaunchMetrics.shared.markPhase("settings")
    }

    // Explicit saving lets all document windows share one preference; AppKit's
    // automatic frame saving only accepts a name for one open window at a time.
    private func saveWindowFrame() {
        guard let window, window.isVisible, !isInFullScreen,
              !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: savedFrameName)
    }

    func windowDidMove(_ notification: Notification) { saveWindowFrame() }
    func windowDidResize(_ notification: Notification) { saveWindowFrame() }
    func windowWillClose(_ notification: Notification) { saveWindowFrame() }

    func windowWillEnterFullScreen(_ notification: Notification) {
        saveWindowFrame()
        isInFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isInFullScreen = false
        saveWindowFrame()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isInFullScreen = false
    }

    private func showPrompt(_ prompt: Prompt) {
        guard let content = window?.contentView else { return }
        if promptBar == nil {
            let bar = NSView()
            let field = NSTextField()
            let direction = NSTextField(labelWithString: "/")
            let submit = NSButton(title: "Find", target: self, action: #selector(submitPrompt(_:)))
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPrompt(_:)))
            field.target = self
            field.action = #selector(submitPrompt(_:))
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
            promptBottom = scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -4)
            promptBar = bar
            promptField = field
            promptLabel = direction
            promptSubmit = submit
        }
        self.prompt = prompt
        switch prompt {
        case .search(let forward, _):
            promptLabel?.stringValue = forward ? "/" : "?"
            promptField?.placeholderString = "Find literal text"
            promptField?.setAccessibilityLabel("Vim literal search")
            promptSubmit?.title = "Find"
        case .command:
            promptLabel?.stringValue = ":"
            promptField?.placeholderString = "w, q, wq, x, q!"
            promptField?.setAccessibilityLabel("Vim command")
            promptSubmit?.title = "Run"
        }
        modeLabel.stringValue = textView.engine.mode.label
        promptField?.stringValue = ""
        promptBar?.isHidden = false
        editorBottom?.isActive = false
        promptBottom?.isActive = true
        window?.makeFirstResponder(promptField)
    }

    @objc private func submitPrompt(_ sender: Any?) {
        let input = promptField?.stringValue ?? ""
        closePrompt()
        switch prompt {
        case .search(let forward, let count):
            textView.submitSearch(input, forward: forward, count: count)
        case .command:
            executeCommand(input)
        }
    }

    @objc private func cancelPrompt(_ sender: Any?) { closePrompt() }

    private func closePrompt() {
        promptBottom?.isActive = false
        editorBottom?.isActive = true
        promptBar?.isHidden = true
        window?.makeFirstResponder(textView)
    }

    func executeCommand(_ input: String) {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard let command = ExCommand(input) else {
            showCommandResult("Unsupported command: :\(input)")
            return
        }
        guard let document = document as? NSDocument else { return }
        guard closeAfterCommandSave == nil, window?.attachedSheet == nil else {
            showCommandResult("Finish the current document operation first")
            return
        }
        switch command {
        case .quit(let force):
            guard force || !document.isDocumentEdited else {
                showCommandResult("Unsaved changes; use :w to save or :q! to discard")
                return
            }
            document.close()
        case .exit where !document.isDocumentEdited:
            document.close()
        case .write, .writeQuit, .exit:
            textView.breakUndoCoalescing()
            closeAfterCommandSave = command != .write
            document.save(withDelegate: self,
                          didSave: #selector(finishedCommandSave(_:didSave:contextInfo:)), contextInfo: nil)
        }
    }

    @objc private func finishedCommandSave(_ document: NSDocument, didSave: Bool,
                                          contextInfo: UnsafeMutableRawPointer?) {
        guard let shouldClose = closeAfterCommandSave else { return }
        closeAfterCommandSave = nil
        guard didSave else {
            showCommandResult("Save cancelled or failed; document remains open")
            return
        }
        // A save can complete asynchronously; never discard edits made during it.
        if shouldClose && !document.isDocumentEdited {
            document.close()
        } else {
            showCommandResult(document.isDocumentEdited ? "Unsaved changes remain" : "Saved")
        }
    }

    private func showCommandResult(_ message: String) {
        modeLabel.stringValue = textView.engine.mode.label + " — " + message
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closePrompt()
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

    func applySettings(_ configuration: EditorSettings?) {
        let settings = configuration ?? EditorSettings()
        let background = settings.background.map(EditorTheme.color) ?? EditorTheme.background
        let foreground = settings.foreground.map(EditorTheme.color) ?? EditorTheme.foreground
        window?.backgroundColor = background
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.textColor = foreground
        textView.insertionPointColor = settings.cursorColor.map(EditorTheme.color) ?? EditorTheme.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: settings.selectionBackground.map(EditorTheme.color) ?? EditorTheme.selectionBackground,
            .foregroundColor: settings.selectionForeground.map(EditorTheme.color) ?? foreground,
        ]
        textView.font = EditorFont.resolve(settings.fontFamily, size: settings.fontSize)
            ?? .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        textView.writingWidth = settings.writingWidth
        textView.normalKeyMappings = settings.normalKeyMappings
        textView.expandTab = settings.expandTabs
        textView.tabWidth = settings.tabWidth
        textView.shiftWidth = settings.indentWidth == 0 ? settings.tabWidth : settings.indentWidth
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = settings.wordWrap ? .byWordWrapping : .byCharWrapping
        let advance = (" " as NSString).size(withAttributes: [.font: textView.font!]).width
        style.tabStops = []
        style.defaultTabInterval = CGFloat(settings.tabWidth) * advance
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.paragraphStyle] = style
        // Presentation-only attributes must not create document edits or undo entries.
        textView.textStorage?.addAttribute(.paragraphStyle, value: style,
            range: NSRange(location: 0, length: (textView.string as NSString).length))
        scrollView.hasHorizontalScroller = !settings.wrap
        textView.isHorizontallyResizable = !settings.wrap
        textView.autoresizingMask = settings.wrap ? [.width] : []
        textView.textContainer?.widthTracksTextView = settings.wrap
        textView.wrapsToWritingColumn = settings.wrap
        textView.textContainer?.containerSize = NSSize(
            width: settings.wrap ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        if settings.wrap { textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height)) }
        let showNumbers = settings.number || settings.relativeNumber
        if showNumbers, numberRuler == nil {
            numberRuler = LineNumberRuler(scrollView: scrollView, editor: textView)
            scrollView.verticalRulerView = numberRuler
        }
        numberRuler?.relative = settings.relativeNumber
        numberRuler?.absolute = settings.number
        numberRuler?.numberColor = settings.lineNumberForeground.map(EditorTheme.color) ?? .secondaryLabelColor
        numberRuler?.editorBackground = settings.lineNumberBackground.map(EditorTheme.color) ?? background
        scrollView.hasVerticalRuler = showNumbers
        scrollView.rulersVisible = showNumbers
        textView.updateWritingInsets()
        textView.needsDisplay = true
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        (document as? NSDocument)?.undoManager
    }

    @objc func discardChanges(_ sender: Any?) {
        guard let document = document as? NSDocument, let window else { return }
        guard document.isDocumentEdited else {
            document.close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Discard changes to this document?"
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
