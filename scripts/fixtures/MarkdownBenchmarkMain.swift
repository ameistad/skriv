import AppKit

@MainActor func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}
let shape = CommandLine.arguments[1]
let size = Int(CommandLine.arguments[2])!
let enabled = CommandLine.arguments[3] == "on"
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let unit: String
switch shape {
case "dense": unit = "**b** `c` [x](y) _e_\n"
case "long": unit = "a"
case "short": unit = "x\n"
default: unit = "# Heading\nA note with **emphasis**, `code`, [a link](https://example.test) and æøå 👩🏽‍💻.\n```swift\nlet x = 1\n```\n\n"
}
let repetitions = max(1, size / unit.utf8.count)
let text = String(repeating: unit, count: repetitions)
let document = SkrivDocument()
document.fileURL = URL(fileURLWithPath: "/tmp/skriv-benchmark.md")
document.textStorage.mutableString.setString(text)
var settings = EditorSettings()
settings.markdownHighlighting = enabled
var controller: DocumentWindowController!
let rssBefore = residentBytes()
let construction = milliseconds {
    controller = DocumentWindowController(document: document, settings: settings)
    document.addWindowController(controller)
}
let view = controller.textView
let highlighter = controller.markdownHighlighter
let initial = milliseconds {
    while highlighter?.hasPendingWork == true {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    }
}
// Give both modes the same opportunity to process AppKit's deferred initialization.
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
let rssHighlighted = residentBytes()
let initialBatches = highlighter?.batchMilliseconds ?? []
var scanCache = MarkdownScanCache()
let scannerOnly = milliseconds {
    if document.textStorage.length <= MarkdownHighlighter.maximumLength && enabled {
        while scanCache.hasPendingWork { scanCache.process(document.textStorage.mutableString) { _, _ in } }
    }
}
var editTimes: [Double] = []
var editAndColorTimes: [Double] = []
var batchCPU: [Double] = []
document.undoManager?.disableUndoRegistration()
for index in 0..<100 {
    // Same-width replacement in the first paragraph, with real native edit/selection handling.
    let beforeCount = highlighter?.batchMilliseconds.count ?? 0
    var native = 0.0
    let combined = milliseconds {
        native = milliseconds {
            view.insertText(index.isMultiple(of: 2) ? "X" : String(text.prefix(1)), replacementRange: NSRange(location: 0, length: 1))
        }
        while highlighter?.hasPendingWork == true { highlighter?.processPendingBatch() }
        if let container = view.textContainer {
            view.layoutManager?.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: 800, height: 600), in: container)
        }
    }
    editTimes.append(native)
    editAndColorTimes.append(combined)
    batchCPU.append((highlighter?.batchMilliseconds.dropFirst(beforeCount) ?? []).reduce(0, +))
}
precondition(document.textStorage.string == text)
var insertTimes: [Double] = [], deleteTimes: [Double] = []
var insertColorCPU: [Double] = [], deleteColorCPU: [Double] = []
for _ in 0..<100 {
    for insertion in [true, false] {
        let beforeCount = highlighter?.batchMilliseconds.count ?? 0
        let duration = milliseconds {
            view.insertText(insertion ? "z" : "", replacementRange: NSRange(location: 5, length: insertion ? 0 : 1))
            while highlighter?.hasPendingWork == true { highlighter?.processPendingBatch() }
            if let container = view.textContainer {
                view.layoutManager?.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: 800, height: 600), in: container)
            }
        }
        let cpu = (highlighter?.batchMilliseconds.dropFirst(beforeCount) ?? []).reduce(0, +)
        if insertion { insertTimes.append(duration); insertColorCPU.append(cpu) }
        else { deleteTimes.append(duration); deleteColorCPU.append(cpu) }
    }
}
precondition(document.textStorage.string == text)
let report: [String: Any] = [
    "shape": shape, "enabled": enabled, "utf8Bytes": text.utf8.count, "utf16Units": document.textStorage.length,
    "active": highlighter?.isActive ?? false, "controllerConstructionMilliseconds": construction,
    "queuedInitialCompletionMilliseconds": initial, "initialBatchMilliseconds": initialBatches,
    "scannerOnlyMilliseconds": scannerOnly, "nativeEditMilliseconds": editTimes,
    "editAndColorAndViewportLayoutMilliseconds": editAndColorTimes, "editColorCPUMilliseconds": batchCPU,
    "residentBeforeControllerBytes": rssBefore, "residentAfterHighlightBytes": rssHighlighted,
    "insertionAndColorAndViewportLayoutMilliseconds": insertTimes,
    "deletionAndColorAndViewportLayoutMilliseconds": deleteTimes,
    "insertionColorCPUMilliseconds": insertColorCPU, "deletionColorCPUMilliseconds": deleteColorCPU,
    "retainedLineBytes": highlighter?.retainedLineBytes ?? 0,
    "cachedLines": highlighter?.cachedLineCount ?? 0
]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
highlighter?.stop()
document.updateChangeCount(.changeCleared)
document.close()
