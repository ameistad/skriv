import Foundation

/// Per-note transient search history. Matches must start and end on whole graphemes.
struct LiteralSearch {
    struct Match: Equatable {
        let range: NSRange
        let wrapped: Bool
    }
    private(set) var query = ""
    private(set) var forward = true
    private var indexedText: String?
    private var indexedQuery = ""
    private var matches: [NSRange] = []

    mutating func invalidateMatches() {
        indexedText = nil
        matches = []
    }

    mutating func submit(_ query: String, forward: Bool, text: String, caret: Int, count: Int = 1) -> Match? {
        if !query.isEmpty { self.query = query }
        self.forward = forward
        return find(text: text, caret: caret, forward: forward, count: count)
    }

    mutating func repeatMatch(reverse: Bool, text: String, caret: Int, count: Int = 1) -> Match? {
        find(text: text, caret: caret, forward: reverse ? !forward : forward, count: count)
    }

    private mutating func indexMatches(in text: String) {
        if let indexedText, indexedQuery.isByteIdentical(to: query),
           indexedText.isByteIdentical(to: text) { return }
        let source = text as NSString
        matches.removeAll(keepingCapacity: true)
        var offset = 0
        while offset < source.length {
            let range = source.range(of: query, options: [], range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if source.rangeOfComposedCharacterSequences(for: range) == range { matches.append(range) }
            offset = NSMaxRange(source.rangeOfComposedCharacterSequence(at: range.location))
        }
        indexedText = text
        indexedQuery = query
    }

    private mutating func find(text: String, caret: Int, forward: Bool, count: Int) -> Match? {
        guard !query.isEmpty else { return nil }
        indexMatches(in: text)
        guard !matches.isEmpty else { return nil }
        let steps = max(1, count) - 1
        // Find the first start greater than the caret (forward), or greater
        // than/equal to it (backward). Repeats no longer rescan the match list.
        let low = matches.partitionIndex { forward ? $0.location <= caret : $0.location < caret }
        if forward {
            let index = (low % matches.count + steps % matches.count) % matches.count
            return Match(range: matches[index], wrapped: steps >= matches.count - low)
        }
        let first = low - 1
        let index = ((first - steps % matches.count) % matches.count + matches.count) % matches.count
        return Match(range: matches[index], wrapped: steps > first)
    }
}
