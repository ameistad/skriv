import Foundation

/// Deliberately small, line-oriented Markdown subset. All positions are native UTF-16.
enum MarkdownScanner {
    enum Kind: CaseIterable { case heading, marker, emphasis, link, code }
    struct Span: Equatable {
        let range: NSRange
        let kind: Kind
    }
    struct Fence: Equatable {
        let character: UInt16
        let count: Int
    }
    struct Result {
        let spans: [Span]
        let fence: Fence?
    }
    // Bound allocations and inline work even for a megabyte-long logical line.
    static let maximumInlineLength = 16_384

    static func scan(_ source: NSString, range: NSRange, incoming: Fence?) -> Result {
        guard range.length <= maximumInlineLength else {
            return Result(spans: incoming == nil ? [] : [Span(range: range, kind: .code)], fence: incoming)
        }
        let units = Array(source.substring(with: range).utf16)
        let n = units.count
        func space(_ c: UInt16) -> Bool { c == 32 || c == 9 }
        var first = 0
        while first < n && first < 4 && units[first] == 32 { first += 1 }
        if first < n && first <= 3 && (units[first] == 96 || units[first] == 126) {
            let character = units[first]
            var end = first
            while end < n && units[end] == character { end += 1 }
            let count = end - first
            if let incoming {
                if character == incoming.character && count >= incoming.count && units[end...].allSatisfy(space) {
                    return Result(spans: [Span(range: range, kind: .code)], fence: nil)
                }
            } else if count >= 3 && (character != 96 || !units[end...].contains(96)) {
                return Result(spans: [Span(range: range, kind: .code)], fence: Fence(character: character, count: count))
            }
        }
        if let incoming { return Result(spans: [Span(range: range, kind: .code)], fence: incoming) }
        var spans: [Span] = []
        func add(_ start: Int, _ end: Int, _ kind: Kind) {
            guard end > start else { return }
            spans.append(Span(range: NSRange(location: range.location + start, length: end - start), kind: kind))
        }
        if first <= 3 && first < n {
            var end = first
            while end < n && units[end] == 35 { end += 1 }
            if (1...6).contains(end - first) && (end == n || space(units[end])) { add(first, n, .heading) }
            if units[first] == 62 { add(first, first + 1, .marker) }
            if [UInt16(45), 43, 42].contains(units[first]), first + 1 < n, space(units[first + 1]) {
                add(first, first + 1, .marker)
            }
            end = first
            while end < n && end - first < 9 && (48...57).contains(units[end]) { end += 1 }
            if end > first && end + 1 < n && (units[end] == 46 || units[end] == 41) && space(units[end + 1]) {
                add(first, end + 1, .marker)
            }
        }
        // Build delimiter lookups once: unmatched delimiters never cause repeated suffix searches.
        var escaped = [Bool](repeating: false, count: n)
        var i = 0
        while i < n {
            if units[i] == 92 && i + 1 < n { escaped[i + 1] = true; i += 2 } else { i += 1 }
        }
        var ticks: [(start: Int, end: Int)] = []
        i = 0
        while i < n {
            if units[i] == 96 && !escaped[i] {
                let start = i
                repeat { i += 1 } while i < n && units[i] == 96
                ticks.append((start, i))
            } else { i += 1 }
        }
        var nextTick: [Int: (start: Int, end: Int)] = [:]
        var latest: [Int: (start: Int, end: Int)] = [:]
        for run in ticks.reversed() {
            nextTick[run.start] = latest[run.end - run.start]
            latest[run.end - run.start] = run
        }
        var parentheses: [Int] = []
        var closingParenthesis: [Int: Int] = [:]
        for index in 0..<n where !escaped[index] {
            if units[index] == 40 { parentheses.append(index) }
            if units[index] == 41, let opening = parentheses.popLast() { closingParenthesis[opening] = index }
        }
        var brackets: [Int] = []
        var emphasis: [Int: Int] = [:]
        func word(_ c: UInt16) -> Bool {
            (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c >= 128
        }
        i = 0
        while i < n {
            if escaped[i] { i += 1; continue }
            if units[i] == 96 {
                if let closing = nextTick[i] { add(i, closing.end, .code); i = closing.end; continue }
                repeat { i += 1 } while i < n && units[i] == 96
                continue
            }
            if units[i] == 91 { brackets.append(i) }
            if units[i] == 93, let opening = brackets.popLast(), i + 1 < n, units[i + 1] == 40,
               let end = closingParenthesis[i + 1] {
                let start = opening > 0 && units[opening - 1] == 33 && !escaped[opening - 1] ? opening - 1 : opening
                add(start, end + 1, .link)
                i = end + 1
                continue
            }
            if units[i] == 42 || units[i] == 95 {
                let start = i, delimiter = units[i]
                repeat { i += 1 } while i < n && units[i] == delimiter
                let count = i - start
                guard count <= 2 else { continue }
                let key = Int(delimiter) * 3 + count
                let intraword = delimiter == 95 && start > 0 && i < n && word(units[start - 1]) && word(units[i])
                if !intraword, start > 0, !space(units[start - 1]), let opening = emphasis.removeValue(forKey: key) {
                    add(opening, i, .emphasis)
                } else if !intraword, i < n, !space(units[i]) { emphasis[key] = start }
                continue
            }
            i += 1
        }
        // Code wins over enclosing emphasis/link colors, while headings are the base color.
        spans.sort { $0.kind.priority < $1.kind.priority }
        return Result(spans: spans, fence: nil)
    }
}

private extension MarkdownScanner.Kind {
    var priority: Int {
        switch self { case .heading: 0; case .marker: 1; case .emphasis: 2; case .link: 3; case .code: 4 }
    }
}

/// Retains only line boundaries and fence state, never a second document or token tree.
/// A partially scanned prefix is also a valid cache; edits can interrupt any batch.
struct MarkdownScanCache {
    private struct Line {
        var start: Int
        let outgoing: MarkdownScanner.Fence?
    }
    private var lines: [Line] = []
    private(set) var cursor: Int? = 0
    private var fence: MarkdownScanner.Fence?
    private var requiredEnd = 0
    var hasPendingWork: Bool { cursor != nil }
    var cachedLineCount: Int { lines.count }
    var retainedLineBytes: Int { lines.capacity * MemoryLayout<Line>.stride }

