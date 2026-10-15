import Foundation

private let fm = FileManager.default

private func makeRoot() -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent("escapeos-paste-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ root: URL, _ rel: String, _ text: String) {
    let url = root.appendingPathComponent(rel)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

private func read(_ root: URL, _ rel: String) -> String? {
    try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

private func names(_ root: URL, _ rel: String = "") -> [String] {
    let dir = rel.isEmpty ? root : root.appendingPathComponent(rel)
    return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

private func item(_ root: URL, _ rel: String, folder: Bool = false) -> FileItem {
    FileItem(
        name: (rel as NSString).lastPathComponent, path: root.appendingPathComponent(rel).path,
        kind: folder ? .directory : .regular, size: 1, modified: nil, isReadable: true, isWritable: true
    )
}

func runPasteConflictsTests() {
    T.section("PasteConflicts")
    let files = FileService()

    // ---- planner -------------------------------------------------------------------------
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/a.txt", "A")
        write(root, "src/b.txt", "B")
        write(root, "src/dir/inner.txt", "I")
        write(root, "dest/a.txt", "old A")
        try? fm.createDirectory(at: root.appendingPathComponent("dest/dir"), withIntermediateDirectories: true)
        write(root, "dest/dir2", "a FILE named dir2")
        try? fm.createDirectory(at: root.appendingPathComponent("src/dir2"), withIntermediateDirectories: true)
        let dest = root.appendingPathComponent("dest").path

        let none = PasteConflictPlanner.plan(items: [item(root, "src/b.txt")], into: dest, moving: false, files: files)
        T.check(!none.hasConflicts, "a name that is free is not a conflict")

        let file = PasteConflictPlanner.plan(items: [item(root, "src/a.txt"), item(root, "src/b.txt")], into: dest, moving: false, files: files)
        T.equal(file.replaceableFiles, ["a.txt"], "a file over a file is replaceable")
        T.check(file.keepBothOnly.isEmpty, "nothing is keep-both-only there")

        let folder = PasteConflictPlanner.plan(items: [item(root, "src/dir", folder: true)], into: dest, moving: false, files: files)
        T.equal(folder.keepBothOnly, ["dir"], "a folder onto a folder is keep-both-only")
        T.check(!folder.canReplace, "so Replace is not offered")

        let folderOnFile = PasteConflictPlanner.plan(items: [item(root, "src/dir2", folder: true)], into: dest, moving: false, files: files)
        T.equal(folderOnFile.keepBothOnly, ["dir2"], "a folder onto a file is keep-both-only")

        let itself = PasteConflictPlanner.plan(items: [item(root, "dest/a.txt")], into: dest, moving: false, files: files)
        T.equal(itself.keepBothOnly, ["a.txt"], "copying a file into its own folder is keep-both-only")

        let moveSame = PasteConflictPlanner.plan(items: [item(root, "dest/a.txt")], into: dest, moving: true, files: files)
        T.check(!moveSame.hasConflicts, "moving an item into its own folder is a no-op, not a conflict")

        let dup = PasteConflictPlanner.plan(items: [item(root, "src/a.txt"), item(root, "src/a.txt")], into: dest, moving: false, files: files)
        T.equal(dup.replaceableFiles, ["a.txt"], "the same name twice is listed once")
    }

    // ---- wording -------------------------------------------------------------------------
    do {
        var plan = PastePlan(); plan.replaceableFiles = ["report.pdf"]
        T.equal(PasteConflictPlanner.title(for: plan), "Replace “report.pdf”?", "one file: title names it")
        T.check(PasteConflictPlanner.message(for: plan).contains("overwrites"), "one file: message says it overwrites")
        plan.replaceableFiles = ["a", "b", "c"]
        T.equal(PasteConflictPlanner.title(for: plan), "Replace 3 files?", "several files: title counts them")
        var folders = PastePlan(); folders.keepBothOnly = ["Stuff"]
        T.equal(PasteConflictPlanner.title(for: folders), "Name already used", "keep-both-only: neutral title")
        T.check(PasteConflictPlanner.message(for: folders).contains("Keep Both"), "keep-both-only: message points to Keep Both")
        var many = PastePlan(); many.replaceableFiles = (1...6).map { "f\($0)" }
        T.check(PasteConflictPlanner.message(for: many).contains("and 2 more"), "long lists are shortened")
    }

    // ---- land: keep both -----------------------------------------------------------------
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/a.txt", "NEW"); write(root, "dest/a.txt", "OLD")
        let landed = try? files.land(source: root.appendingPathComponent("src/a.txt").path, sourceIsDirectory: false, named: "a.txt",
                                     into: root.appendingPathComponent("dest").path, policy: .keepBoth, move: false)
        T.equal(read(root, "dest/a.txt"), "OLD", "keep both leaves the existing file alone")
        T.equal(read(root, "dest/a 2.txt"), "NEW", "keep both writes the numbered copy")
        T.equal(landed.map { ($0 as NSString).lastPathComponent }, "a 2.txt", "land reports the numbered name")
        T.equal(read(root, "src/a.txt"), "NEW", "a copy leaves the source")
    }

    // ---- land: replace (copy) -------------------------------------------------------------
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/a.txt", "NEW"); write(root, "dest/a.txt", "OLD")
        _ = try? files.land(source: root.appendingPathComponent("src/a.txt").path, sourceIsDirectory: false, named: "a.txt",
                            into: root.appendingPathComponent("dest").path, policy: .replace, move: false)
        T.equal(read(root, "dest/a.txt"), "NEW", "replace overwrites the existing file")
        T.equal(read(root, "src/a.txt"), "NEW", "replace by copy leaves the source")
        T.equal(names(root, "dest"), ["a.txt"], "replace leaves no staging file behind")
    }

    // ---- land: replace (move) -------------------------------------------------------------
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/a.txt", "NEW"); write(root, "dest/a.txt", "OLD")
        _ = try? files.land(source: root.appendingPathComponent("src/a.txt").path, sourceIsDirectory: false, named: "a.txt",
                            into: root.appendingPathComponent("dest").path, policy: .replace, move: true)
        T.equal(read(root, "dest/a.txt"), "NEW", "replace by move overwrites")
        T.check(!fm.fileExists(atPath: root.appendingPathComponent("src/a.txt").path), "replace by move removes the source")
        T.equal(names(root, "dest"), ["a.txt"], "no staging file after a move")
    }

    // ---- land: replace never touches a folder, or an item itself ---------------------------
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/dir", "I am a FILE called dir")
        try? fm.createDirectory(at: root.appendingPathComponent("dest/dir"), withIntermediateDirectories: true)
        write(root, "dest/dir/keep.txt", "KEEP")
        _ = try? files.land(source: root.appendingPathComponent("src/dir").path, sourceIsDirectory: false, named: "dir",
                            into: root.appendingPathComponent("dest").path, policy: .replace, move: false)
        T.equal(read(root, "dest/dir/keep.txt"), "KEEP", "a file never replaces a folder or its contents")
        T.equal(read(root, "dest/dir 2"), "I am a FILE called dir", "it lands beside the folder instead")
    }
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/stuff/one.txt", "1"); write(root, "dest/stuff", "a file")
        _ = try? files.land(source: root.appendingPathComponent("src/stuff").path, sourceIsDirectory: true, named: "stuff",
                            into: root.appendingPathComponent("dest").path, policy: .replace, move: false)
        T.equal(read(root, "dest/stuff"), "a file", "a folder never replaces a file")
        T.equal(read(root, "dest/stuff 2/one.txt"), "1", "the folder lands beside it")
    }
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "dest/a.txt", "ONLY COPY")
        let path = root.appendingPathComponent("dest/a.txt").path
        let landed = try? files.land(source: path, sourceIsDirectory: false, named: "a.txt",
                                     into: root.appendingPathComponent("dest").path, policy: .replace, move: false)
        T.equal(read(root, "dest/a.txt"), "ONLY COPY", "pasting an item over itself never destroys it")
        T.equal(read(root, "dest/a 2.txt"), "ONLY COPY", "it becomes a numbered copy")
        T.check(landed != nil, "land still reports a destination")
    }

    // ---- land: failure leaves the existing file as it was ----------------------------------
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "dest/a.txt", "OLD")
        var threw = false
        do {
            try files.land(source: root.appendingPathComponent("src/missing.txt").path, sourceIsDirectory: false, named: "a.txt",
                           into: root.appendingPathComponent("dest").path, policy: .replace, move: false)
        } catch { threw = true }
        T.check(threw, "replacing from a missing source fails")
        T.equal(read(root, "dest/a.txt"), "OLD", "a failed replace leaves the existing file untouched")
        T.equal(names(root, "dest"), ["a.txt"], "a failed replace leaves no staging file")
    }

    // ---- land: cancel and free names ---------------------------------------------------------
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/a.txt", "NEW"); try? fm.createDirectory(at: root.appendingPathComponent("dest"), withIntermediateDirectories: true)
        var cancelled: String? = "not called"
        do {
            cancelled = try files.land(source: root.appendingPathComponent("src/a.txt").path, sourceIsDirectory: false, named: "a.txt",
                                       into: root.appendingPathComponent("dest").path, policy: .cancel, move: false)
        } catch { cancelled = "threw" }
        T.check(cancelled == nil, "cancel returns nil without throwing")
        T.equal(names(root, "dest"), [], "cancel writes nothing")
        _ = try? files.land(source: root.appendingPathComponent("src/a.txt").path, sourceIsDirectory: false, named: "a.txt",
                            into: root.appendingPathComponent("dest").path, policy: .replace, move: false)
        T.equal(read(root, "dest/a.txt"), "NEW", "replace onto a free name just lands it")
    }
}
