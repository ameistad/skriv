import Foundation

extension String {
    /// String equality uses canonical equivalence, which cannot validate cached
    /// UTF-16 positions. Compare exact bytes, using contiguous storage when available.
    func isByteIdentical(to other: String) -> Bool {
        guard utf8.count == other.utf8.count else { return false }
        return utf8.withContiguousStorageIfAvailable { left in
            other.utf8.withContiguousStorageIfAvailable { right in
                left.isEmpty || memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0
            } ?? utf8.elementsEqual(other.utf8)
        } ?? utf8.elementsEqual(other.utf8)
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
    private var digits = ""
    private var operation: String?
    private var operationCount = 1
    private var operationHasCount = false
    private var awaitingG = false
    private var desiredColumn: Int?
    private var visualAnchor = 0
    private var visualCaret = 0
    // One disposable index per editor, shared by Normal and Visual motions.
    // The native text remains authoritative; byte equality protects UTF-16
    // offsets even when two strings are canonically equivalent.
    private var cachedBuffer: Buffer?

    mutating func invalidateTextCache() { cachedBuffer = nil }

    private mutating func buffer(for text: String) -> Buffer {
        if let cachedBuffer, cachedBuffer.text.isByteIdentical(to: text) { return cachedBuffer }
        let buffer = Buffer(text)
        cachedBuffer = buffer
        return buffer
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

    mutating func handle(_ input: String, text: String, caret: Int, visualMotion: Bool = false) -> VimEffect {
        if mode.isVisual { return handleVisual(input, text: text) }
        guard mode == .normal || input == "<Esc>" else { return .passThrough }
        let b = buffer(for: text)
        let position = b.index(at: caret)
        if input == "<Esc>" {
            let wasInsert = mode == .insert
            mode = .normal
            clearPending()
            desiredColumn = nil
            let line = b.line(at: position)
            return .move(b.offset(b.normal(wasInsert && position > line.start ? position - 1 : position)))
        }
        guard mode == .normal else { return .passThrough }
        let key = ["<Left>": "h", "<Right>": "l", "<Up>": "k", "<Down>": "j"][input] ?? input
        let i = visualMotion ? position : b.normal(position)
        if key.count == 1, let n = key.first?.wholeNumberValue, n < 10,
           n > 0 || !digits.isEmpty {
            digits = String(min(10_000, (Int(digits) ?? 0) * 10 + n))
            return .handled
        }
        let count = Int(digits) ?? 1
        let explicitCount = !digits.isEmpty
        digits = ""
        if awaitingG {
            awaitingG = false
            guard key == "g" else { clearPending(); return .handled }
            return executeMotion("gg", count: count, explicitCount: explicitCount, b: b, i: i, visual: visualMotion)
        }
        if key == "g" {
            awaitingG = true
            // Keep a leading count until the second g arrives.
            if explicitCount { digits = String(count) }
            return .handled
        }
        if let op = operation, key == op {
            let total = min(10_000, operationCount * count)
            clearPending()
            desiredColumn = nil
            if total > 1 && b.lineNumber(at: i) == b.lines.count - 1 { return .move(b.offset(i)) }
            let effect = lineOperation(op, b: b, first: b.lineNumber(at: i), last: b.lineNumber(at: i) + total - 1)
            return op == "y" ? .move(b.offset(i)) : effect
        }
        if ["h", "j", "k", "l", "0", "^", "$", "w", "b", "e", "W", "B", "E", "G"].contains(key) {
            return executeMotion(key, count: count, explicitCount: explicitCount, b: b, i: i, visual: visualMotion)
        }
        if operation != nil { clearPending(); return .handled }
        desiredColumn = nil
        switch key {
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

    private mutating func handleVisual(_ key: String, text: String) -> VimEffect {
        let b = buffer(for: text)
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
            let effect = characterOperation(op, b: b, lower: min(anchor, head), upper: min(b.characters.count, max(anchor, head) + 1))
            return op == "y" ? .move(b.offset(b.normal(min(anchor, head)))) : effect
        }
        let motionKeys = ["h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "^", "$", "g", "G",
                          "<Left>", "<Right>", "<Up>", "<Down>"]
        let digit = key.count == 1 && key.first?.wholeNumberValue != nil
        guard motionKeys.contains(key) || digit else {
            clearPending()
            return .handled
        }
        let visualMode = mode
        mode = .normal
        let effect = handle(key, text: text, caret: visualCaret, visualMotion: true)
        mode = visualMode
        if case .move(let next) = effect { visualCaret = next }
        return visualSelection(b)
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
            let end = last + 1 < b.lines.count ? b.lines[last + 1].start : b.characters.count
            range = b.range(first, end)
        } else {
            range = b.range(lower, min(b.characters.count, upper + 1))
        }
        return .select(range: range, caret: b.offset(head))
    }

    private mutating func clearPending() {
        digits = ""
        operation = nil
        operationCount = 1
        operationHasCount = false
        awaitingG = false
    }

    private mutating func capture(_ text: String, linewise: Bool) {
        register = Register(text: text, linewise: linewise)
        registerGeneration &+= 1
    }

    private mutating func executeMotion(_ key: String, count: Int, explicitCount: Bool, b: Buffer, i: Int, visual: Bool = false) -> VimEffect {
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
        if inclusive { upper = min(b.characters.count, upper + (upper < b.characters.count && !b.isNewline(upper) ? 1 : 0)) }
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
        let updated = (b.text as NSString).replacingCharacters(in: range, with: "")
        let after = Buffer(updated)
        let index = after.index(at: range.location)
        return .edit(range: range, replacement: "", caret: mode == .insert ? range.location : after.offset(after.normal(index)))
    }

    private mutating func lineOperation(_ op: String, b: Buffer, first: Int, last: Int) -> VimEffect {
        let first = min(max(0, first), b.lines.count - 1)
        let last = min(max(first, last), b.lines.count - 1)
        let start = b.lines[first].start
        let end = last + 1 < b.lines.count ? b.lines[last + 1].start : b.characters.count
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
        let lower = end == b.characters.count && last + 1 == b.lines.count && first > 0 ? start - 1 : start
        let range = b.range(lower, end)
        let updated = Buffer((b.text as NSString).replacingCharacters(in: range, with: ""))
        let nextLine = min(first, updated.lines.count - 1)
        return .edit(range: range, replacement: "", caret: updated.offset(updated.firstNonblank(nextLine)))
    }

    private func paste(b: Buffer, i: Int, after: Bool, count: Int) -> VimEffect {
        guard !register.text.isEmpty else { return .handled }
        let content = String(repeating: register.text, count: count)
        if register.linewise {
            let line = b.line(at: i)
            let inserted = Buffer(content)
            let firstNonblank = inserted.offset(inserted.firstNonblank(0))
            if after {
                if line.end < b.characters.count {
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
        let lastOffset = inserted.offset(max(0, inserted.characters.count - 1))
        return .edit(range: b.range(at, at), replacement: content, caret: b.offset(at) + lastOffset)
    }

    private struct Buffer {
        struct Line { let start: Int; let end: Int }
        let text: String
        let characters: [Character]
        let offsets: [Int]
        let lines: [Line]

        init(_ text: String) {
            self.text = text
            characters = Array(text)
            var offsets = [0]
            var lines: [Line] = []
            var start = 0
            for (i, character) in characters.enumerated() {
                offsets.append(offsets.last! + character.utf16.count)
                if character == "\n" || character == "\r\n" || character == "\r" {
                    lines.append(Line(start: start, end: i))
                    start = i + 1
                }
            }
            lines.append(Line(start: start, end: characters.count))
            self.offsets = offsets
            self.lines = lines
        }

        func offset(_ index: Int) -> Int { offsets[min(max(0, index), characters.count)] }
        func index(at offset: Int) -> Int {
            var lower = 0
            var upper = offsets.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if offsets[middle] <= offset { lower = middle + 1 } else { upper = middle }
            }
            return max(0, lower - 1)
        }
        func lineNumber(at i: Int) -> Int {
            var lower = 0
            var upper = lines.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if lines[middle].start <= i { lower = middle + 1 } else { upper = middle }
            }
            return max(0, lower - 1)
        }
        func line(at i: Int) -> Line { lines[lineNumber(at: i)] }
        func normal(_ i: Int) -> Int {
            let i = min(max(0, i), characters.count)
            let line = line(at: i)
            return min(i, max(line.start, line.end - 1))
        }
        func firstNonblank(_ index: Int) -> Int {
            let line = lines[index]
            var i = line.start
            while i < line.end && (characters[i] == " " || characters[i] == "\t") { i += 1 }
            return i == line.end ? line.start : i
        }
        func isNewline(_ i: Int) -> Bool {
            i < characters.count && (characters[i] == "\n" || characters[i] == "\r\n" || characters[i] == "\r")
        }
        func range(_ lower: Int, _ upper: Int) -> NSRange { NSRange(location: offset(lower), length: offset(upper) - offset(lower)) }
        func substring(_ lower: Int, _ upper: Int) -> String { String(characters[lower..<upper]) }
        func category(_ i: Int, big: Bool) -> Int {
            guard i < characters.count else { return 0 }
            let c = characters[i]
            if c.isWhitespace { return 0 }
            if big { return 1 }
            return c.isLetter || c.isNumber || c == "_" ? 1 : 2
        }
        func wordMotion(_ motion: String, from start: Int, count: Int, big: Bool, operatorWord: Bool = false, initialWordEnd: Bool = false) -> Int {
            var i = start
            for step in 0..<count {
                switch motion {
                case "w":
                    if i >= characters.count { return i }
                    let kind = category(i, big: big)
                    if kind == 0 { i += 1 }
                    else { while i < characters.count && category(i, big: big) == kind { i += 1 } }
                    while i < characters.count && category(i, big: big) == 0 {
                        if operatorWord && step == count - 1 && isNewline(i) { return i }
                        if isNewline(i) && line(at: i).start == i { break }
                        i += 1
                    }
                case "b":
                    if i == 0 { return 0 }
                    i -= 1
                    while i > 0 && category(i, big: big) == 0 {
                        if isNewline(i) && line(at: i).start == i { break }
                        i -= 1
                    }
                    let kind = category(i, big: big)
                    if kind != 0 { while i > 0 && category(i - 1, big: big) == kind { i -= 1 } }
                case "e":
                    if i >= characters.count { return i }
                    if i == characters.count - 1 { return isNewline(i) ? characters.count : i }
                    if !(initialWordEnd && step == 0) { i += 1 }
                    while i < characters.count && category(i, big: big) == 0 { i += 1 }
                    if i == characters.count { return i }
                    let kind = category(i, big: big)
                    while i < characters.count - 1 && category(i + 1, big: big) == kind { i += 1 }
                default: break
                }
            }
            return i
        }
    }
}
