import Foundation

/// Search terms can match different metadata fields; normalization supports
/// accented and full-width titles without changing the user's stored names.
enum LibraryQuery {
    static func matches(_ values: [String], query: String) -> Bool {
        let normalize: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let terms = normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let normalized = values.map(normalize)
        return terms.allSatisfy { term in normalized.contains { $0.contains(term) } }
    }

    static func games(_ values: [LibraryGame], query: String) -> [LibraryGame] {
        values.filter { matches([$0.displayTitle, $0.sourcePath, $0.externalPath ?? "", $0.directory], query: query) }
            .sorted {
                let left = $0.lastPlayedAt ?? .distantPast, right = $1.lastPlayedAt ?? .distantPast
                if left != right { return left > right }
                let order = $0.displayTitle.localizedStandardCompare($1.displayTitle)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }
}