    mutating func edited(range: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(range) - delta
        var first = max(0, lines.partitionIndex { $0.start <= range.location } - 2)
        var start = lines.isEmpty ? 0 : lines[first].start
        if let cursor, cursor < start {
            start = cursor
            first = lines.partitionIndex { $0.start < start }
        }
        let suffix = min(lines.count, lines.partitionIndex { $0.start <= oldEnd } + 1)
        if delta != 0 {
            for index in suffix..<lines.count { lines[index].start += delta }
        }
        lines.removeSubrange(first..<max(first, suffix))
        fence = first > 0 ? lines[first - 1].outgoing : nil
        // A pending initial scan has no cached suffix. Do not converge before its
        // frontier and accidentally abandon the rest of the document after an edit.
        requiredEnd = max(NSMaxRange(range), cursor.map { max(requiredEnd, $0) + delta } ?? 0)
        cursor = start
    }

    /// Call outside text-storage edit processing. Budget includes applying the returned colors.
    /// Returns scanned UTF-16 units for diagnostics, without a timer in the normal idle path.
    @discardableResult
    mutating func process(_ source: NSString, budgetNanoseconds: UInt64 = 2_000_000,
                          apply: (NSRange, [MarkdownScanner.Span]) -> Void) -> Int {
        guard var position = cursor else { return 0 }
        let began = DispatchTime.now().uptimeNanoseconds
        let first = lines.partitionIndex { $0.start < position }
        var oldIndex = first
        var replacement: [Line] = []
        var scanned = 0
        repeat {
            while oldIndex < lines.count && lines[oldIndex].start < position { oldIndex += 1 }
            var end = 0, contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            let result = MarkdownScanner.scan(source, range: NSRange(location: position, length: contentsEnd - position), incoming: fence)
            let converged = oldIndex < lines.count && lines[oldIndex].start == position
                && position >= requiredEnd && lines[oldIndex].outgoing == result.fence
            replacement.append(Line(start: position, outgoing: result.fence))
            apply(NSRange(location: position, length: end - position), result.spans)
            if oldIndex < lines.count && lines[oldIndex].start == position { oldIndex += 1 }
            scanned += end - position
            fence = result.fence
            position = end
            cursor = end < source.length && !converged ? end : nil
            if cursor == nil { break }
        } while DispatchTime.now().uptimeNanoseconds - began < budgetNanoseconds
        lines.replaceSubrange(first..<oldIndex, with: replacement)
        return scanned
    }
}
