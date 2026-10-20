import AppKit

@MainActor
final class SettingsImportController {
    private(set) var settings: NeovimSettings?
    private(set) var isImporting = false
    var onChange: ((NeovimSettings?) -> Void)?
    private let cache: NeovimSettingsCache
    private let importer: NeovimImporter

    init(cache: NeovimSettingsCache = NeovimSettingsCache(), importer: NeovimImporter = NeovimImporter()) {
        self.cache = cache
        self.importer = importer
        settings = cache.load()
    }

    func importSettings() {
        guard !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                var imported = try await importer.importSettings()
                if !imported.guifont.isEmpty && EditorFont.resolve(imported.guifont) == nil {
                    imported.warnings.append("The guifont value could not be applied; Skriv uses its built-in monospace font.")
                }
                try cache.save(imported)
                settings = imported
                onChange?(imported)
                showReport(imported)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func resetSettings() {
        guard !isImporting else { return }
        do {
            try cache.remove()
            settings = nil
            onChange?(nil)
        } catch { NSAlert(error: error).runModal() }
    }

    func showReport() {
        guard let settings else {
            let alert = NSAlert()
            alert.messageText = "Using Built-in Settings"
            alert.informativeText = "Import Neovim Settings to read your current Neovim profile. Opening a note never launches Neovim."
            alert.runModal()
            return
        }
        showReport(settings)
    }

    private func showReport(_ settings: NeovimSettings) {
        let alert = NSAlert()
        alert.messageText = "Neovim Settings Imported"
        alert.informativeText = "Resolved colors and editor options are cached locally.\n\(settings.normalKeyMappings.count) Normal-mode remaps applied; \(settings.unsupportedMappings.count) mappings unsupported. Refresh explicitly after changing your Neovim configuration."
        var report = settings.warnings.map { "Warning: \($0)" }
        report += settings.normalKeyMappings.sorted(by: { $0.key < $1.key }).map { "Applied: n \($0.key) → \($0.value)" }
        report += settings.unsupportedMappings
        if !report.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 240))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = report.joined(separator: "\n")
            text.autoresizingMask = [.width]
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        alert.runModal()
    }
}
