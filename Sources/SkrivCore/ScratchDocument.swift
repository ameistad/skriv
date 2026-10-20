import AppKit
import UniformTypeIdentifiers

/// The text storage owns the note. Views and file serialization share that storage.
@MainActor
@objc(SkrivDocument)
public final class ScratchDocument: NSDocument {
    static let typeName = UTType.plainText.identifier
    let textStorage = NSTextStorage()
    private var pendingClose: DocumentCloseRequest?

    public override init() {
        super.init()
        hasUndoManager = true
    }

    public override class var autosavesInPlace: Bool { false }
    public override class var readableTypes: [String] { [typeName] }
    public override class var writableTypes: [String] { [typeName] }

    public override func makeWindowControllers() {
        let settings = (NSDocumentController.shared as? ScratchDocumentController)?.currentSettings
        addWindowController(NoteWindowController(document: self, settings: settings))
    }

    public override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                                  contextInfo: UnsafeMutableRawPointer?) {
        guard isDocumentEdited else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        let request = DocumentCloseRequest(delegate: delegate as AnyObject,
                                           selector: shouldCloseSelector, context: contextInfo)
        guard pendingClose == nil else {
            request.reply(document: self, shouldClose: false)
            return
        }
        pendingClose = request
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(displayName ?? "Untitled")”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        if let window = windowForSheet {
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.resolveClose(response)
            }
        } else {
            resolveClose(alert.runModal())
        }
    }

    private func resolveClose(_ response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn:
            save(withDelegate: self, didSave: #selector(finishedCloseSave(_:didSave:contextInfo:)), contextInfo: nil)
        case .alertThirdButtonReturn:
            finishClose(true)
        default:
            finishClose(false)
        }
    }

    @objc private func finishedCloseSave(_ document: NSDocument, didSave: Bool,
                                        contextInfo: UnsafeMutableRawPointer?) {
        finishClose(didSave)
    }

    private func finishClose(_ shouldClose: Bool) {
        let request = pendingClose
        pendingClose = nil
        request?.reply(document: self, shouldClose: shouldClose)
    }

    public override func data(ofType typeName: String) throws -> Data {
        Data(textStorage.string.utf8)
    }

    public override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        // AppKit reads on the main thread because concurrent reading is off (the NSDocument default).
        MainActor.assumeIsolated {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        }
    }
}

/// Bridge NSDocument's documented delegate selector without assuming its name.
/// AppKit uses this callback for both window closing and application termination.
@MainActor
struct DocumentCloseRequest {
    let delegate: AnyObject
    let selector: Selector?
    let context: UnsafeMutableRawPointer?

    func reply(document: NSDocument, shouldClose: Bool) {
        guard let selector,
              let implementation = class_getMethodImplementation(object_getClass(delegate), selector) else { return }
        typealias Callback = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        let callback = unsafeBitCast(implementation, to: Callback.self)
        callback(delegate, selector, document, shouldClose, context)
    }
}
