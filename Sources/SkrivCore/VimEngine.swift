import Foundation

extension String {
    /// String equality uses canonical equivalence, which cannot validate cached
    /// UTF-16 positions. Compare exact bytes, using contiguous storage when available.
    func isByteIdentical(to other: String) -> Bool {
        return utf8.withContiguousStorageIfAvailable { left in
            other.utf8.withContiguousStorageIfAvailable { right in
                left.count == right.count && (left.isEmpty || left.baseAddress == right.baseAddress ||
                    memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0)
            } ?? utf8.elementsEqual(other.utf8)
        } ?? utf8.elementsEqual(other.utf8)
    }
}

extension RandomAccessCollection where Index == Int {
    /// First index whose element fails `isBefore`, for a collection partitioned by it.
    /// Lives here because the conformance and benchmark scripts compile this file alone.
    func partitionIndex(where isBefore: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = (low + high) / 2
            if isBefore(self[middle]) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// The deliberately small native Vim subset. Offsets crossing the AppKit boundary are UTF-16;
/// editing and motion calculations use extended grapheme clusters, never Unicode scalars.
enum VimEffect: Equatable {
    case passThrough
    case handled
    case move(Int)
    case edit(range: NSRange, replacement: String, caret: Int)
    case undo
    case redo
    case select(range: NSRange, caret: Int)
    case beginCommand
    case beginSearch(forward: Bool, count: Int)
    case repeatSearch(reverse: Bool, count: Int)
}

struct VimEngine {
    enum Mode: String {
        case insert, normal, visual, visualLine
        var isVisual: Bool { self == .visual || self == .visualLine }
        var label: String { self == .visualLine ? "VISUAL LINE" : rawValue.uppercased() }
    }
    struct Register: Equatable {
        var text: String
        var linewise: Bool
    }
    private(set) var mode: Mode = .normal
    private(set) var register = Register(text: "", linewise: false)
    private(set) var registerGeneration: UInt = 0
    private var pendingCount: Int?
    private var operation: String?
    private var operationCount = 1
    private var operationHasCount = false
    private var awaitingG = false
    private var desiredColumn: Int?
    private var visualAnchor = 0
    private var visualCaret = 0
    /// The active end can differ from the lower bound of the native selection.
    var activeVisualCaret: Int? { mode.isVisual ? visualCaret : nil }
    // One disposable chunk index per editor, shared by Normal and Visual modes.
    // Native storage supplies edit deltas. Standalone immutable-string callers
    // use exact byte equality to protect UTF-16 offsets across normalization.
    private var cachedBuffer: Buffer?
    private var cachedText: String?
    private var usesNativeStorage = false
    struct CacheMetrics {
        var indexedUTF16Length = 0
        var cachedBytes = 0
        var budgetBytes = 0
        var evictionCount = 0
        var entryCount = 0
        var metadataScanMilliseconds = 0.0
        var graphemeBuildMilliseconds = 0.0
    }
    var cacheBudgetBytes = 4 * 1024 * 1024 {
        didSet { ensureUniqueBuffer(); cachedBuffer?.setBudget(cacheBudgetBytes) }
    }
    var cacheMetrics: CacheMetrics { cachedBuffer?.metrics ?? CacheMetrics(budgetBytes: max(0, cacheBudgetBytes)) }
    var lastReindexedUTF16Length: Int { cachedBuffer?.lastReindexedUTF16Length ?? 0 }

    mutating func invalidateTextCache() {
        cachedBuffer = nil
        cachedText = nil
        usesNativeStorage = false
    }

    private mutating func ensureUniqueBuffer() {
        if !isKnownUniquelyReferenced(&cachedBuffer) { cachedBuffer = cachedBuffer?.copy() }
    }

    /// Native storage notifications supply an exact edit delta. Unchanged chunks
    /// keep their cached indexes; only nearby lightweight metadata is rescanned.
    mutating func textDidChange(_ source: NSString, editedRange: NSRange, changeInLength: Int) {
        guard usesNativeStorage else { invalidateTextCache(); return }
        ensureUniqueBuffer()
        cachedBuffer?.update(source, editedRange: editedRange, delta: changeInLength)
    }

    private mutating func buffer(for text: String) -> Buffer {
        if !usesNativeStorage, let cachedBuffer, let cachedText, cachedText.isByteIdentical(to: text) { return cachedBuffer }
        let buffer = Buffer(text, budget: cacheBudgetBytes)
        cachedBuffer = buffer
        cachedText = text
        usesNativeStorage = false
        return buffer
    }

    /// The caller must invalidate on storage replacement and deliver character
    /// edits via textDidChange. No whole-document Swift snapshot is required.
    mutating func handle(_ key: String, storage: NSString, caret: Int) -> VimEffect {
        guard mode != .insert || key == "<Esc>" else { return .passThrough }
        if !usesNativeStorage || cachedBuffer == nil {
            cachedBuffer = Buffer(storage, budget: cacheBudgetBytes)
            cachedText = nil
            usesNativeStorage = true
        }
        return handle(key, buffer: cachedBuffer!, caret: caret)
    }

    var canApplyNormalMapping: Bool { mode == .normal && operation == nil && !awaitingG }

    mutating func reset(mode: Mode = .normal) {
        self.mode = mode
        clearPending()
        desiredColumn = nil
    }

    mutating func setRegister(text: String, linewise: Bool) {
        register = Register(text: text, linewise: linewise)
    }

    mutating func handle(_ key: String, text: String, caret: Int) -> VimEffect {
        guard mode != .insert || key == "<Esc>" else { return .passThrough }
        return handle(key, buffer: buffer(for: text), caret: caret)
    }

    private mutating func handle(_ key: String, buffer b: Buffer, caret: Int) -> VimEffect {
        defer { b.endCommand() }
        if mode.isVisual { return handleVisual(key, buffer: b) }
        guard mode == .normal || key == "<Esc>" else { return .passThrough }
        let position = b.index(at: caret)
        if key == "<Esc>" {
            let wasInsert = mode == .insert
            mode = .normal
            clearPending()
            desiredColumn = nil
            let line = b.line(at: position)
            return .move(b.offset(b.normal(wasInsert && position > line.start ? b.previous(position) : position)))
        }
        guard mode == .normal else { return .passThrough }
        let i = b.normal(position)
        if accumulateCount(key) { return .handled }
        let (count, explicitCount) = takeCount()
        if let effect = motion(key, count: count, explicitCount: explicitCount, b: b, i: i, visual: false) { return effect }
        if let op = operation, key == op {
            let total = min(10_000, operationCount * count)
            clearPending()
            desiredColumn = nil
            if total > 1 && b.lineNumber(at: i) == b.lines.count - 1 { return .move(b.offset(i)) }
            let effect = lineOperation(op, b: b, first: b.lineNumber(at: i), last: b.lineNumber(at: i) + total - 1)
            return op == "y" ? .move(b.offset(i)) : effect
        }
        if operation != nil { clearPending(); return .handled }
        desiredColumn = nil
        switch key {
        case ":": return explicitCount ? .handled : .beginCommand
        case "v", "V":
            mode = key == "v" ? .visual : .visualLine
            visualAnchor = b.offset(i)
            visualCaret = visualAnchor
            return visualSelection(b)
        case "/", "?": return .beginSearch(forward: key == "/", count: count)
        case "n", "N": return .repeatSearch(reverse: key == "N", count: count)
        case "d", "c", "y":
            operation = key
            operationCount = count
            operationHasCount = explicitCount
            return .handled
        case "i": mode = .insert; return .move(b.offset(i))
        case "a": mode = .insert; return .move(b.offset(min(b.next(i), b.line(at: i).end)))
        case "I": mode = .insert; return .move(b.offset(b.firstNonblank(b.lineNumber(at: i))))
        case "A": mode = .insert; return .move(b.offset(b.line(at: i).end))
        case "o", "O":
            mode = .insert
            let line = b.line(at: i)
            let at = key == "o" ? line.end : line.start
            return .edit(range: b.range(at, at), replacement: "\n", caret: b.offset(at) + (key == "o" ? 1 : 0))
        case "x", "X":
            let line = b.line(at: i)
            return characterOperation("d", b: b, lower: key == "x" ? i : max(line.start, b.advance(i, by: -count)), upper: key == "x" ? min(line.end, b.advance(i, by: count)) : i)
        case "D", "C":
            let last = min(b.lines.count - 1, b.lineNumber(at: i) + count - 1)
            return characterOperation(key == "D" ? "d" : "c", b: b, lower: i, upper: b.lines[last].end)
        case "Y":
            _ = lineOperation("y", b: b, first: b.lineNumber(at: i), last: b.lineNumber(at: i) + count - 1)
            return .move(b.offset(i))
        case "p", "P": return paste(b: b, i: i, after: key == "p", count: count)
        case "u": return .undo
        case "<C-r>": return .redo
        default: return .handled
        }
    }

    private mutating func handleVisual(_ key: String, buffer b: Buffer) -> VimEffect {
        let head = b.index(at: visualCaret)
        let anchor = b.index(at: visualAnchor)
        visualCaret = b.offset(head)
        visualAnchor = b.offset(anchor)
        if key == "<Esc>" || (key == "v" && mode == .visual) || (key == "V" && mode == .visualLine) {
            reset(mode: .normal)
            return .move(b.offset(b.normal(head)))
        }
        if key == "v" || key == "V" {
            mode = key == "v" ? .visual : .visualLine
            clearPending()
            return visualSelection(b)
        }
        if key == "o" {
            swap(&visualAnchor, &visualCaret)
            desiredColumn = nil
            clearPending()
            return visualSelection(b)
        }
        if ["d", "x", "c", "y"].contains(key) {
            let linewise = mode == .visualLine
            let op = key == "x" ? "d" : key
            reset(mode: .normal)
            if linewise {
                let effect = lineOperation(op, b: b, first: min(b.lineNumber(at: anchor), b.lineNumber(at: head)),
                                           last: max(b.lineNumber(at: anchor), b.lineNumber(at: head)))
                return op == "y" ? .move(b.offset(head < anchor ? b.normal(head) : b.line(at: anchor).start)) : effect
            }
            let effect = characterOperation(op, b: b, lower: min(anchor, head), upper: b.next(max(anchor, head)))
            return op == "y" ? .move(b.offset(b.normal(min(anchor, head)))) : effect
        }
        if accumulateCount(key) { return .handled }
        let (count, explicitCount) = takeCount()
        guard let effect = motion(key, count: count, explicitCount: explicitCount, b: b, i: head, visual: true) else {
            clearPending()
            return .handled
        }
        if case .move(let next) = effect { visualCaret = next }
        return visualSelection(b)
    }

    private static let arrowAliases = ["<Left>": "h", "<Right>": "l", "<Up>": "k", "<Down>": "j"]
    private static let motionKeys: Set = ["h", "j", "k", "l", "0", "^", "$", "w", "b", "e", "W", "B", "E", "G"]

    /// Absorbs a count digit. A leading zero is the line-start motion, not a count.
    private mutating func accumulateCount(_ key: String) -> Bool {
        guard key.count == 1, let n = key.first?.wholeNumberValue, n < 10, n > 0 || pendingCount != nil else { return false }
        pendingCount = min(10_000, (pendingCount ?? 0) * 10 + n)
        return true
    }

    private mutating func takeCount() -> (count: Int, explicit: Bool) {
        defer { pendingCount = nil }
        return (pendingCount ?? 1, pendingCount != nil)
    }

    /// Motions and the `g` prefix, shared by Normal and Visual modes. Returns nil for any other key.
    private mutating func motion(_ input: String, count: Int, explicitCount: Bool, b: Buffer, i: Int, visual: Bool) -> VimEffect? {
        let key = Self.arrowAliases[input] ?? input
        if awaitingG {
            awaitingG = false
            guard key == "g" else { clearPending(); return .handled }
            return executeMotion("gg", count: count, explicitCount: explicitCount, b: b, i: i, visual: visual)
        }
        if key == "g" {
            awaitingG = true
            // Keep a leading count until the second g arrives.
            if explicitCount { pendingCount = count }
            return .handled
        }
        guard Self.motionKeys.contains(key) else { return nil }
        return executeMotion(key, count: count, explicitCount: explicitCount, b: b, i: i, visual: visual)
    }

    private func visualSelection(_ b: Buffer) -> VimEffect {
        let anchor = b.index(at: visualAnchor)
        let head = b.index(at: visualCaret)
        let lower = min(anchor, head)
        let upper = max(anchor, head)
        let range: NSRange
        if mode == .visualLine {
            let first = b.line(at: lower).start
            let last = b.lineNumber(at: upper)
            let end = last + 1 < b.lines.count ? b.lines[last + 1].start : b.length
            range = b.range(first, end)
        } else {
            range = b.range(lower, b.next(upper))
        }
        return .select(range: range, caret: b.offset(head))
    }

    private mutating func clearPending() {
        pendingCount = nil
        operation = nil
        operationCount = 1
        operationHasCount = false
        awaitingG = false
    }

    private mutating func capture(_ text: String, linewise: Bool) {
        register = Register(text: text, linewise: linewise)
        registerGeneration &+= 1
    }

    private mutating func executeMotion(_ key: String, count: Int, explicitCount: Bool, b: Buffer, i: Int, visual: Bool) -> VimEffect {
        let op = operation
        let total = min(10_000, operationCount * count)
        let lineIndex = b.lineNumber(at: i)
        let line = b.lines[lineIndex]
        var target = i
        var inclusive = false
        var linewise = false
        if key != "j" && key != "k" { desiredColumn = nil }
        switch key {
        case "h": target = max(line.start, b.advance(i, by: -total))
        case "l": target = min(line.end, b.advance(i, by: total))
        case "0": target = line.start
        case "^": target = b.firstNonblank(lineIndex)
        case "$":
            let last = b.lines[min(b.lines.count - 1, lineIndex + total - 1)]
            target = visual ? last.end : max(last.start, b.previous(last.end))
            inclusive = true
            desiredColumn = Int.max
        case "j", "k":
            let column = desiredColumn ?? b.column(at: i)
            desiredColumn = column
            let next = min(b.lines.count - 1, max(0, lineIndex + (key == "j" ? total : -total)))
            if op != nil && next == lineIndex { clearPending(); return .move(b.offset(i)) }
            let destination = b.lines[next]
            target = b.position(in: destination, column: column, visual: visual)
            linewise = true
        case "G", "gg":
            let requested = (explicitCount || operationHasCount) ? total - 1 : (key == "G" ? b.lines.count - 1 : 0)
            target = b.firstNonblank(min(b.lines.count - 1, max(0, requested)))
            linewise = true
        case "w", "W", "b", "B", "e", "E":
            let big = key == key.uppercased()
            // Vim treats cw on a word as ce, leaving the following whitespace intact.
            let motion = op == "c" && key.lowercased() == "w" && b.category(i, big: big) != 0 ? "e" : key.lowercased()
            target = b.wordMotion(motion, from: i, count: total, big: big, operatorWord: op != nil && motion == "w", initialWordEnd: op == "c" && key.lowercased() == "w" && motion == "e")
            inclusive = motion == "e"
        default: break
        }
        clearPending()
        guard let op else { return .move(b.offset(visual ? target : b.normal(target))) }
        desiredColumn = nil
        if linewise {
            let effect = lineOperation(op, b: b, first: min(lineIndex, b.lineNumber(at: target)), last: max(lineIndex, b.lineNumber(at: target)))
            return op == "y" ? .move(b.offset(min(i, target))) : effect
        }
        // Exclusive motions ending at column zero stop at the preceding line;
        // operations beginning before its first word cover those complete lines.
        if !inclusive && target > i && target == b.line(at: target).start {
            if i <= b.firstNonblank(lineIndex) {
                return lineOperation(op, b: b, first: lineIndex, last: b.lineNumber(at: target) - 1)
            }
            target = b.previous(target)
        }
        let lower = min(i, target)
        var upper = max(i, target)
        if !inclusive && upper > lower && upper == b.line(at: upper).start,
           lower <= b.firstNonblank(b.lineNumber(at: lower)) {
            let effect = lineOperation(op, b: b, first: b.lineNumber(at: lower), last: b.lineNumber(at: upper) - 1)
            return op == "y" ? .move(b.offset(lower)) : effect
        }
        if inclusive { upper = upper < b.length && !b.isNewline(upper) ? b.next(upper) : upper }
        if op == "d", b.lineNumber(at: upper) > b.lineNumber(at: lower),
           lower <= b.firstNonblank(b.lineNumber(at: lower)), upper >= b.line(at: upper).end {
            return lineOperation(op, b: b, first: b.lineNumber(at: lower), last: b.lineNumber(at: upper))
        }
        return characterOperation(op, b: b, lower: lower, upper: upper)
    }

    private mutating func characterOperation(_ op: String, b: Buffer, lower: Int, upper: Int) -> VimEffect {
        if op == "c" { mode = .insert }
        guard upper > lower else { return op == "c" ? .move(b.offset(lower)) : .handled }
        capture(b.substring(lower, upper), linewise: false)
        if op == "y" { return .move(b.offset(lower)) }
        let range = b.range(lower, upper)
        if mode == .insert { return .edit(range: range, replacement: "", caret: range.location) }
        // Only the joined line can change grapheme boundaries or caret clamping.
        // Avoid copying and indexing the entire document to predict this caret.
        let start = b.line(at: lower).start
        let end = b.line(at: upper).end
        let after = Buffer(b.substring(start, lower) + b.substring(upper, max(upper, end)))
        let base = b.offset(start)
        let index = after.index(at: range.location - base)
        return .edit(range: range, replacement: "", caret: base + after.offset(after.normal(index)))
    }

    private mutating func lineOperation(_ op: String, b: Buffer, first: Int, last: Int) -> VimEffect {
        let first = min(max(0, first), b.lines.count - 1)
        let last = min(max(first, last), b.lines.count - 1)
        let start = b.lines[first].start
        let end = last + 1 < b.lines.count ? b.lines[last + 1].start : b.length
        var captured = b.substring(start, end)
        if last == b.lines.count - 1 { captured += "\n" }
        capture(captured, linewise: true)
        if op == "y" { return .handled }
        if op == "c" {
            mode = .insert
            let replacement = last + 1 < b.lines.count ? "\n" : ""
            return .edit(range: b.range(start, end), replacement: replacement, caret: b.offset(start))
        }
        // Removing a final unterminated line also removes its preceding separator.
        let lower = end == b.length && last + 1 == b.lines.count && first > 0 ? b.previous(start) : start
        let range = b.range(lower, end)
        let caret: Int
        if last + 1 < b.lines.count {
            caret = b.offset(b.firstNonblank(last + 1)) - range.length
        } else {
            caret = first > 0 ? b.offset(b.firstNonblank(first - 1)) : 0
        }
        return .edit(range: range, replacement: "", caret: caret)
    }

    private func paste(b: Buffer, i: Int, after: Bool, count: Int) -> VimEffect {
        guard !register.text.isEmpty else { return .handled }
        let content = String(repeating: register.text, count: count)
        if register.linewise {
            let line = b.line(at: i)
            let inserted = Buffer(content)
            let firstNonblank = inserted.offset(inserted.firstNonblank(0))
            if after {
                if line.end < b.length {
                    let at = b.next(line.end)
                    return .edit(range: b.range(at, at), replacement: content, caret: b.offset(at) + firstNonblank)
                }
                let body = content.hasSuffix("\n") ? String(content.dropLast()) : content
                return .edit(range: b.range(line.end, line.end), replacement: "\n" + body, caret: b.offset(line.end) + 1 + firstNonblank)
            }
            let content = content.hasSuffix("\n") ? content : content + "\n"
            return .edit(range: b.range(line.start, line.start), replacement: content, caret: b.offset(line.start) + firstNonblank)
        }
        let at = after ? min(b.next(i), b.line(at: i).end) : i
        let inserted = Buffer(content)
        let lastOffset = inserted.previous(inserted.length)
        return .edit(range: b.range(at, at), replacement: content, caret: b.offset(at) + lastOffset)
    }

    /// Positions are native UTF-16 offsets. Only line metadata is collected up
    /// front; visiting a chunk creates its disposable sparse grapheme index.
    /// Native mutable storage remains the sole editable text owner.
    private final class Buffer {
        struct Line { let start: Int; let end: Int }
        private final class Chunk {
            let length: Int
            let lines: [Line]
            var fragment: Fragment?
            var bytes = 0
            var access: UInt64 = 0
            init(length: Int, lines: [Line]) { self.length = length; self.lines = lines }
        }
        private static let targetSize = 16_384
        private var source: NSString
        private var chunks: [Chunk] = []
        private var starts: [Int] = []
        private var lineStarts: [Int] = []
        private(set) var length = 0
        private var lineCount = 0
        private var clock: UInt64 = 0
        // An oversized logical line may temporarily exceed the cache budget,
        // but its snapshot/index is released at the end of the command.
        private var temporary: (chunk: Chunk, fragment: Fragment)?
        private(set) var metrics: CacheMetrics
        private(set) var lastReindexedUTF16Length = 0

        convenience init(_ text: String, budget: Int = 4 * 1024 * 1024) { self.init(text as NSString, budget: budget) }
        init(_ source: NSString, budget: Int = 4 * 1024 * 1024) {
            self.source = source
            metrics = CacheMetrics(budgetBytes: max(0, budget))
            chunks = scan(NSRange(location: 0, length: source.length))
            rebuildTotals()
        }

        /// Bounded UTF-16 reads avoid a whole-document Swift conversion. Only
        /// CR, LF and CRLF are Vim lines; the gutter intentionally has broader
        /// Foundation line-separator semantics.
        private func scan(_ range: NSRange) -> [Chunk] {
            let began = DispatchTime.now().uptimeNanoseconds
            defer { metrics.metadataScanMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000 }
            lastReindexedUTF16Length = range.length
            var result: [Chunk] = []
            var lines: [Line] = []
            var chunkStart = range.location
            var lineStart = chunkStart
            let limit = NSMaxRange(range)
            var pendingCR: Int?
            func separator(_ start: Int, _ end: Int) {
                lines.append(Line(start: lineStart - chunkStart, end: start - chunkStart))
                lineStart = end
                if end - chunkStart >= Self.targetSize {
                    // Every chunk includes a final (possibly empty) line.
                    lines.append(Line(start: end - chunkStart, end: end - chunkStart))
                    result.append(Chunk(length: end - chunkStart, lines: lines))
                    chunkStart = end
                    lines = []
                }
            }
            var units = [unichar](repeating: 0, count: min(32_768, max(1, range.length)))
            var blockStart = range.location
            while blockStart < limit {
                let count = min(units.count, limit - blockStart)
                source.getCharacters(&units, range: NSRange(location: blockStart, length: count))
                for index in 0..<count {
                    let at = blockStart + index
                    let unit = units[index]
                    if let cr = pendingCR {
                        pendingCR = nil
                        separator(cr, unit == 10 ? at + 1 : at)
                        if unit == 10 { continue }
                    }
                    if unit == 13 { pendingCR = at }
                    else if unit == 10 { separator(at, at + 1) }
                }
                blockStart += count
            }
            if let cr = pendingCR { separator(cr, limit) }
            if chunkStart < limit || result.isEmpty {
                lines.append(Line(start: lineStart - chunkStart, end: limit - chunkStart))
                result.append(Chunk(length: limit - chunkStart, lines: lines))
            }
            return result
        }

        private init(copying other: Buffer) {
            source = other.source
            metrics = other.metrics
            starts = other.starts
            lineStarts = other.lineStarts
            length = other.length
            lineCount = other.lineCount
            clock = other.clock
            lastReindexedUTF16Length = other.lastReindexedUTF16Length
            chunks = other.chunks.map { old in
                let chunk = Chunk(length: old.length, lines: old.lines)
                chunk.fragment = old.fragment
                chunk.bytes = old.bytes
                chunk.access = old.access
                return chunk
            }
        }
        func copy() -> Buffer { Buffer(copying: self) }

        private func rebuildTotals() {
            starts.removeAll(keepingCapacity: true)
            lineStarts.removeAll(keepingCapacity: true)
            length = 0
            lineCount = 0
            for (i, chunk) in chunks.enumerated() {
                starts.append(length)
                lineStarts.append(lineCount)
                length += chunk.length
                lineCount += chunk.lines.count - (i + 1 < chunks.count ? 1 : 0)
            }
        }

        func update(_ source: NSString, editedRange: NSRange, delta: Int) {
            self.source = source
            temporary = nil
            let oldEnd = NSMaxRange(editedRange) - delta
            guard editedRange.location >= 0, oldEnd >= editedRange.location, oldEnd <= length,
                  source.length == length + delta else {
                chunks = scan(NSRange(location: 0, length: source.length))
                metrics.cachedBytes = 0
                metrics.entryCount = 0
                rebuildTotals()
                return
            }
            let first = max(0, chunk(at: editedRange.location) - 1)
            let last = min(chunks.count - 1, chunk(at: oldEnd) + 1)
            let start = starts[first]
            let end = (last + 1 < chunks.count ? starts[last + 1] : length) + delta
            for i in first...last { discard(chunks[i], eviction: false) }
            let replacement = scan(NSRange(location: start, length: end - start))
            chunks.replaceSubrange(first...last, with: replacement)
            rebuildTotals()
        }

        func endCommand() { temporary = nil }
        func setBudget(_ bytes: Int) {
            metrics.budgetBytes = max(0, bytes)
            trim(to: metrics.budgetBytes)
        }
        private func discard(_ chunk: Chunk, eviction: Bool) {
            guard chunk.fragment != nil else { return }
            metrics.cachedBytes -= chunk.bytes
            metrics.entryCount -= 1
            if eviction { metrics.evictionCount += 1 }
            chunk.fragment = nil
            chunk.bytes = 0
        }
        private func trim(to maximum: Int) {
            while metrics.cachedBytes > maximum,
                  let oldest = chunks.filter({ $0.fragment != nil }).min(by: { $0.access < $1.access }) {
                discard(oldest, eviction: true)
            }
        }
        private func fragment(_ i: Int) -> Fragment {
            let chunk = chunks[i]
            clock &+= 1
            chunk.access = clock
            if let fragment = chunk.fragment { return fragment }
            if let temporary, temporary.chunk === chunk { return temporary.fragment }
            let began = DispatchTime.now().uptimeNanoseconds
            let fragment = Fragment(source.substring(with: NSRange(location: starts[i], length: chunk.length)))
            metrics.graphemeBuildMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
            metrics.indexedUTF16Length += chunk.length
            // Includes owned UTF-8 text, conservative checkpoint allocation,
            // and object/array overhead, not merely the logical checkpoint count.
            let bytes = fragment.estimatedBytes
            if bytes <= metrics.budgetBytes {
                trim(to: metrics.budgetBytes - bytes)
                chunk.fragment = fragment
                chunk.bytes = bytes
                metrics.cachedBytes += bytes
                metrics.entryCount += 1
            } else {
                temporary = (chunk, fragment)
            }
            return fragment
        }
        // A giant logical line must not build and discard an oversized Swift
        // snapshot on every key. Foundation resolves composed-character ranges
        // against the complete native string, including unbounded RI/combining
        // context. This fallback retains no character index or text copy.
        private func direct(_ i: Int) -> Bool { chunks[i].length > Self.targetSize * 4 }
        private func composed(at position: Int) -> NSRange { source.rangeOfComposedCharacterSequence(at: position) }
        private func chunk(at position: Int) -> Int { max(0, starts.partitionIndex { $0 <= position } - 1) }
        func offset(_ position: Int) -> Int { min(max(0, position), length) }
        func index(at offset: Int) -> Int {
            let offset = self.offset(offset)
            if offset == length { return length }
            let i = chunk(at: offset)
            if direct(i) { return composed(at: offset).location }
            let f = fragment(i)
            return starts[i] + f.offset(f.index(at: offset - starts[i]))
        }
        func advance(_ position: Int, by count: Int) -> Int {
            guard count != 0 else { return position }
            var at = position
            var remaining = count
            while remaining != 0 && (remaining > 0 ? at < length : at > 0) {
                let i = chunk(at: remaining < 0 ? at - 1 : at)
                if direct(i) {
                    at = remaining > 0 ? NSMaxRange(composed(at: at)) : composed(at: at - 1).location
                    remaining += remaining > 0 ? -1 : 1
                    continue
                }
                let f = fragment(i)
                let local = f.index(at: at - starts[i])
                let next = min(f.characterCount, max(0, local + remaining))
                remaining -= next - local
                at = starts[i] + f.offset(next)
            }
            return at
        }
        func next(_ position: Int) -> Int { advance(position, by: 1) }
        func previous(_ position: Int) -> Int { advance(position, by: -1) }
        func column(at position: Int) -> Int {
            let i = chunk(at: position)
            if direct(i) {
                var at = line(at: position).start
                var column = 0
                while at < position { at = NSMaxRange(composed(at: at)); column += 1 }
                return column
            }
            let f = fragment(i)
            return f.index(at: position - starts[i]) - f.index(at: line(at: position).start - starts[i])
        }
        func position(in line: Line, column: Int, visual: Bool) -> Int {
            let end = visual ? line.end : max(line.start, previous(line.end))
            if column == Int.max { return end }
            let i = chunk(at: line.start)
            if direct(i) {
                var at = line.start
                var remaining = column
                while remaining > 0 && at < end { at = NSMaxRange(composed(at: at)); remaining -= 1 }
                return min(at, end)
            }
            let f = fragment(i)
            let first = f.index(at: line.start - starts[i])
            let last = f.index(at: end - starts[i])
            return starts[i] + f.offset(min(last, first + column))
        }
        func lineNumber(at position: Int) -> Int {
            let i = chunk(at: position)
            return lineStarts[i] + max(0, chunks[i].lines.partitionIndex { $0.start <= position - starts[i] } - 1)
        }
        struct Lines: RandomAccessCollection {
            typealias Index = Int
            fileprivate let buffer: Buffer
            var startIndex: Int { 0 }
            var endIndex: Int { buffer.lineCount }
            subscript(position: Int) -> Line {
                let i = Swift.max(0, buffer.lineStarts.partitionIndex { $0 <= position } - 1)
                let line = buffer.chunks[i].lines[position - buffer.lineStarts[i]]
                return Line(start: buffer.starts[i] + line.start, end: buffer.starts[i] + line.end)
            }
        }
        var lines: Lines { Lines(buffer: self) }
        func line(at position: Int) -> Line { lines[lineNumber(at: position)] }
        func normal(_ position: Int) -> Int {
            let position = offset(position)
            let line = line(at: position)
            return position < line.end ? position : max(line.start, previous(line.end))
        }
        func firstNonblank(_ number: Int) -> Int {
            let line = lines[number]
            var i = line.start
            while i < line.end {
                let c = character(i)
                if c != " " && c != "\t" { break }
                i = next(i)
            }
            return i == line.end ? line.start : i
        }
        private func character(_ position: Int) -> Character {
            let i = chunk(at: position)
            if direct(i) { return source.substring(with: composed(at: position)).first! }
            let f = fragment(i)
            return f.character(f.index(at: position - starts[i]))
        }
        func isNewline(_ position: Int) -> Bool {
            guard position < length else { return false }
            let unit = source.character(at: position)
            return unit == 10 || unit == 13
        }
        func category(_ position: Int, big: Bool) -> Int {
            guard position < length else { return 0 }
            let c = character(position)
            if c.isWhitespace { return 0 }
            return big || c.isLetter || c.isNumber || c == "_" ? 1 : 2
        }
        func range(_ lower: Int, _ upper: Int) -> NSRange { NSRange(location: lower, length: upper - lower) }
        func substring(_ lower: Int, _ upper: Int) -> String { source.substring(with: range(lower, upper)) }

        func wordMotion(_ motion: String, from start: Int, count: Int, big: Bool, operatorWord: Bool = false, initialWordEnd: Bool = false) -> Int {
            // Keep a String cursor for sequential scans so long words do not
            // repeatedly seek from sparse checkpoints.
            var cursorPosition = -1
            var cursorChunk = -1
            var text = ""
            var cursor = text.startIndex
            func value(_ position: Int) -> Character {
                let i = chunk(at: position)
                if direct(i) { return character(position) }
                if i != cursorChunk {
                    cursorChunk = i
                    text = fragment(i).text
                    cursorPosition = -1
                }
                if cursorPosition != position {
                    let f = fragment(i)
                    cursor = f.stringIndex(f.index(at: position - starts[i]))
                    cursorPosition = position
                }
                return text[cursor]
            }
            func nextPosition(_ position: Int) -> Int {
                guard position < length else { return length }
                if direct(chunk(at: position)) { return NSMaxRange(composed(at: position)) }
                _ = value(position)
                let next = text.index(after: cursor)
                let offset = position + text[cursor..<next].utf16.count
                cursor = next
                cursorPosition = offset
                return offset
            }
            func previousPosition(_ position: Int) -> Int {
                guard position > 0 else { return 0 }
                let i = chunk(at: position - 1)
                if direct(i) { return composed(at: position - 1).location }
                if i != cursorChunk { cursorChunk = i; text = fragment(i).text; cursorPosition = -1 }
                if cursorPosition != position {
                    let f = fragment(i)
                    cursor = f.stringIndex(f.index(at: position - starts[i]))
                }
                let before = text.index(before: cursor)
                let previous = position - text[before..<cursor].utf16.count
                cursor = before
                cursorPosition = previous
                return previous
            }
            func kind(_ position: Int) -> Int {
                guard position < length else { return 0 }
                let c = value(position)
                if c.isWhitespace { return 0 }
                return big || c.isLetter || c.isNumber || c == "_" ? 1 : 2
            }
            var i = start
            for step in 0..<count {
                switch motion {
                case "w":
                    if i >= length { return i }
                    let category = kind(i)
                    if category == 0 { i = nextPosition(i) }
                    else { while i < length && kind(i) == category { i = nextPosition(i) } }
                    while i < length && kind(i) == 0 {
                        if operatorWord && step == count - 1 && isNewline(i) { return i }
                        if isNewline(i) && line(at: i).start == i { break }
                        i = nextPosition(i)
                    }
                case "b":
                    if i == 0 { return 0 }
                    i = previousPosition(i)
                    while i > 0 && kind(i) == 0 {
                        if isNewline(i) && line(at: i).start == i { break }
                        i = previousPosition(i)
                    }
                    let category = kind(i)
                    if category != 0 {
                        while i > 0 {
                            let before = previousPosition(i)
                            if kind(before) != category { break }
                            i = before
                        }
                    }
                case "e":
                    if i >= length { return i }
                    if nextPosition(i) == length { return isNewline(i) ? length : i }
                    if !(initialWordEnd && step == 0) { i = nextPosition(i) }
                    while i < length && kind(i) == 0 { i = nextPosition(i) }
                    if i == length { return i }
                    let category = kind(i)
                    while true {
                        let next = nextPosition(i)
                        if next >= length || kind(next) != category { break }
                        i = next
                    }
                default: break
                }
            }
            return i
        }
    }

    private struct Fragment {
        let text: String
        // A checkpoint every 32 graphemes replaces the old Character + Int per
        // grapheme arrays. String slices share the snapshot; lookups scan at most
        // one small block, including on very long single-line documents.
        private static let stride = 32
        let characterCount: Int
        let utf16Count: Int
        let checkpoints: [(index: String.Index, offset: Int)]

        init(_ text: String) {
            var text = text
            text.makeContiguousUTF8()
            self.text = text
            var checkpoints: [(index: String.Index, offset: Int)] = []
            var count = 0
            var offset = 0
            text.utf8.withContiguousStorageIfAvailable { bytes in
                var byte = 0
                while byte < bytes.count {
                    if count.isMultiple(of: Self.stride) {
                        checkpoints.append((text.utf8.index(text.utf8.startIndex, offsetBy: byte), offset))
                    }
                    let value = bytes[byte]
                    // ASCII followed by ASCII has a known grapheme boundary,
                    // except CRLF. Before non-ASCII, let Swift handle combining
                    // marks, emoji and the complete Unicode grapheme rules.
                    let ascii = value < 128 && (byte + 1 == bytes.count || bytes[byte + 1] < 128)
                        && !(value == 13 && byte + 1 < bytes.count && bytes[byte + 1] == 10)
                    if ascii {
                        byte += 1
                        offset += 1
                    } else {
                        let index = text.utf8.index(text.utf8.startIndex, offsetBy: byte)
                        let next = text.index(after: index)
                        let end = text.utf8.distance(from: text.utf8.startIndex, to: next)
                        // Count UTF-16 units from UTF-8 lead bytes. Creating a
                        // Substring.UTF16View here repeatedly transcodes text.
                        while byte < end {
                            let byteValue = bytes[byte]
                            if byteValue < 128 || byteValue >= 192 { offset += byteValue >= 240 ? 2 : 1 }
                            byte += 1
                        }
                    }
                    count += 1
                }
            }
            if count.isMultiple(of: Self.stride) { checkpoints.append((text.endIndex, offset)) }
            self.characterCount = count
            self.utf16Count = offset
            self.checkpoints = checkpoints
        }

        var estimatedBytes: Int { text.utf8.count + checkpoints.count * MemoryLayout<(String.Index, Int)>.stride * 2 + 256 }

        func stringIndex(_ position: Int) -> String.Index {
            let position = min(max(0, position), characterCount)
            return text.index(checkpoints[position / Self.stride].index, offsetBy: position % Self.stride)
        }
        func character(_ position: Int) -> Character { text[stringIndex(position)] }
        func offset(_ position: Int) -> Int {
            let position = min(max(0, position), characterCount)
            let checkpoint = checkpoints[position / Self.stride]
            let end = text.index(checkpoint.index, offsetBy: position % Self.stride)
            return checkpoint.offset + text[checkpoint.index..<end].utf16.count
        }
        func index(at offset: Int) -> Int {
            let block = max(0, checkpoints.partitionIndex { $0.offset <= offset } - 1)
            var position = block * Self.stride
            var current = checkpoints[block].index
            var distance = checkpoints[block].offset
            while current < text.endIndex {
                let next = text.index(after: current)
                distance += text[current..<next].utf16.count
                if distance > offset { break }
                position += 1
                current = next
            }
            return position
        }
    }
}
