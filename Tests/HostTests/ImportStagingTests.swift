import Foundation

func runImportStagingTests() {
    T.section("ImportStaging")
    let files = FileService()
    let chunk = 4096

    // staging a file
    do {
        let s = Scratch("drop-file")
        s.write("incoming/photo.jpg", bytes: 3 * chunk + 11)
        s.mkdir("staging")
        let folder = URL(fileURLWithPath: s.path("staging"))
        var counted: Int64 = 0
        let staged = try? ImportStaging.stage(
            source: URL(fileURLWithPath: s.path("incoming/photo.jpg")), into: folder, files: files,
            observer: TransferObserver(bytes: { counted += $0 }), chunkSize: chunk
        )
        T.equal(staged?.name ?? "", "photo.jpg", "the dropped name is kept")
        T.equal(staged?.isDirectory, false, "a file is a file")
        T.equal(staged?.bytes ?? -1, Int64(3 * chunk + 11), "its size is recorded")
        T.equal(counted, Int64(3 * chunk + 11), "and its progress was reported")
        if let staged {
            T.equal(FileManager.default.contents(atPath: staged.path), s.read("incoming/photo.jpg"), "the staged copy is exact")
            T.check(staged.path.hasPrefix(folder.path), "and it is inside the staging folder")
        }
        T.check(s.exists("incoming/photo.jpg"), "the dropped original is untouched")
    }

    // staging a folder
    do {
        let s = Scratch("drop-folder")
        s.write("incoming/Album/one.jpg", bytes: 5_000)
        s.write("incoming/Album/inner/two.jpg", bytes: 7_000)
        s.mkdir("incoming/Album/empty")
        s.mkdir("staging")
        let staged = try? ImportStaging.stage(
            source: URL(fileURLWithPath: s.path("incoming/Album")), into: URL(fileURLWithPath: s.path("staging")),
            files: files, chunkSize: chunk
        )
        T.equal(staged?.isDirectory, true, "a dropped folder is staged as a folder")
        T.equal(staged?.bytes ?? -1, 12_000, "with the size of everything in it")
        if let staged {
            T.equal(FileManager.default.contents(atPath: staged.path + "/inner/two.jpg")?.count ?? -1, 7_000, "its contents are intact")
            T.check(files.isDirectory(at: staged.path + "/empty"), "an empty folder inside is kept")
        }
    }

    // two items with one name
    do {
        let s = Scratch("drop-same")
        s.write("a/notes.txt", text: "from a")
        s.write("b/notes.txt", text: "from b")
        s.mkdir("staging")
        let folder = URL(fileURLWithPath: s.path("staging"))
        let first = try? ImportStaging.stage(source: URL(fileURLWithPath: s.path("a/notes.txt")), into: folder, files: files)
        let second = try? ImportStaging.stage(source: URL(fileURLWithPath: s.path("b/notes.txt")), into: folder, files: files)
        T.check(first?.path != second?.path, "equal names do not land on one path in staging")
        T.equal(first.flatMap { FileManager.default.contents(atPath: $0.path) }, Data("from a".utf8), "the first keeps its content")
        T.equal(second.flatMap { FileManager.default.contents(atPath: $0.path) }, Data("from b".utf8), "and the second its own")
        T.equal(first?.name ?? "", second?.name ?? "x", "both keep the dropped name")
    }

    // names a file cannot have
    do {
        let s = Scratch("drop-name")
        s.write("incoming/a:b.txt", text: "x")
        s.mkdir("staging")
        let staged = try? ImportStaging.stage(source: URL(fileURLWithPath: s.path("incoming/a:b.txt")), into: URL(fileURLWithPath: s.path("staging")), files: files)
        T.equal(staged?.name ?? "", "a-b.txt", "a colon is replaced")
    }

    // a link is staged as a link
    do {
        let s = Scratch("drop-link")
        s.mkdir("incoming")
        try? FileManager.default.createSymbolicLink(atPath: s.path("incoming/link"), withDestinationPath: "elsewhere")
        s.mkdir("staging")
        let staged = try? ImportStaging.stage(source: URL(fileURLWithPath: s.path("incoming/link")), into: URL(fileURLWithPath: s.path("staging")), files: files)
        T.equal(staged?.isDirectory, false, "a link is not a folder even if it points at one")
        T.check(staged.map { files.isSymlink(at: $0.path) } ?? false, "and stays a link")
    }

    // a missing source, and a cancel, leave nothing behind
    do {
        let s = Scratch("drop-fail")
        s.write("incoming/big.bin", bytes: 8 * chunk)
        s.mkdir("staging")
        let folder = URL(fileURLWithPath: s.path("staging"))
        var failed = false
        do { _ = try ImportStaging.stage(source: URL(fileURLWithPath: s.path("incoming/nope")), into: folder, files: files) } catch { failed = true }
        T.check(failed, "a source that is not there fails")
        var seen: Int64 = 0
        var cancelled = false
        do {
            _ = try ImportStaging.stage(
                source: URL(fileURLWithPath: s.path("incoming/big.bin")), into: folder, files: files,
                observer: TransferObserver(bytes: { seen += $0 }, isCancelled: { seen >= Int64(2 * chunk) }), chunkSize: chunk
            )
        } catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a cancelled drop surfaces as JobCancelled")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
        T.check(left.isEmpty, "and leaves nothing in the staging folder (\(left))")
    }

    // conflict planning, with the same rules as Paste
    do {
        let s = Scratch("drop-plan")
        s.write("dest/exists.txt", text: "old")
        s.mkdir("dest/Folder")
        s.write("dest/Photos", text: "a file where a folder is dropped")
        let staged = [
            StagedImport(name: "exists.txt", path: s.path("st/exists.txt"), isDirectory: false, bytes: 3),
            StagedImport(name: "fresh.txt", path: s.path("st/fresh.txt"), isDirectory: false, bytes: 3),
            StagedImport(name: "Folder", path: s.path("st/Folder"), isDirectory: false, bytes: 3),
            StagedImport(name: "Photos", path: s.path("st/Photos"), isDirectory: true, bytes: 3),
        ]
        let plan = ImportStaging.plan(staged: staged, into: s.path("dest"), files: files)
        T.equal(plan.replaceableFiles, ["exists.txt"], "a file dropped onto a file can be replaced")
        T.equal(plan.keepBothOnly, ["Folder", "Photos"], "a file onto a folder, and a folder onto a file, only keep both")
        T.check(plan.hasConflicts, "so there are conflicts to ask about")
        let clean = ImportStaging.plan(staged: [staged[1]], into: s.path("dest"), files: files)
        T.check(!clean.hasConflicts, "a new name has none")
        let items = ImportStaging.fileItems(for: staged)
        T.equal(items.map(\.name), staged.map(\.name), "staged items map to browser items by name")
        T.equal(items.map(\.isDirectory), [false, false, false, true], "and by kind")
    }

    // landing with each choice
    do {
        let s = Scratch("drop-land")
        s.write("dest/a.txt", text: "existing a")
        s.mkdir("staging")
        s.write("src/a.txt", text: "dropped a")
        s.write("src/b.txt", text: "dropped b")
        s.write("src/Folder/inner.txt", text: "inner")
        let folder = URL(fileURLWithPath: s.path("staging"))
        func stageAll() -> [StagedImport] {
            ["src/a.txt", "src/b.txt", "src/Folder"].compactMap {
                try? ImportStaging.stage(source: URL(fileURLWithPath: s.path($0)), into: folder, files: files)
            }
        }

        let keep = stageAll()
        let kept = (try? ImportStaging.land(keep, into: s.path("dest"), policy: .keepBoth, files: files)) ?? []
        T.equal(kept.map { ($0 as NSString).lastPathComponent }, ["a 2.txt", "b.txt", "Folder"], "Keep Both lands a clash under a new name")
        T.equal(s.read("dest/a.txt"), Data("existing a".utf8), "and leaves the existing file alone")
        T.equal(s.read("dest/a 2.txt"), Data("dropped a".utf8), "with the dropped content")
        T.equal(s.read("dest/Folder/inner.txt"), Data("inner".utf8), "a folder lands with its contents")
        T.check(keep.allSatisfy { !s.exists(String($0.path.dropFirst(s.root.count + 1))) }, "the staged copies are moved out, not copied")
        T.check(s.exists("src/a.txt") && s.exists("src/Folder/inner.txt"), "the dropped originals are untouched")

        try? FileManager.default.removeItem(atPath: s.path("dest/b.txt"))
        try? FileManager.default.removeItem(atPath: s.path("dest/Folder"))
        try? FileManager.default.removeItem(atPath: s.path("dest/a 2.txt"))
        let replace = stageAll()
        let replaced = (try? ImportStaging.land(replace, into: s.path("dest"), policy: .replace, files: files)) ?? []
        T.equal(replaced.map { ($0 as NSString).lastPathComponent }, ["a.txt", "b.txt", "Folder"], "Replace lands a clash on the same name")
        T.equal(s.read("dest/a.txt"), Data("dropped a".utf8), "the existing file is overwritten")

        let cancelled = stageAll()
        let none = (try? ImportStaging.land(cancelled, into: s.path("dest"), policy: .cancel, files: files)) ?? ["?"]
        T.check(none.isEmpty, "Cancel lands nothing")
        T.check(cancelled.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "and the staged copies stay until discarded")
        ImportStaging.discard(folder)
        T.check(!s.exists("staging"), "discarding removes the staging folder")
    }

    // a folder dropped onto an existing folder lands beside it, never merged or replaced
    do {
        let s = Scratch("drop-folder-clash")
        s.write("dest/Album/old.txt", text: "old")
        s.mkdir("staging")
        s.write("src/Album/new.txt", text: "new")
        let staged = (try? ImportStaging.stage(source: URL(fileURLWithPath: s.path("src/Album")), into: URL(fileURLWithPath: s.path("staging")), files: files)).map { [$0] } ?? []
        let landed = (try? ImportStaging.land(staged, into: s.path("dest"), policy: .replace, files: files)) ?? []
        T.equal(landed.map { ($0 as NSString).lastPathComponent }, ["Album 2"], "a folder is never replaced; it lands as 'Album 2'")
        T.equal(s.read("dest/Album/old.txt"), Data("old".utf8), "the existing folder is untouched")
        T.equal(s.read("dest/Album 2/new.txt"), Data("new".utf8), "and the dropped one is whole")
    }

    // a cancel during landing stops between items
    do {
        let s = Scratch("drop-land-cancel")
        s.mkdir("dest")
        s.mkdir("staging")
        for name in ["a", "b", "c"] { s.write("src/\(name).txt", text: name) }
        let folder = URL(fileURLWithPath: s.path("staging"))
        let staged = ["a", "b", "c"].compactMap { try? ImportStaging.stage(source: URL(fileURLWithPath: s.path("src/\($0).txt")), into: folder, files: files) }
        var landedCount = 0
        let observer = TransferObserver(detail: { _ in landedCount += 1 }, isCancelled: { landedCount > 2 })
        var cancelled = false
        do { _ = try ImportStaging.land(staged, into: s.path("dest"), policy: .keepBoth, files: files, observer: observer) }
        catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a cancel while landing surfaces as JobCancelled")
        T.check(s.exists("dest/a.txt"), "what had already landed stays landed")
        T.check(!s.exists("dest/c.txt"), "and the rest does not")
    }

    // sweeping only removes our own staging folders
    do {
        let s = Scratch("drop-sweep")
        s.mkdir("tmp/escapeos-drop-AAAA")
        s.write("tmp/escapeos-drop-AAAA/x.bin", bytes: 10)
        s.mkdir("tmp/escapeos-share-BBBB")
        s.write("tmp/other.txt", text: "keep")
        ImportStaging.sweepLeftovers(in: URL(fileURLWithPath: s.path("tmp")))
        T.check(!s.exists("tmp/escapeos-drop-AAAA"), "an unfinished drop's folder is removed")
        T.check(s.exists("tmp/escapeos-share-BBBB"), "a share folder is not ours to remove here")
        T.check(s.exists("tmp/other.txt"), "and neither is anything else")
        let made = try? ImportStaging.makeFolder(in: URL(fileURLWithPath: s.path("tmp")))
        T.check(made.map { $0.lastPathComponent.hasPrefix(ImportStaging.folderPrefix) } ?? false, "a new staging folder carries the prefix the sweep looks for")
    }
}
