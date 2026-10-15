import Foundation

func runContainerSearchTests() {
    T.section("ContainerSearch")
    let fm = FileManager.default
    let files = FileService()

    // ---- matching ------------------------------------------------------------------------
    T.equal(ContainerSearch.terms(from: "  report   2024 "), ["report", "2024"], "terms split on whitespace")
    T.equal(ContainerSearch.terms(from: "   "), [], "blank query has no terms")
    T.check(ContainerSearch.matches(name: "Quarterly Report.PDF", terms: ["report"]), "match ignores case")
    T.check(ContainerSearch.matches(name: "Café menu.txt", terms: ["cafe"]), "match ignores accents")
    T.check(ContainerSearch.matches(name: "budget report 2024.xlsx", terms: ["report", "2024"]), "every word must appear")
    T.check(!ContainerSearch.matches(name: "budget report.xlsx", terms: ["report", "2024"]), "a missing word means no match")
    T.check(!ContainerSearch.matches(name: "anything", terms: []), "no terms never matches")
    T.check(ContainerSearch.matches(name: "photo.final.jpg", terms: [".final"]), "dots are literal, not wildcards")
    T.check(!ContainerSearch.matches(name: "photoXfinal.jpg", terms: [".final"]), "a dot does not match any character")

    // ---- a real tree -----------------------------------------------------------------------
    let root = fm.temporaryDirectory.appendingPathComponent("escapeos-search-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    func put(_ rel: String) {
        let url = root.appendingPathComponent(rel)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data("x".utf8))
    }
    put("Documents/invoice.pdf")
    put("Documents/Taxes/invoice-2023.pdf")
    put("Library/Caches/Deep/er/est/invoice-old.pdf")
    put("Library/Preferences/settings.plist")
    put("tmp/notes.txt")
    try? fm.createDirectory(at: root.appendingPathComponent("Documents/invoice folder"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: root.appendingPathComponent("loop").path, withDestinationPath: root.path)

    let found = ContainerSearch.search(root: root.path, query: "invoice", files: files)
    let rels = found.hits.map(\.relativePath)
    T.equal(rels.count, 4, "finds files and folders at every depth")
    T.check(rels.contains("Documents/invoice.pdf"), "finds a file near the top")
    T.check(rels.contains("Documents/Taxes/invoice-2023.pdf"), "finds a file one folder down")
    T.check(rels.contains("Library/Caches/Deep/er/est/invoice-old.pdf"), "finds a file buried deep")
    T.check(rels.contains("Documents/invoice folder"), "finds a folder by name")
    T.check(found.hits.first { $0.relativePath == "Documents/invoice folder" }?.item.isDirectory == true, "a folder hit is marked as a folder")
    T.check(!found.truncated && !found.cancelled, "a small search completes")
    T.check(found.scanned >= 10, "it looked at the tree")

    // shallowest first
    let depths = rels.map { $0.split(separator: "/").count }
    T.check(depths == depths.sorted(), "results are ordered shallowest first")

    // the symlink is a leaf: it neither loops nor is followed
    let viaLink = ContainerSearch.search(root: root.path, query: "loop", files: files)
    T.equal(viaLink.hits.map(\.relativePath), ["loop"], "a symlink matches as itself")
    T.check(!viaLink.truncated, "and does not cause an endless walk")

    T.equal(ContainerSearch.search(root: root.path, query: "   ", files: files).hits.count, 0, "a blank query finds nothing")
    T.equal(ContainerSearch.search(root: root.path, query: "zzz-nothing", files: files).hits.count, 0, "no match is an empty result")
    T.equal(ContainerSearch.search(root: root.appendingPathComponent("missing").path, query: "x", files: files).hits.count, 0, "a missing root is an empty result")

    // limits
    let limited = ContainerSearch.search(root: root.path, query: "invoice", files: files, maxResults: 2)
    T.equal(limited.hits.count, 2, "stops at the result limit")
    T.check(limited.truncated, "and says there may be more")

    let nodeLimited = ContainerSearch.search(root: root.path, query: "invoice", files: files, maxNodes: 3)
    T.check(nodeLimited.truncated, "stops at the scan limit")
    T.check(nodeLimited.scanned <= 3, "without scanning past it")

    // cancellation
    var calls = 0
    let cancelled = ContainerSearch.search(root: root.path, query: "invoice", files: files, isCancelled: {
        calls += 1
        return calls > 2
    })
    T.check(cancelled.cancelled, "a cancelled search says so")
    T.check(cancelled.hits.count < 4, "and stops early")

    // progress is reported
    var reported = 0
    _ = ContainerSearch.search(root: root.path, query: "invoice", files: files, progress: { reported = max(reported, $0) })
    T.check(reported > 0, "progress reports the final count")
}
