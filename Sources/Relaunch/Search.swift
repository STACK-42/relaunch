import Foundation

/// Ranks apps for the search field. Beyond Launchpad's prefix match it also
/// accepts word prefixes ("settings"), initials ("vsc") and subsequences, and
/// ignores case and diacritics.
enum Search {
    static func rank(_ query: String, in apps: [AppInfo]) -> [AppInfo] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        var scored: [(app: AppInfo, score: Int)] = []
        for a in apps {
            if let s = score(q, fold(a.name)) { scored.append((a, s)) }
        }
        scored.sort { l, r in
            if l.score != r.score { return l.score > r.score }
            return l.app.name.localizedStandardCompare(r.app.name) == .orderedAscending
        }
        return scored.map(\.app)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func score(_ q: String, _ name: String) -> Int? {
        if name.hasPrefix(q) { return 1000 - name.count }
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(q) }) { return 800 - name.count }
        if name.contains(q) { return 600 - name.count }
        if String(words.compactMap(\.first)).hasPrefix(q) { return 500 - name.count }

        // Loose subsequence matches only once the query is specific enough.
        guard q.count >= 3 else { return nil }
        var it = name.makeIterator()
        for ch in q {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return nil }
        }
        return 200 - name.count
    }
}
