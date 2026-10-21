import AppKit

@MainActor
final class SkrivDocumentController: NSDocumentController {
    /// Applied to every new document; nil means the built-in editor settings.
    var currentSettings: EditorSettings?

    override init() {
        super.init()
        // Native tab-management actions require tabbing to be
        // enabled. DocumentWindowController suppresses automatic grouping while
        // showing a window; presentation destinations are chosen explicitly here.
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    required init?(coder: NSCoder) { fatalError("Skriv creates its document controller programmatically.") }

    var activeDocumentWindow: NSWindow? {
        let application = NSApplication.shared
        let candidates = [application.keyWindow?.sheetParent, application.keyWindow, application.mainWindow]
            + application.orderedWindows.map(Optional.some)
        return candidates.compactMap { $0 }.first {
            TabDestination.isOpen($0) && ($0.isVisible || $0.isMiniaturized)
        }
    }

    override func openUntitledDocumentAndDisplay(_ displayDocument: Bool) throws -> NSDocument {
        let destination = TabDestination(window: activeDocumentWindow)
        let document = try super.openUntitledDocumentAndDisplay(false)
        if displayDocument { present(document, in: destination) }
        return document
    }

    @objc func newWindowForTab(_ sender: Any?) {
        newTab(in: (sender as? NSWindow) ?? activeDocumentWindow)
    }

    func newTab(in window: NSWindow?) {
        createDocument(in: TabDestination(window: window))
    }

    @objc func newWindow(_ sender: Any?) {
        createDocument(in: nil)
    }

    private func createDocument(in destination: TabDestination?) {
        do {
            let document = try super.openUntitledDocumentAndDisplay(false)
            present(document, in: destination)
        } catch { presentError(error) }
    }

    override func openDocument(_ sender: Any?) {
        // Keep the original destination even if the Open panel changes key windows.
        let destination = TabDestination(window: activeDocumentWindow)
        beginOpenPanel { [weak self] urls in
            guard let self, let urls else { return }
            openDocuments(urls[...], in: destination, completionHandler: { _ in })
        }
    }

    /// Finder and the Open panel each keep one destination for the whole batch,
    /// even if an already-open file temporarily selects a different window.
    func openDocuments(at urls: [URL], completionHandler: @escaping (Bool) -> Void) {
        openDocuments(urls[...], in: TabDestination(window: activeDocumentWindow),
                      completionHandler: completionHandler)
    }

    private func openDocuments(_ urls: ArraySlice<URL>, in destination: TabDestination,
                               completionHandler: @escaping (Bool) -> Void) {
        guard let url = urls.first else {
            completionHandler(true)
            return
        }
        openDocument(at: url, in: destination) { [weak self] _, _, error in
            guard let self else { return }
            if let error { presentError(error) }
            openDocuments(urls.dropFirst(), in: destination) { success in
                completionHandler(success && error == nil)
            }
        }
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard displayDocument else {
            super.openDocument(withContentsOf: url, display: false, completionHandler: completionHandler)
            return
        }
        openDocument(at: url, in: TabDestination(window: activeDocumentWindow),
                     completionHandler: completionHandler)
    }

    private func openDocument(at url: URL, in destination: TabDestination,
                              completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        super.openDocument(withContentsOf: url, display: false) { [self] document, alreadyOpen, error in
            if let document { present(document, in: destination) }
            completionHandler(document, alreadyOpen, error)
        }
    }

    /// A nil destination explicitly requests a separate window. Existing documents
    /// are only selected, never transferred out of their current group.
    func present(_ document: NSDocument, in destination: TabDestination?) {
        if document.windowControllers.isEmpty {
            document.makeWindowControllers()
            if let window = document.windowControllers.first?.window {
                if let anchor = destination?.insertionWindow, let group = anchor.tabGroup,
                   let index = group.windows.firstIndex(of: anchor) {
                    group.insertWindow(window, at: index + 1)
                    group.selectedWindow = window
                }
                destination?.advance(to: window)
            }
        }
        document.showWindows()
    }

    func applySettings(_ settings: EditorSettings) {
        currentSettings = settings
        for document in documents {
            for controller in document.windowControllers {
                (controller as? DocumentWindowController)?.applySettings(settings)
            }
        }
    }

    /// Open our custom extension as plain text, reusing an existing unsaved buffer.
    func openConfiguration(at url: URL) throws {
        if let existing = document(for: url) {
            present(existing, in: TabDestination(window: activeDocumentWindow))
            return
        }
        let destination = TabDestination(window: activeDocumentWindow)
        let document = try SkrivDocument(contentsOf: url, ofType: SkrivDocument.configurationTypeName)
        addDocument(document)
        present(document, in: destination)
    }

    override var defaultType: String? { SkrivDocument.typeName }

    override func documentClass(forType typeName: String) -> AnyClass? {
        SkrivDocument.self
    }
}

/// An opening operation's destination, not a second tab model. AppKit owns group
/// membership; retain its group only for the lifetime of the opening operation so
/// closing the original tab can fall back to a surviving sibling.
@MainActor
final class TabDestination {
    private weak var anchor: NSWindow?
    private var group: NSWindowTabGroup?

    init(window: NSWindow?) {
        anchor = window
        group = window?.tabGroup
    }

    var insertionWindow: NSWindow? {
        if let anchor, Self.isOpen(anchor) { return anchor }
        return group?.windows.first(where: Self.isOpen)
    }

    func advance(to window: NSWindow) {
        anchor = window
        group = window.tabGroup
    }

    static func isOpen(_ window: NSWindow) -> Bool {
        guard let controller = window.windowController as? DocumentWindowController else { return false }
        return controller.document != nil && !controller.isClosing
    }
}
