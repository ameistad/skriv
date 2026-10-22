import Foundation

/// Per-document transient search history. Matches must start and end on whole graphemes.
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
    private var source: NSString?
    private var streamsMatches = false
    // Retain at most 64 KiB of match ranges, even for a document full of matches.
    static let matchLimit = 4096
    var cachedMatchCount: Int { matches.count }

    mutating func invalidateMatches() {
        indexedText = nil
        source = nil
        streamsMatches = false
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
        streamsMatches = false
        matches.removeAll(keepingCapacity: true)
        var offset = 0
        while offset < source.length {
            let range = source.range(of: query, options: [], range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if source.rangeOfComposedCharacterSequences(for: range) == range {
                if matches.count == Self.matchLimit {
                    streamsMatches = true
                    matches = []
                    break
                }
                matches.append(range)
            }
            offset = NSMaxRange(source.rangeOfComposedCharacterSequence(at: range.location))
        }
        self.source = streamsMatches ? source : nil
        indexedText = text
        indexedQuery = query
    }

    private mutating func find(text: String, caret: Int, forward: Bool, count: Int) -> Match? {
        guard !query.isEmpty else { return nil }
        indexMatches(in: text)
        if streamsMatches, let source { return streamingMatch(in: source, caret: caret, forward: forward, count: count) }
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

    /// Search only as far as the requested match. Backward ranges include enough
    /// whole graphemes beyond the caret to preserve overlapping/canonical matches.
    private func nextMatch(in source: NSString, caret: Int, forward: Bool) -> NSRange? {
        let length = source.length
        if forward {
            var start = caret < 0 ? 0 : (caret < length ? NSMaxRange(source.rangeOfComposedCharacterSequence(at: caret)) : length)
            while start < length {
                let range = source.range(of: query, range: NSRange(location: start, length: length - start))
                guard range.location != NSNotFound, range.length > 0 else { return nil }
                if source.rangeOfComposedCharacterSequences(for: range) == range { return range }
                start = NSMaxRange(source.rangeOfComposedCharacterSequence(at: range.location))
            }
        } else {
            guard caret > 0 else { return nil }
            var end = min(caret, length)
            for _ in query.utf16 {
                if end == length { break }
                end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: end))
            }
            while end > 0 {
                let range = source.range(of: query, options: .backwards, range: NSRange(location: 0, length: end))
                guard range.location != NSNotFound, range.length > 0 else { return nil }
                if range.location < caret && source.rangeOfComposedCharacterSequences(for: range) == range { return range }
                end = source.rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1).location
            }
        }
        return nil
    }

    private func streamingMatch(in source: NSString, caret: Int, forward: Bool, count: Int) -> Match? {
        var remaining = max(1, count)
        var position = caret
        var wrapped = false
        var first: NSRange?
        var visited = 0
        var lastLength = 0
        while remaining > 0 {
            var next = nextMatch(in: source, caret: position, forward: forward)
            if next == nil {
                wrapped = true
                next = nextMatch(in: source, caret: forward ? -1 : source.length + 1, forward: forward)
            }
            guard let next else { return nil }
            if first == next {
                // Huge counts need at most one cycle plus its remainder.
                remaining %= visited
                if remaining == 0 { return Match(range: NSRange(location: position, length: lastLength), wrapped: wrapped) }
            } else if first == nil { first = next }
            visited += 1
            remaining -= 1
            position = next.location
            lastLength = next.length
            if remaining == 0 { return Match(range: next, wrapped: wrapped) }
        }
        return nil
    }
}
