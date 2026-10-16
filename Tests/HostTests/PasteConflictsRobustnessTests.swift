import Foundation

private let fm = FileManager.default

private func makeRoot() -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent("escapeos-robust-\(UUID().uuidString)")
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

private func names(_ root: URL, _ rel: String) -> [String] {
    ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(rel).path)) ?? []).sorted()
}

/// Failure paths of Replace. The swap step (`rename(2)`) is injected so the rollback can be
/// exercised: it cannot be made to fail for real on a healthy temp folder.
func runPasteConflictsRobustnessTests() {
    T.section("PasteConflicts robustness")
    let files = FileService()
    let failingSwap: (String, String) -> Int32 = { _, _ in
        errno = EACCES
        return -1
    }

    // The swap fails after the copy was staged: existing file, source and folder all as before.
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/a.txt", "NEW"); write(root, "dest/a.txt", "OLD")
        var message = ""
        do {
            try files.land(source: root.appendingPathComponent("src/a.txt").path, sourceIsDirectory: false, named: "a.txt",
                           into: root.appendingPathComponent("dest").path, policy: .replace, move: false, swap: failingSwap)
        } catch { message = error.localizedDescription }
        T.check(message.contains("Could not replace"), "a failed swap reports that it could not replace")
        T.equal(read(root, "dest/a.txt"), "OLD", "copy: the existing file is untouched")
        T.equal(read(root, "src/a.txt"), "NEW", "copy: the source is untouched")
        T.equal(names(root, "dest"), ["a.txt"], "copy: the staged copy is removed")
    }

    // Same failure for a move: the original goes back where it came from.
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/a.txt", "NEW"); write(root, "dest/a.txt", "OLD")
        var threw = false
        do {
            try files.land(source: root.appendingPathComponent("src/a.txt").path, sourceIsDirectory: false, named: "a.txt",
                           into: root.appendingPathComponent("dest").path, policy: .replace, move: true, swap: failingSwap)
        } catch { threw = true }
        T.check(threw, "a failed swap on a move throws")
        T.equal(read(root, "src/a.txt"), "NEW", "move: the original is put back where it was")
        T.equal(read(root, "dest/a.txt"), "OLD", "move: the existing file is untouched")
        T.equal(names(root, "dest"), ["a.txt"], "move: nothing is left staged")
        T.equal(names(root, "src"), ["a.txt"], "move: nothing extra appears in the source folder")
    }

    // The staged copy itself fails (unreadable source, standing in for running out of space).
    if getuid() != 0 {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/locked.txt", "SECRET"); write(root, "dest/locked.txt", "OLD")
        let locked = root.appendingPathComponent("src/locked.txt").path
        _ = chmod(locked, 0o000)
        var threw = false
        do {
            try files.land(source: locked, sourceIsDirectory: false, named: "locked.txt",
                           into: root.appendingPathComponent("dest").path, policy: .replace, move: false)
        } catch { threw = true }
        _ = chmod(locked, 0o644)
        T.check(threw, "a copy that cannot be read fails")
        T.equal(read(root, "dest/locked.txt"), "OLD", "the existing file survives a failed copy")
        T.equal(names(root, "dest"), ["locked.txt"], "no hidden half-file is left behind")
    }

    // A copy that has already started writing, then fails, must not leave its partial result.
    // A real Replace only ever stages a file, but a folder with one unreadable file inside is the
    // portable way to make `copyItem` create something and then stop (as running out of space would),
    // so the source is passed as a plain item to reach that path.
    if getuid() != 0 {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "src/box/aaa-readable.txt", "fine")
        write(root, "src/box/zzz-locked.txt", "SECRET")
        write(root, "dest/box", "OLD")
        let locked = root.appendingPathComponent("src/box/zzz-locked.txt").path
        _ = chmod(locked, 0o000)
        var threw = false
        do {
            try files.land(source: root.appendingPathComponent("src/box").path, sourceIsDirectory: false, named: "box",
                           into: root.appendingPathComponent("dest").path, policy: .replace, move: false)
        } catch { threw = true }
        _ = chmod(locked, 0o644)
        T.check(threw, "a copy that fails part-way reports the failure")
        T.equal(read(root, "dest/box"), "OLD", "the existing item survives a copy that failed part-way")
        T.equal(names(root, "dest"), ["box"], "and the partial staged copy is cleaned up")
    }

    // Moving an item onto the very same place never loses it.
    do {
        let root = makeRoot(); defer { try? fm.removeItem(at: root) }
        write(root, "dest/a.txt", "ONLY COPY")
        let path = root.appendingPathComponent("dest/a.txt").path
        let landed = try? files.land(source: path, sourceIsDirectory: false, named: "a.txt",
                                     into: root.appendingPathComponent("dest").path, policy: .replace, move: true)
        let survivors = names(root, "dest").compactMap { read(root, "dest/" + $0) }
        T.equal(survivors, ["ONLY COPY"], "a move onto itself leaves exactly one copy, with its content")
        T.check(landed != nil, "and still reports where it is")
    }

    // The same-folder rule shared by the planner and the paste.
    do {
        let dir = "/private/var/mobile/Containers/Data/Application/AAAA/Documents"
        T.check(PasteConflictPlanner.isInSameFolder(dir + "/a.txt", as: dir), "an item in the folder is in the same folder")
        T.check(PasteConflictPlanner.isInSameFolder("/var/mobile/Containers/Data/Application/AAAA/Documents/a.txt", as: dir), "/var and /private/var agree")
        T.check(PasteConflictPlanner.isInSameFolder(dir + "/a.txt", as: dir + "/"), "a trailing slash does not matter")
        T.check(!PasteConflictPlanner.isInSameFolder(dir + "/Sub/a.txt", as: dir), "an item in a subfolder is not")
        T.check(!PasteConflictPlanner.isInSameFolder(dir + "/a.txt", as: dir + "/Sub"), "nor is an item and its sibling folder")
        T.check(!PasteConflictPlanner.isInSameFolder("/private/var/mobile/Containers/Data/Application/AAAA/a.txt", as: dir), "nor an item in the parent")
    }
}
