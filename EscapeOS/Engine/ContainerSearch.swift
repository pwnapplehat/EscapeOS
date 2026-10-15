import Foundation

/// One match from a whole-app search.
struct SearchHit: Identifiable, Hashable {
    let id = UUID()
    let item: FileItem
    /// Path below the folder that was searched, for example `Library/Caches/thumb.db`.
    let relativePath: String
}

struct SearchOutcome {
    var hits: [SearchHit] = []
    /// True when the search stopped at a limit, so there may be more matches than shown.
    var truncated = false
    /// Items looked at.
    var scanned = 0
    var cancelled = false
}

/// Finds files and folders by name anywhere under an app's container.
///
/// Issue #3: the search box only filtered the folder you were looking at, so a file buried in a
/// subfolder never appeared from the top. This walks the whole tree, shallowest first, so the
/// closest matches come first and the search can stop early. It follows no symlinks (a link is a
/// file here), so it cannot loop or leave the container, and it gives up cleanly at a size limit
/// instead of running for minutes on a huge container.
enum ContainerSearch {
    static let maxResults = 500
    static let maxNodes = 150_000

    /// Words to look for. Every word must appear in a name for it to match.
    static func terms(from query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    static func matches(name: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func search(
        root: String,
        query: String,
        files: FileService,
        maxResults: Int = ContainerSearch.maxResults,
        maxNodes: Int = ContainerSearch.maxNodes,
        progress: ((Int) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> SearchOutcome {
        var outcome = SearchOutcome()
        let words = terms(from: query)
        guard !words.isEmpty else { return outcome }

        // Breadth first, so shallow matches come before deep ones.
        var queue: [(path: String, relative: String)] = [(root, "")]
        var head = 0
        while head < queue.count {
            if isCancelled() {
                outcome.cancelled = true
                return outcome
            }
            let (folder, relative) = queue[head]
            head += 1
            guard let entries = try? files.list(directory: folder) else { continue }
            for entry in entries {
                outcome.scanned += 1
                if outcome.scanned % 500 == 0 { progress?(outcome.scanned) }
                let entryRelative = relative.isEmpty ? entry.name : relative + "/" + entry.name
                if matches(name: entry.name, terms: words) {
                    outcome.hits.append(SearchHit(item: entry, relativePath: entryRelative))
                    if outcome.hits.count >= maxResults {
                        outcome.truncated = true
                        return outcome
                    }
                }
                if entry.isDirectory {
                    queue.append((entry.path, entryRelative))
                }
                if outcome.scanned >= maxNodes {
                    outcome.truncated = true
                    return outcome
                }
            }
        }
        progress?(outcome.scanned)
        return outcome
    }
}
