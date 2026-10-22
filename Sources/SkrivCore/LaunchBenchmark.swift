import AppKit

/// Benchmark-only driver used by scripts/benchmark.swift launch via `--benchmark-launch-count`.
/// It invokes the same document-opening action on the main loop. It never sends synthetic
/// input and never closes a modified or saved document. Inert without the flag.
@MainActor
public enum LaunchBenchmark {
    private static let requestedCount: Int? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--benchmark-launch-count"),
              arguments.indices.contains(index + 1),
              let count = Int(arguments[index + 1]), (1...1000).contains(count) else { return nil }
        return count
    }()

    static var isRequested: Bool { requestedCount != nil }

    /// Identical geometry for both builds, independent of the pointer and saved preferences.
    /// Benchmark windows never save their frame into the interactive app's preferences.
    static var windowFrame: NSRect? {
        guard isRequested, let screen = NSScreen.screens.first else { return nil }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1000, visible.width), height: min(700, visible.height))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    public static func startIfRequested(createDocument: @escaping @MainActor () -> Void) {
        guard let count = requestedCount else { return }

        let startupDocuments = NSDocumentController.shared.documents.filter {
            $0.fileURL == nil && !$0.isDocumentEdited
        }
        Task { @MainActor in
            await waitForOpening(startupDocuments)
            try? await Task.sleep(for: .milliseconds(150))
            // Keep emitted stage names stable for comparisons with historical reports.
            LaunchMetrics.shared.recordMemory(stage: "oneEmptyNote")
            for document in startupDocuments where document.fileURL == nil && !document.isDocumentEdited {
                document.close()
            }
            try? await Task.sleep(for: .milliseconds(500))
            LaunchMetrics.shared.recordMemory(stage: "residentNoWindows")
            for iteration in 0..<count {
                let before = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
                createDocument()
                let owned = NSDocumentController.shared.documents.filter { !before.contains(ObjectIdentifier($0)) }
                await waitForOpening(owned)
                if iteration == count - 1,
                   let sample = owned.first as? SkrivDocument,
                   sample.textStorage.length == 0, !sample.isDocumentEdited {
                    // This is a newly created benchmark-owned document; preserve any intervening user edits.
                    let text = String(repeating: "En norsk notatlinje: blåbær, øl, ål, ærlig arbeid og 👩🏽‍💻.\n", count: 1000)
                    sample.textStorage.mutableString.setString(text)
                    for controller in sample.windowControllers {
                        controller.window?.displayIfNeeded()
                    }
                    try? await Task.sleep(for: .seconds(1))
                    LaunchMetrics.shared.recordMemory(stage: "representativeNote")
                    if sample.textStorage.string == text {
                        sample.textStorage.mutableString.setString("")
                        sample.updateChangeCount(.changeCleared)
                    }
                }
                try? await Task.sleep(for: .milliseconds(40))
                for document in owned where document.fileURL == nil && !document.isDocumentEdited {
                    document.close()
                }
            }
            // Let AppKit release transient drawing surfaces before recording resident idle memory.
            try? await Task.sleep(for: .seconds(1))
            LaunchMetrics.shared.recordMemory(stage: "residentAfterWarmRuns")
            NSApp.terminate(nil)
        }
    }

    private static func waitForOpening(_ documents: [NSDocument]) async {
        let controllers = documents.flatMap(\.windowControllers).compactMap { $0 as? DocumentWindowController }
        let deadline = ContinuousClock.now + .seconds(10)
        while controllers.contains(where: { !$0.isOpeningComplete }) {
            precondition(ContinuousClock.now < deadline, "Benchmark window did not become active and ready within 10 seconds")
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
