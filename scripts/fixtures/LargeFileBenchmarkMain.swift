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

// Each workload runs in a fresh process. No user files/configuration, windows,
// clipboard changes or native Find animations. Native layout is not measured.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let shape = CommandLine.arguments[1]
let repetitions = Int(CommandLine.arguments[2])!
let unit = shape == "unicode" ? "En norsk notatlinje: blåbær, øl, ål, ærlig arbeid og 👩🏽‍💻.\n"
    : shape == "singleLine" ? "a" : "a\n"
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
times["firstMotionMilliseconds"] = measure { view.handleVimKey("<Esc>") }
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
let report: [String: Any] = ["shape": shape, "repetitions": repetitions, "utf8Bytes": unit.utf8.count * repetitions,
    "sha256": inputHash, "timings": times, "memory": samples, "motionPairMilliseconds": motionTimes,
    "repeatSearchMilliseconds": searchTimes, "storageEditMilliseconds": editTimes,
    "postEditMotionMilliseconds": rebuildTimes, "editCycleMilliseconds": editCycleTimes,
    "insertCycleMilliseconds": insertCycleTimes, "deleteCycleMilliseconds": deleteCycleTimes]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
