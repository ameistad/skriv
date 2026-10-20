import Foundation

func measure(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

var results: [[String: Any]] = []
var checksum = 0
for lines in [1000, 10_000] {
    let text = String(repeating: "En norsk notatlinje: blåbær, øl, ål, ærlig arbeid og 👩🏽‍💻.\n", count: lines)
    var engine = VimEngine()
    engine.reset(mode: .normal)
    var caret = 0
    let first = measure { _ = engine.handle("l", text: text, caret: 0) }
    var motions: [Double] = []
    for i in 0..<(lines == 1000 ? 200 : 40) {
        motions.append(measure {
            if case .move(let next) = engine.handle(i.isMultiple(of: 2) ? "l" : "h", text: text, caret: caret) {
                caret = next
                checksum += next
            }
        })
    }
    var visual: [Double] = []
    _ = engine.handle("v", text: text, caret: 0)
    for i in 0..<40 {
        visual.append(measure {
            if case .select(_, let next) = engine.handle(i.isMultiple(of: 2) ? "l" : "h", text: text, caret: caret) {
                caret = next
                checksum += next
            }
        })
    }
    var search = LiteralSearch()
    _ = search.submit("blåbær", forward: true, text: text, caret: 0)
    var searches: [Double] = []
    caret = 0
    for _ in 0..<40 {
        searches.append(measure {
            if let match = search.repeatMatch(reverse: false, text: text, caret: caret) {
                caret = match.range.location
                checksum += caret
            }
        })
    }
    results.append(["lines": lines, "utf8Bytes": text.utf8.count,
                    "firstMotionMilliseconds": first, "motionMilliseconds": motions,
                    "visualMilliseconds": visual, "searchMilliseconds": searches])
}
let data = try JSONSerialization.data(withJSONObject: ["workloads": results, "checksum": checksum], options: [.sortedKeys])
FileHandle.standardOutput.write(data)
