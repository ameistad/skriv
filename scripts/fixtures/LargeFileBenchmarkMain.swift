import AppKit
import CryptoKit

@MainActor func measure(_ work: @MainActor () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try autoreleasepool(invoking: work)
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func memory() -> [String: UInt64] {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return ["residentBytes": info.resident_size, "peakResidentBytes": UInt64(usage.ru_maxrss)]
}

func hash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let data = try file.read(upToCount: 1 << 20), !data.isEmpty else { return false }
        hash.update(data: data)
        return true
    }) {}
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

// Each workload/profile runs in a fresh process. No user files/configuration,
// clipboard changes or native Find animations. Only the visible profile opens a window.
_ = NSApplication.shared
let profile = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "offscreen"
NSApp.setActivationPolicy(profile == "visible" ? .accessory : .prohibited)
let shape = CommandLine.arguments[1]
let repetitions = Int(CommandLine.arguments[2])!
let unit = shape == "unicode" ? "En norsk notatlinje: blåbær, øl, ål, ærlig arbeid og 👩🏽‍💻.\n"
    : shape == "singleLine" ? "a" : "a\n"
let fixtureRoot = ProcessInfo.processInfo.environment["SKRIV_BENCHMARK_DIRECTORY"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
let directory = fixtureRoot.appendingPathComponent("skriv-large-file-input-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let input = directory.appendingPathComponent("input.txt")
let output = directory.appendingPathComponent("output.txt")
FileManager.default.createFile(atPath: input.path, contents: nil)
let file = try FileHandle(forWritingTo: input)
try autoreleasepool {
    let block = Data(String(repeating: unit, count: 1000).utf8)
    for _ in 0..<(repetitions / 1000) { try file.write(contentsOf: block) }
    try file.write(contentsOf: Data(String(repeating: unit, count: repetitions % 1000).utf8))
}
try file.close()
let inputHash = try hash(input)
var samples: [String: Any] = ["baseline": memory()]
var times: [String: Double] = [:]
let document = SkrivDocument()
times["loadMilliseconds"] = try measure { try document.read(from: input, ofType: SkrivDocument.typeName) }
let storage = document.textStorage
if profile == "engine" {
    var engine = VimEngine()
    samples["loaded"] = memory()
    times["firstEngineCommandMilliseconds"] = measure {
        precondition(engine.handle("<Esc>", storage: storage.mutableString, caret: 0) == .move(0))
    }
    samples["motionIndex"] = memory()
    times["lastLineJumpMilliseconds"] = measure {
        guard case .move(let offset) = engine.handle("G", storage: storage.mutableString, caret: 0) else {
            preconditionFailure("G did not move")
        }
        let expected = shape == "singleLine" ? 0 : storage.length
        precondition(offset == expected)
    }
    samples["afterJump"] = memory()
    var diagnostics: [String: Any] = [:]
    #if LAZY_INDEX_DIAGNOSTICS
    let metrics = engine.cacheMetrics
    diagnostics = ["indexedUTF16Length": metrics.indexedUTF16Length,
                   "cachedBytes": metrics.cachedBytes, "budgetBytes": metrics.budgetBytes,
                   "evictionCount": metrics.evictionCount, "entryCount": metrics.entryCount,
                   "metadataScanMilliseconds": metrics.metadataScanMilliseconds,
                   "graphemeBuildMilliseconds": metrics.graphemeBuildMilliseconds]
    #endif
    let report: [String: Any] = ["profile": profile, "shape": shape, "repetitions": repetitions,
        "utf8Bytes": unit.utf8.count * repetitions, "sha256": inputHash,
        "timings": times, "memory": samples, "indexDiagnostics": diagnostics]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
    try FileManager.default.removeItem(at: directory)
    exit(0)
}
if profile == "visible" {
    var controller: DocumentWindowController!
    times["visibleHierarchyMilliseconds"] = measure {
        controller = DocumentWindowController(document: document, settings: EditorSettings())
        document.addWindowController(controller)
    }
    times["visibleFirstDisplayMilliseconds"] = measure {
        controller.showWindow(nil)
        controller.window?.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    samples["loaded"] = memory()
    times["firstMotionMilliseconds"] = measure {
        controller.textView.handleVimKey("<Esc>")
        controller.window?.displayIfNeeded()
    }
    precondition(controller.textView.selectedRange().location == 0)
    samples["motionIndex"] = memory()
    let report: [String: Any] = ["profile": profile, "shape": shape, "repetitions": repetitions,
        "utf8Bytes": unit.utf8.count * repetitions, "sha256": inputHash,
        "timings": times, "memory": samples]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
    controller.close()
    try FileManager.default.removeItem(at: directory)
    exit(0)
}
let layout = NSLayoutManager()
let container = NSTextContainer(containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
layout.addTextContainer(container)
storage.addLayoutManager(layout)
let view = VimTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
view.isRichText = false
let scroll = NSScrollView()
var ruler: LineNumberRuler!
times["gutterIndexMilliseconds"] = measure { ruler = LineNumberRuler(scrollView: scroll, editor: view) }
samples["loaded"] = memory()
view.setSelectedRange(NSRange(location: 0, length: 0))
times["firstMotionMilliseconds"] = measure {
    view.handleVimKey("<Esc>")
}
precondition(view.selectedRange().location == 0)
samples["motionIndex"] = memory()
var motionTimes: [Double] = []
for _ in 0..<100 {
    motionTimes.append(measure { view.handleVimKey("l"); view.handleVimKey("h") })
    precondition(view.selectedRange().location == 0)
}
// Use the same snapshot semantics as the adapter without its find animation.
var search = LiteralSearch()
var snapshot = storage.string
snapshot.makeContiguousUTF8()
times["firstSearchMilliseconds"] = measure {
    precondition(search.submit(shape == "unicode" ? "blåbær" : "a", forward: true, text: snapshot, caret: 0) != nil)
}
samples["searchIndex"] = memory()
var searchTimes: [Double] = []
var caret = 0
for _ in 0..<100 {
    searchTimes.append(measure { caret = search.repeatMatch(reverse: false, text: snapshot, caret: caret)!.range.location })
}
search.invalidateMatches()
snapshot = ""
var editTimes: [Double] = []
var rebuildTimes: [Double] = []
var editCycleTimes: [Double] = []
for i in 0..<3 {
    let cycleStart = DispatchTime.now().uptimeNanoseconds
    // Include both the notification-time work and the following command.
    editTimes.append(measure { storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: i == 1 ? "e" : "E") })
    view.setSelectedRange(NSRange(location: 0, length: 0))
    rebuildTimes.append(measure { view.handleVimKey("l") })
    precondition(view.selectedRange().location == (shape == "denseLines" ? 0 : 1))
    editCycleTimes.append(Double(DispatchTime.now().uptimeNanoseconds - cycleStart) / 1_000_000)
}
var insertCycleTimes: [Double] = []
var deleteCycleTimes: [Double] = []
for _ in 0..<2 {
    insertCycleTimes.append(measure {
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("l")
        precondition(view.selectedRange().location == 1)
    })
    deleteCycleTimes.append(measure {
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.handleVimKey("l")
        precondition(view.selectedRange().location == (shape == "denseLines" ? 0 : 1))
    })
}
// Restore original bytes, serialize, and independently hash in bounded chunks.
storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: shape == "unicode" ? "E" : "a")
times["saveMilliseconds"] = try measure { try document.data(ofType: SkrivDocument.typeName).write(to: output) }
let outputHash = try hash(output)
precondition(outputHash == inputHash)
samples["saved"] = memory()
withExtendedLifetime(ruler) {}
let report: [String: Any] = ["profile": profile, "shape": shape, "repetitions": repetitions, "utf8Bytes": unit.utf8.count * repetitions,
    "sha256": inputHash, "timings": times, "memory": samples, "motionPairMilliseconds": motionTimes,
    "repeatSearchMilliseconds": searchTimes, "storageEditMilliseconds": editTimes,
    "postEditMotionMilliseconds": rebuildTimes, "editCycleMilliseconds": editCycleTimes,
    "insertCycleMilliseconds": insertCycleTimes, "deleteCycleMilliseconds": deleteCycleTimes]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
