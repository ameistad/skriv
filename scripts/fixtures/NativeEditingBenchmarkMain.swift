import AppKit

@MainActor func measure(_ work: @MainActor () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

// Offscreen views exercise the actual command adapter without synthetic input,
// windows, user configuration, clipboard operations, or find-indicator animations.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
var results: [[String: Any]] = []
var checksum = 0
for lines in [1000, 10_000, 100_000] {
    let text = String(repeating: "En norsk notatlinje: blåbær, øl, ål, ærlig arbeid og 👩🏽‍💻.\n", count: lines)
    // Match the app's explicit TextKit 1 stack.
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    let view = VimTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
    view.isRichText = false
    view.string = text
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.handleVimKey("<Esc>")
    view.handleVimKey("l")
    var motions: [Double] = []
    for i in 0..<100 {
        motions.append(measure { view.handleVimKey(i.isMultiple(of: 2) ? "h" : "l") })
        precondition(view.selectedRange() == NSRange(location: i.isMultiple(of: 2) ? 0 : 1, length: 0))
        checksum += view.selectedRange().location
    }
    // Direct storage edits must invalidate the adapter's snapshot, too.
    var edits: [Double] = []
    for i in 0..<10 {
        view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 1), with: i.isMultiple(of: 2) ? "e" : "E")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        edits.append(measure { view.handleVimKey("l") })
        precondition(view.selectedRange() == NSRange(location: 1, length: 0))
        checksum += view.selectedRange().location
    }
    results.append(["lines": lines, "utf8Bytes": text.utf8.count,
                    "motionMilliseconds": motions, "postEditMotionMilliseconds": edits])
}
let data = try JSONSerialization.data(withJSONObject: ["workloads": results, "checksum": checksum], options: [.sortedKeys])
FileHandle.standardOutput.write(data)
