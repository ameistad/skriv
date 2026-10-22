import Foundation

/// Disposable UTF-16 line starts. Edits rescan their surrounding lines and
/// shift the unaffected suffix in place, without copying or rescanning its text.
struct LineStartIndex {
    private(set) var starts = [0]

    init(_ text: NSString) { rebuild(text) }

    mutating func rebuild(_ text: NSString) {
        starts = [0]
        appendStarts(in: text, from: 0, through: text.length, to: &starts)
    }

    mutating func update(_ text: NSString, editedRange: NSRange, changeInLength delta: Int) {
        let oldEnd = NSMaxRange(editedRange) - delta
        let first = max(0, starts.partitionIndex { $0 <= editedRange.location } - 2)
        // Include one unchanged line on both sides, including CR/LF joins.
        let suffix = min(starts.count, starts.partitionIndex { $0 <= oldEnd } + 1)
        let end = suffix < starts.count ? starts[suffix] + delta : text.length
        var replacement: [Int] = []
        appendStarts(in: text, from: starts[first], through: end, to: &replacement)
        if suffix < starts.count, replacement.last == end { replacement.removeLast() }
        if delta != 0 {
            for index in suffix..<starts.count { starts[index] += delta }
        }
        starts.replaceSubrange((first + 1)..<suffix, with: replacement)
    }

    func line(at offset: Int) -> Int { max(0, starts.partitionIndex { $0 <= offset } - 1) }

    private func appendStarts(in text: NSString, from start: Int, through limit: Int, to result: inout [Int]) {
        var position = start
        while position < limit {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: position, length: 0))
            guard end > position else { break }
            if end < text.length || contentsEnd < end { result.append(end) }
            position = end
        }
    }
}
