import Foundation
let cases = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var results: [[String: Any]] = []
for c in cases {
    var text = c["text"] as! String
    var caret = c["caret"] as! Int
    var engine = VimEngine()
    engine.reset(mode: .normal)
    for key in c["keys"] as! String {
        switch engine.handle(String(key), text: text, caret: caret) {
        case .move(let offset): caret = offset
        case .select(_, let offset): caret = offset
        case .edit(let range, let replacement, let offset): text = (text as NSString).replacingCharacters(in: range, with: replacement); caret = offset
        default: break
        }
    }
    results.append(["text":text,"caret":caret,"reg":engine.register.text,"type":engine.register.linewise ? "V" : "v"])
}
let output = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
FileHandle.standardOutput.write(output)
