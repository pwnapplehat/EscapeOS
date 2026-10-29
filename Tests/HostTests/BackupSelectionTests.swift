import Foundation

private func entry(_ path: String, _ size: Int = 10) -> BackupManifestEntry {
    BackupManifestEntry(path: path, size: size, sha256: "00")
}

private func fileItem(_ path: String, name: String? = nil, directory: Bool = false) -> FileItem {
    FileItem(
        name: name ?? (path as NSString).lastPathComponent, path: path,
        kind: directory ? .directory : .regular, size: 0, modified: nil, isReadable: true, isWritable: true
    )
}

private func metadata(files: Int, bytes: Int64, partial: Bool? = nil, scope: [String]? = nil) -> BackupMetadata {
    BackupMetadata(
        bundleIdentifier: "com.example", appName: "Example", containerPath: "/c", createdAt: "2026-10-29T10:00:00Z",
        fileCount: files, totalBytes: bytes, manifestSHA256: "ab", escapeOSVersion: "0.2.0", isPartial: partial, scope: scope
    )
}

func runBackupSelectionTests() {
    T.section("BackupSelection")

    // which paths are valid
    T.equal(BackupSelection.normalize("Documents/a.txt"), "Documents/a.txt", "an ordinary path is kept")
    T.equal(BackupSelection.normalize("Documents/notes/"), "Documents/notes", "a trailing slash is dropped")
    T.equal(BackupSelection.normalize("Library//Preferences/x.plist"), "Library/Preferences/x.plist", "doubled slashes collapse")
    T.equal(BackupSelection.normalize("tmp"), "tmp", "a whole root can be chosen")
    for bad in ["", "/Documents/a", "Documents/../Library/x", "Documents/./x", "..", "Other/x", "SystemData/x", "StoreKit/receipt", ".com.apple.mobile_container_manager.metadata.plist", "documents/a"] {
        T.check(BackupSelection.normalize(bad) == nil, "'\(bad)' is not a place a backup covers")
    }

    // building a selection
    T.check(BackupSelection(paths: []) == nil, "an empty selection is not a selection")
    T.check(BackupSelection(paths: ["Documents/a", "../x"]) == nil, "one bad path spoils the selection rather than being quietly dropped")
    T.equal(BackupSelection(paths: ["Documents/b", "Documents/a", "Documents/a"])?.paths ?? [], ["Documents/a", "Documents/b"], "duplicates go and the order is stable")
    T.equal(BackupSelection(paths: ["Documents/a/b/c.txt", "Documents/a", "Documents/a/x"])?.paths ?? [], ["Documents/a"], "items inside a chosen folder are redundant")
    T.equal(BackupSelection(paths: ["Documents/ab", "Documents/a"])?.paths ?? [], ["Documents/a", "Documents/ab"], "a sibling whose name merely starts the same is not 'inside'")
    T.equal(BackupSelection(paths: ["Documents", "Documents/a", "Library/x"])?.paths ?? [], ["Documents", "Library/x"], "a whole root covers what is in it")
    T.equal(BackupSelection(paths: ["Documents/a/", "Documents/a"])?.paths ?? [], ["Documents/a"], "the same path spelled two ways counts once")

    // what a selection covers
    do {
        let selection = BackupSelection(paths: ["Documents/notes", "Library/Preferences/app.plist"])!
        T.check(selection.covers("Documents/notes"), "a chosen folder covers itself")
        T.check(selection.covers("Documents/notes/a.txt"), "and a file in it")
        T.check(selection.covers("Documents/notes/deep/er/b.txt"), "and a file deep in it")
        T.check(selection.covers("Library/Preferences/app.plist"), "a chosen file covers itself")
        T.check(!selection.covers("Library/Preferences/other.plist"), "but not its neighbour")
        T.check(!selection.covers("Documents/notes2/a.txt"), "a folder whose name starts the same is not covered")
        T.check(!selection.covers("Documents/note"), "a shorter name is not covered")
        T.check(!selection.covers("Documents"), "a parent of a chosen folder is not covered")
        T.check(!selection.covers("tmp/a"), "another root is not covered")
        let manifest = ["Documents/notes/a.txt", "Documents/other.txt", "Library/Preferences/app.plist", "Documents/notes/sub/c.txt"].map { entry($0) }
        T.equal(selection.filter(manifest).map(\.path), ["Documents/notes/a.txt", "Library/Preferences/app.plist", "Documents/notes/sub/c.txt"], "filtering keeps the covered entries in manifest order")
        T.equal(selection.filter([]).count, 0, "filtering nothing gives nothing")
    }

    // a big selection against a big manifest stays quick
    do {
        let paths = (0..<5_000).map { "Documents/folder\($0 % 50)/sub\($0 % 7)/file\($0).bin" }
        let selection = BackupSelection(paths: paths)!
        let manifest = paths.map { entry($0) } + (0..<5_000).map { entry("Library/other/file\($0).bin") }
        let started = Date()
        let kept = selection.filter(manifest)
        let elapsed = Date().timeIntervalSince(started)
        T.equal(kept.count, 5_000, "all the chosen files are found among 10,000")
        T.check(elapsed < 2, "filtering 10,000 entries against 5,000 choices took \(String(format: "%.2f", elapsed)) s")
    }

    // from the browser's selection
    do {
        let container = "/private/var/mobile/Containers/Data/Application/AAAA"
        let ok = try? BackupSelection.from(items: [
            fileItem(container + "/Documents/notes", directory: true),
            fileItem(container + "/Library/Preferences/a.plist"),
        ], containerPath: container)
        T.equal(ok?.paths ?? [], ["Documents/notes", "Library/Preferences/a.plist"], "browser items become container-relative paths")
        let alias = try? BackupSelection.from(items: [fileItem("/var/mobile/Containers/Data/Application/AAAA/Documents/x")], containerPath: container)
        T.equal(alias?.paths ?? [], ["Documents/x"], "/var and /private/var spellings agree")

        func failure(_ items: [FileItem]) -> BackupSelectionError? {
            do { _ = try BackupSelection.from(items: items, containerPath: container); return nil }
            catch let e as BackupSelectionError { return e } catch { return nil }
        }
        T.equal(failure([]), .empty, "nothing chosen is an error")
        T.equal(failure([fileItem("/elsewhere/file.txt")]), .outside("file.txt"), "an item outside the container is refused")
        T.equal(failure([fileItem(container, name: "AAAA", directory: true)]), .outside("AAAA"), "the container itself is refused")
        T.equal(failure([fileItem(container + "/SystemData/x.db")]), .unsupportedLocation("x.db"), "an item outside the three roots is refused")
        T.equal(failure([fileItem(container + "/.com.apple.mobile_container_manager.metadata.plist")]), .unsupportedLocation(".com.apple.mobile_container_manager.metadata.plist"), "the container's own metadata file is refused")
        T.equal(failure([fileItem(container + "/Documents/ok"), fileItem("/elsewhere/bad")]), .outside("bad"), "one bad item refuses the lot")
        T.check((failure([fileItem("/elsewhere/file.txt")])?.errorDescription ?? "").contains("not inside this app's data"), "the message says why")
        T.check((failure([fileItem(container + "/SystemData/x.db")])?.errorDescription ?? "").contains("Documents, Library and tmp"), "and what is allowed")
    }

    // metadata: old archives still read, new fields round-trip
    do {
        let oldJSON = """
        {"bundleIdentifier":"com.example","appName":"Example","containerPath":"/c","createdAt":"2026-01-01T00:00:00Z","fileCount":3,"totalBytes":300,"manifestSHA256":"ab","escapeOSVersion":"0.1.8"}
        """
        let old = try? JSONDecoder().decode(BackupMetadata.self, from: Data(oldJSON.utf8))
        T.check(old != nil, "a backup made before selective backup still decodes")
        T.check(old?.isPartialBackup == false, "and counts as a full backup")
        T.check(old?.scope == nil, "with no scope")
        let partial = metadata(files: 2, bytes: 20, partial: true, scope: ["Documents/notes"])
        let data = try? JSONEncoder().encode(partial)
        let back = data.flatMap { try? JSONDecoder().decode(BackupMetadata.self, from: $0) }
        T.equal(back, partial, "a partial backup's metadata round-trips")
        T.check(back?.isPartialBackup == true, "and reads as partial")
        let newer = """
        {"bundleIdentifier":"b","appName":"A","containerPath":"/c","createdAt":"x","fileCount":1,"totalBytes":1,"manifestSHA256":"a","escapeOSVersion":"9","isPartial":true,"scope":["Documents/a"],"someFutureField":42}
        """
        T.check((try? JSONDecoder().decode(BackupMetadata.self, from: Data(newer.utf8))) != nil, "a field this version does not know is ignored")
        let full = metadata(files: 3, bytes: 30)
        let fullJSON = String(decoding: (try? JSONEncoder().encode(full)) ?? Data(), as: UTF8.self)
        T.check(!fullJSON.contains("\"isPartial\":true"), "a full backup does not claim to be partial")
    }

    // wording
    do {
        T.check(BackupDescription.subtitle(for: metadata(files: 12, bytes: 3_000_000)).hasPrefix("12 files · "), "a full backup: file count then size")
        T.check(BackupDescription.subtitle(for: metadata(files: 1, bytes: 10)).hasPrefix("1 file · "), "one file is not '1 files'")
        let partial = BackupDescription.subtitle(for: metadata(files: 14, bytes: 3_200_000, partial: true, scope: ["Documents/a", "Documents/b"]))
        T.check(partial.hasPrefix("Partial · 2 items · 14 files · "), "a partial backup says so and how many items")
        T.check(BackupDescription.subtitle(for: metadata(files: 1, bytes: 1, partial: true, scope: ["Documents/a"])).hasPrefix("Partial · 1 item · 1 file · "), "singular for one item")
        T.check(BackupDescription.subtitle(for: metadata(files: 2, bytes: 1, partial: true, scope: nil)).hasPrefix("Partial · 2 files · "), "a partial backup without a recorded scope still says partial")
        T.check(BackupDescription.scopeSummary(for: metadata(files: 1, bytes: 1)) == nil, "a full backup has no scope line")
        func summary(_ names: [String]) -> String? {
            BackupDescription.scopeSummary(for: metadata(files: 1, bytes: 1, partial: true, scope: names.map { "Documents/\($0)" }))
        }
        T.equal(summary(["notes"]) ?? "", "notes", "one item by name")
        T.equal(summary(["notes", "a.plist"]) ?? "", "notes and a.plist", "two items")
        T.equal(summary(["a", "b", "c"]) ?? "", "a, b and c", "three items")
        T.equal(summary(["a", "b", "c", "d", "e"]) ?? "", "a, b, c and 2 more", "five items")
        T.check(BackupDescription.scopeSummary(for: metadata(files: 1, bytes: 1, partial: true, scope: [])) == nil, "an empty scope has no line")
    }

    // the tree of a manifest
    do {
        let manifest = [
            entry("Library/Preferences/app.plist", 100),
            entry("Documents/notes/b.txt", 20),
            entry("Documents/notes/a.txt", 10),
            entry("Documents/zeta.txt", 5),
            entry("Documents/Alpha/inner/deep.bin", 7),
            entry("tmp/cache.dat", 1),
        ]
        let tree = ManifestTree(manifest: manifest)
        T.equal(tree.roots.map(\.name), ["Documents", "Library", "tmp"], "the three roots, in order")
        let documents = tree.roots[0]
        T.equal(documents.children?.map(\.name) ?? [], ["Alpha", "notes", "zeta.txt"], "folders first, then files, each by name")
        T.equal(documents.bytes, 42, "a folder's size is everything under it")
        T.equal(documents.fileCount, 4, "and its file count")
        T.check(documents.isDirectory && documents.children != nil, "a folder has children")
        let notes = documents.children?[1]
        T.equal(notes?.children?.map(\.name) ?? [], ["a.txt", "b.txt"], "files in a folder are sorted")
        T.equal(notes?.id ?? "", "Documents/notes", "a node's id is its full path")
        let zeta = documents.children?[2]
        T.check(zeta?.children == nil && zeta?.isDirectory == false, "a file has no children")
        T.equal(zeta?.bytes ?? -1, 5, "a file's size is its own")
        T.equal(tree.filePaths.count, 6, "every file is listed once")
        T.equal(Set(tree.filePaths), Set(manifest.map(\.path)), "and they are the manifest's")
        // each folder's range covers exactly its own files
        func rangesAreExact(_ node: ManifestNode) -> Bool {
            let inRange = Set(tree.filePaths[node.fileRange])
            let expected = Set(tree.filePaths.filter { $0 == node.id || $0.hasPrefix(node.id + "/") })
            if inRange != expected { return false }
            return (node.children ?? []).allSatisfy(rangesAreExact)
        }
        T.check(tree.roots.allSatisfy(rangesAreExact), "every folder's range holds exactly the files under it")
        T.equal(ManifestTree(manifest: []).roots.count, 0, "an empty manifest is an empty tree")
        T.equal(ManifestTree(manifest: [entry("Documents/café/ü.txt", 3)]).roots.first?.children?.first?.name ?? "", "café", "accented names survive")
        T.equal(ManifestTree(manifest: [entry("a.txt", 3)]).roots.map(\.name), ["a.txt"], "a file at the very top is allowed")
    }

    // ticking things in the picker
    do {
        let manifest = [
            entry("Documents/notes/a.txt", 10), entry("Documents/notes/b.txt", 20),
            entry("Documents/c.txt", 5), entry("Library/p.plist", 100),
        ]
        let tree = ManifestTree(manifest: manifest)
        var selection = ManifestSelection(tree: tree)
        let documents = tree.roots[0]
        let notes = documents.children![0]
        let c = documents.children![1]
        T.check(selection.isEmpty, "nothing is ticked at first")
        T.check(selection.backupSelection == nil, "so there is nothing to restore")
        T.equal(selection.state(of: documents), .none, "a folder with nothing ticked reads none")

        selection.toggle(notes.children![0])
        T.equal(selection.state(of: notes), .some, "ticking one file of two makes its folder 'some'")
        T.equal(selection.state(of: documents), .some, "and its parent too")
        T.equal(selection.state(of: tree.roots[1]), .none, "other folders are unaffected")
        T.equal(selection.selectedFileCount, 1, "one file is ticked")
        T.equal(selection.selectedBytes, 10, "with its size")

        selection.toggle(notes)
        T.equal(selection.state(of: notes), .all, "ticking a half-ticked folder ticks all of it")
        T.equal(selection.selectedBytes, 30, "both files count")
        selection.toggle(notes)
        T.equal(selection.state(of: notes), .none, "ticking a fully ticked folder unticks it")
        T.check(selection.isEmpty, "and nothing is left")

        selection.toggle(documents)
        T.equal(selection.state(of: documents), .all, "ticking a root ticks everything under it")
        T.equal(selection.state(of: c), .all, "including files directly in it")
        T.equal(selection.selectedFileCount, 3, "three files")
        selection.toggle(c)
        T.equal(selection.state(of: documents), .some, "unticking one file leaves the root 'some'")
        T.equal(selection.backupSelection?.paths ?? [], ["Documents/notes/a.txt", "Documents/notes/b.txt"], "the restore selection is exactly the ticked files")

        selection.selectAll()
        T.check(selection.isEverything, "select all ticks everything")
        T.equal(selection.selectedFileCount, 4, "all four files")
        T.equal(selection.selectedBytes, 135, "and all the bytes")
        selection.clear()
        T.check(selection.isEmpty && !selection.isEverything, "clear unticks everything")
        T.check(!ManifestSelection(tree: ManifestTree(manifest: [])).isEverything, "an empty backup is never 'everything'")
        let all = ManifestSelection(tree: tree, selectAll: true)
        T.check(all.isEverything, "a picker can start with everything ticked")
        let applied = all.backupSelection!.filter(manifest)
        T.equal(applied.count, 4, "and that selection restores every file")
    }
}
