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
    private(set) var mode: Mode = .insert
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
    var lastReindexedUTF16Length: Int { cachedBuffer?.lastReindexedUTF16Length ?? 0 }

    mutating func invalidateTextCache() {
        cachedBuffer = nil
        cachedText = nil
        usesNativeStorage = false
    }

    /// Native storage notifications supply an exact edit delta. Unchanged chunks
    /// stay immutable; only the edit's neighborhood is copied and reindexed.
    mutating func textDidChange(_ source: NSString, editedRange: NSRange, changeInLength: Int) {
        guard usesNativeStorage else { invalidateTextCache(); return }
        cachedBuffer?.update(source, editedRange: editedRange, delta: changeInLength)
    }

    private mutating func buffer(for text: String) -> Buffer {
        if !usesNativeStorage, let cachedBuffer, let cachedText, cachedText.isByteIdentical(to: text) { return cachedBuffer }
        let buffer = Buffer(text)
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
            cachedBuffer = Buffer(storage)
            cachedText = nil
            usesNativeStorage = true
        }
        return handle(key, buffer: cachedBuffer!, caret: caret)
    }

    var canApplyNormalMapping: Bool { mode == .normal && operation == nil && !awaitingG }

    mutating func reset(mode: Mode = .insert) {
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
        if mode.isVisual { return handleVisual(key, buffer: b) }
        guard mode == .normal || key == "<Esc>" else { return .passThrough }
        let position = b.index(at: caret)
        if key == "<Esc>" {
            let wasInsert = mode == .insert
            mode = .normal
            clearPending()
            desiredColumn = nil
            let line = b.line(at: position)
            return .move(b.offset(b.normal(wasInsert && position > line.start ? position - 1 : position)))
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
        case "a": mode = .insert; return .move(b.offset(min(i + 1, b.line(at: i).end)))
        case "I": mode = .insert; return .move(b.offset(b.firstNonblank(b.lineNumber(at: i))))
        case "A": mode = .insert; return .move(b.offset(b.line(at: i).end))
        case "o", "O":
            mode = .insert
            let line = b.line(at: i)
            let at = key == "o" ? line.end : line.start
            return .edit(range: b.range(at, at), replacement: "\n", caret: b.offset(at) + (key == "o" ? 1 : 0))
        case "x", "X":
            let line = b.line(at: i)
            return characterOperation("d", b: b, lower: key == "x" ? i : max(line.start, i - count), upper: key == "x" ? min(line.end, i + count) : i)
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
            let effect = characterOperation(op, b: b, lower: min(anchor, head), upper: min(b.characterCount, max(anchor, head) + 1))
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
            let end = last + 1 < b.lines.count ? b.lines[last + 1].start : b.characterCount
            range = b.range(first, end)
        } else {
            range = b.range(lower, min(b.characterCount, upper + 1))
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
        case "h": target = max(line.start, i - total)
        case "l": target = min(line.end, i + total)
        case "0": target = line.start
        case "^": target = b.firstNonblank(lineIndex)
        case "$":
            let last = b.lines[min(b.lines.count - 1, lineIndex + total - 1)]
            target = visual ? last.end : max(last.start, last.end - 1)
            inclusive = true
            desiredColumn = Int.max
        case "j", "k":
            let column = desiredColumn ?? (i - line.start)
            desiredColumn = column
            let next = min(b.lines.count - 1, max(0, lineIndex + (key == "j" ? total : -total)))
            if op != nil && next == lineIndex { clearPending(); return .move(b.offset(i)) }
            let destination = b.lines[next]
            target = destination.start + min(column, max(0, destination.end - destination.start - (visual ? 0 : 1)))
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
            target -= 1
        }
        let lower = min(i, target)
        var upper = max(i, target)
        if !inclusive && upper > lower && upper == b.line(at: upper).start,
           lower <= b.firstNonblank(b.lineNumber(at: lower)) {
            let effect = lineOperation(op, b: b, first: b.lineNumber(at: lower), last: b.lineNumber(at: upper) - 1)
            return op == "y" ? .move(b.offset(lower)) : effect
        }
        if inclusive { upper = min(b.characterCount, upper + (upper < b.characterCount && !b.isNewline(upper) ? 1 : 0)) }
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
        let end = last + 1 < b.lines.count ? b.lines[last + 1].start : b.characterCount
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
        let lower = end == b.characterCount && last + 1 == b.lines.count && first > 0 ? start - 1 : start
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
                if line.end < b.characterCount {
                    let at = line.end + 1
                    return .edit(range: b.range(at, at), replacement: content, caret: b.offset(at) + firstNonblank)
                }
                let body = content.hasSuffix("\n") ? String(content.dropLast()) : content
                return .edit(range: b.range(line.end, line.end), replacement: "\n" + body, caret: b.offset(line.end) + 1 + firstNonblank)
            }
            let content = content.hasSuffix("\n") ? content : content + "\n"
            return .edit(range: b.range(line.start, line.start), replacement: content, caret: b.offset(line.start) + firstNonblank)
        }
        let at = after ? min(i + 1, b.line(at: i).end) : i
        let inserted = Buffer(content)
        let lastOffset = inserted.offset(max(0, inserted.characterCount - 1))
        return .edit(range: b.range(at, at), replacement: content, caret: b.offset(at) + lastOffset)
    }

    /// Immutable text chunks with relative grapheme/line indexes. The small
    /// prefix tables are recomputed after edits; character data is not rescanned.
    private struct Buffer {
        typealias Line = Fragment.Line
        private static let targetSize = 16_384
        private static let separators = CharacterSet(charactersIn: "\r\n")
        private var fragments: [Fragment]
        private var characterStarts: [Int] = []
        private var utf16Starts: [Int] = []
        private var lineStarts: [Int] = []
        private(set) var characterCount = 0
        private var utf16Count = 0
        private var lineCount = 0
        private(set) var lastReindexedUTF16Length = 0

        init(_ text: String) { self.init(text as NSString) }
        init(_ source: NSString) {
            fragments = Self.fragments(source, range: NSRange(location: 0, length: source.length))
            lastReindexedUTF16Length = source.length
            rebuildTotals()
        }

        private static func fragments(_ source: NSString, range: NSRange) -> [Fragment] {
            var result: [Fragment] = []
            var start = range.location
            let limit = NSMaxRange(range)
            while start < limit {
                var end = min(limit, start + targetSize)
                if end < limit {
                    // Chunks end at hard Unicode grapheme boundaries. Keep a
                    // whole logical line, including CRLF, in the same chunk.
                    let separator = source.rangeOfCharacter(from: separators, range: NSRange(location: end, length: limit - end))
                    end = separator.location == NSNotFound ? limit : NSMaxRange(separator)
                    if end < limit && source.character(at: end - 1) == 13 && source.character(at: end) == 10 { end += 1 }
                }
                result.append(Fragment(source.substring(with: NSRange(location: start, length: end - start))))
                start = end
            }
            return result.isEmpty ? [Fragment("")] : result
        }

        private mutating func rebuildTotals() {
            characterStarts.removeAll(keepingCapacity: true)
            utf16Starts.removeAll(keepingCapacity: true)
            lineStarts.removeAll(keepingCapacity: true)
            characterCount = 0
            utf16Count = 0
            lineCount = 0
            for (i, fragment) in fragments.enumerated() {
                characterStarts.append(characterCount)
                utf16Starts.append(utf16Count)
                lineStarts.append(lineCount)
                characterCount += fragment.characterCount
                utf16Count += fragment.utf16Count
                lineCount += fragment.lines.count - (i + 1 < fragments.count ? 1 : 0)
            }
        }

        mutating func update(_ source: NSString, editedRange: NSRange, delta: Int) {
            let oldEnd = NSMaxRange(editedRange) - delta
            guard editedRange.location >= 0, oldEnd >= editedRange.location, oldEnd <= utf16Count,
                  source.length == utf16Count + delta else {
                self = Buffer(source)
                return
            }
            let first = max(0, chunk(at: editedRange.location, starts: utf16Starts) - 1)
            let last = min(fragments.count - 1, chunk(at: oldEnd, starts: utf16Starts) + 1)
            let start = utf16Starts[first]
            let end = (last + 1 < fragments.count ? utf16Starts[last + 1] : utf16Count) + delta
            lastReindexedUTF16Length = end - start
            let replacement = Self.fragments(source, range: NSRange(location: start, length: end - start))
            fragments.replaceSubrange(first...last, with: replacement)
            rebuildTotals()
        }

        private func chunk(at position: Int, starts: [Int]) -> Int {
            max(0, starts.partitionIndex { $0 <= position } - 1)
        }
        func offset(_ position: Int) -> Int {
            let position = min(max(0, position), characterCount)
            let i = chunk(at: position, starts: characterStarts)
            return utf16Starts[i] + fragments[i].offset(position - characterStarts[i])
        }
        func index(at offset: Int) -> Int {
            let offset = min(max(0, offset), utf16Count)
            let i = chunk(at: offset, starts: utf16Starts)
            return characterStarts[i] + fragments[i].index(at: offset - utf16Starts[i])
        }
        func lineNumber(at position: Int) -> Int {
            let i = chunk(at: position, starts: characterStarts)
            return lineStarts[i] + fragments[i].lineNumber(at: position - characterStarts[i])
        }
        struct Lines: RandomAccessCollection {
            typealias Index = Int
            let fragments: [Fragment]
            let characterStarts: [Int]
            let lineStarts: [Int]
            let endIndex: Int
            var startIndex: Int { 0 }
            subscript(position: Int) -> Line {
                let i = Swift.max(0, lineStarts.partitionIndex { $0 <= position } - 1)
                let line = fragments[i].lines[position - lineStarts[i]]
                return Line(start: characterStarts[i] + line.start, end: characterStarts[i] + line.end)
            }
        }
        var lines: Lines { Lines(fragments: fragments, characterStarts: characterStarts, lineStarts: lineStarts, endIndex: lineCount) }
        func line(at position: Int) -> Line { lines[lineNumber(at: position)] }
        func normal(_ position: Int) -> Int {
            let position = min(max(0, position), characterCount)
            let line = line(at: position)
            return min(position, max(line.start, line.end - 1))
        }
        func firstNonblank(_ line: Int) -> Int {
            let i = chunk(at: line, starts: lineStarts)
            return characterStarts[i] + fragments[i].firstNonblank(line - lineStarts[i])
        }
        private func character(_ position: Int) -> Character {
            let i = chunk(at: position, starts: characterStarts)
            return fragments[i].character(position - characterStarts[i])
        }
        func isNewline(_ position: Int) -> Bool {
            guard position < characterCount else { return false }
            let character = character(position)
            return character == "\n" || character == "\r\n" || character == "\r"
        }
        func category(_ position: Int, big: Bool) -> Int {
            guard position < characterCount else { return 0 }
            let c = character(position)
            if c.isWhitespace { return 0 }
            return big || c.isLetter || c.isNumber || c == "_" ? 1 : 2
        }
        func range(_ lower: Int, _ upper: Int) -> NSRange { NSRange(location: offset(lower), length: offset(upper) - offset(lower)) }
        func substring(_ lower: Int, _ upper: Int) -> String {
            guard upper > lower else { return "" }
            let first = chunk(at: lower, starts: characterStarts)
            let last = chunk(at: upper - 1, starts: characterStarts)
            var result = ""
            for i in first...last {
                result += fragments[i].substring(max(0, lower - characterStarts[i]), min(fragments[i].characterCount, upper - characterStarts[i]))
            }
            return result
        }

        func wordMotion(_ motion: String, from start: Int, count: Int, big: Bool, operatorWord: Bool = false, initialWordEnd: Bool = false) -> Int {
            var cursorPosition = -1
            var currentChunk = chunk(at: start, starts: characterStarts)
            var text = fragments[currentChunk].text
            var cursor = text.startIndex
            func value(at position: Int) -> Character {
                let base = characterStarts[currentChunk]
                if position < base || position >= base + fragments[currentChunk].characterCount {
                    currentChunk = chunk(at: position, starts: characterStarts)
                    text = fragments[currentChunk].text
                    cursorPosition = -1
                }
                if cursorPosition >= 0 && position == cursorPosition + 1 {
                    text.formIndex(after: &cursor)
                } else if position == cursorPosition - 1 {
                    text.formIndex(before: &cursor)
                } else if position != cursorPosition {
                    cursor = fragments[currentChunk].stringIndex(position - characterStarts[currentChunk])
                }
                cursorPosition = position
                return text[cursor]
            }
            func kind(at position: Int) -> Int {
                guard position < characterCount else { return 0 }
                let character = value(at: position)
                if character.isWhitespace { return 0 }
                if big { return 1 }
                return character.isLetter || character.isNumber || character == "_" ? 1 : 2
            }
            func newline(at position: Int) -> Bool {
                guard position < characterCount else { return false }
                let character = value(at: position)
                return character == "\n" || character == "\r\n" || character == "\r"
            }
            var i = start
            for step in 0..<count {
                switch motion {
                case "w":
                    if i >= characterCount { return i }
                    let category = kind(at: i)
                    if category == 0 { i += 1 }
                    else { while i < characterCount && kind(at: i) == category { i += 1 } }
                    while i < characterCount && kind(at: i) == 0 {
                        if operatorWord && step == count - 1 && newline(at: i) { return i }
                        if newline(at: i) && line(at: i).start == i { break }
                        i += 1
                    }
                case "b":
                    if i == 0 { return 0 }
                    i -= 1
                    while i > 0 && kind(at: i) == 0 {
                        if newline(at: i) && line(at: i).start == i { break }
                        i -= 1
                    }
                    let category = kind(at: i)
                    if category != 0 { while i > 0 && kind(at: i - 1) == category { i -= 1 } }
                case "e":
                    if i >= characterCount { return i }
                    if i == characterCount - 1 { return newline(at: i) ? characterCount : i }
                    if !(initialWordEnd && step == 0) { i += 1 }
                    while i < characterCount && kind(at: i) == 0 { i += 1 }
                    if i == characterCount { return i }
                    let category = kind(at: i)
                    while i < characterCount - 1 && kind(at: i + 1) == category { i += 1 }
                default: break
                }
            }
            return i
        }
    }

    private struct Fragment {
        struct Line { let start: Int; let end: Int }
        let text: String
        // A checkpoint every 32 graphemes replaces the old Character + Int per
        // grapheme arrays. String slices share the snapshot; lookups scan at most
        // one small block, including on very long single-line documents.
        private static let stride = 32
        let characterCount: Int
        let utf16Count: Int
        let checkpoints: [(index: String.Index, offset: Int)]
        let lines: [Line]

        init(_ text: String) {
            var text = text
            text.makeContiguousUTF8()
            self.text = text
            var checkpoints: [(index: String.Index, offset: Int)] = []
            var lines: [Line] = []
            var start = 0
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
                    if value == 10 || value == 13 {
                        lines.append(Line(start: start, end: count))
                        start = count + 1
                    }
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
            lines.append(Line(start: start, end: count))
            self.characterCount = count
            self.utf16Count = offset
            self.checkpoints = checkpoints
            self.lines = lines
        }

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
        func lineNumber(at i: Int) -> Int { max(0, lines.partitionIndex { $0.start <= i } - 1) }
        func firstNonblank(_ index: Int) -> Int {
            let line = lines[index]
            var i = line.start
            var cursor = stringIndex(i)
            while i < line.end && (text[cursor] == " " || text[cursor] == "\t") {
                i += 1
                text.formIndex(after: &cursor)
            }
            return i == line.end ? line.start : i
        }
        func substring(_ lower: Int, _ upper: Int) -> String { String(text[stringIndex(lower)..<stringIndex(upper)]) }
    }
}
