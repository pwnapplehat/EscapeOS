import Foundation

private func item(_ name: String, directory: Bool = false, path: String? = nil) -> FileItem {
    FileItem(
        name: name,
        path: path ?? "/data/\(name)",
        kind: directory ? .directory : .regular,
        size: 0,
        modified: nil,
        isReadable: true,
        isWritable: true
    )
}

func runShareStagingTests() {
    T.section("ShareStaging")
    let files = FileService()
    let chunk = 4096

    // naming
    do {
        let plan = ShareStaging.plan(items: [item("a.txt"), item("photos", directory: true), item("b.pdf")])
        T.equal(plan.map(\.stagedName), ["a.txt", "photos.zip", "b.pdf"], "files keep their names and a folder becomes name.zip")
        T.equal(plan.map(\.isDirectory), [false, true, false], "which entries are folders is kept")
        T.equal(plan.map(\.sourcePath), ["/data/a.txt", "/data/photos", "/data/b.pdf"], "the source paths are kept, in order")
        T.check(ShareStaging.plan(items: []).isEmpty, "nothing selected, nothing planned")
    }

    // names that would collide get a number, ignoring case
    do {
        let sameCase = ShareStaging.plan(items: [item("notes.txt"), item("notes.txt", path: "/other/notes.txt")])
        T.equal(sameCase.map(\.stagedName), ["notes.txt", "notes 2.txt"], "two files with one name are numbered")
        let differentCase = ShareStaging.plan(items: [item("Report.pdf"), item("report.pdf"), item("REPORT.PDF")])
        T.equal(differentCase.map(\.stagedName), ["Report.pdf", "report 2.pdf", "REPORT 3.PDF"], "names that differ only by case are numbered: the volume would merge them")
        let zipVsFile = ShareStaging.plan(items: [item("a", directory: true), item("a.zip")])
        T.equal(zipVsFile.map(\.stagedName), ["a.zip", "a 2.zip"], "a folder's zip and a file called a.zip do not overwrite each other")
        let noExtension = ShareStaging.plan(items: [item("Makefile"), item("makefile")])
        T.equal(noExtension.map(\.stagedName), ["Makefile", "makefile 2"], "numbering works without an extension")
        let skipsTaken = ShareStaging.plan(items: [item("x.txt"), item("x 2.txt"), item("x.txt", path: "/o/x.txt")])
        T.equal(skipsTaken.map(\.stagedName), ["x.txt", "x 2.txt", "x 3.txt"], "a number already in use is skipped")
    }

    // characters a file name cannot hold
    do {
        T.equal(ShareStaging.safeName("a/b:c.txt"), "a_b-c.txt", "slashes and colons are replaced")
        T.equal(ShareStaging.safeName("  spaced.txt \n"), "spaced.txt", "surrounding whitespace is trimmed")
        T.equal(ShareStaging.safeName(""), "item", "an empty name gets a stand-in")
        T.equal(ShareStaging.safeName("   "), "item", "a blank name gets a stand-in")
        T.equal(ShareStaging.safeName(".."), "item", "dot-dot is not a name")
        T.equal(ShareStaging.safeName("."), "item", "dot is not a name")
        T.equal(ShareStaging.safeName("a\u{0}b"), "ab", "a NUL is dropped")
        let plan = ShareStaging.plan(items: [item("a/b", directory: true)])
        T.equal(plan.first?.stagedName ?? "", "a_b.zip", "a folder name is cleaned before .zip is added")
    }

    // staging copies files and zips folders, in order
    do {
        let s = Scratch("share-stage")
        s.write("src/one.txt", text: "first")
        s.write("src/two.bin", bytes: 3 * chunk + 5)
        s.write("src/dir/inner.txt", text: "inside")
        s.write("src/dir/sub/more.bin", bytes: 2 * chunk)
        s.mkdir("tmp")
        let items = [testItem(s, "src/one.txt"), testItem(s, "src/dir"), testItem(s, "src/two.bin")]
        var counted: Int64 = 0
        let observer = TransferObserver(bytes: { counted += $0 })
        let urls = try? ShareStaging.stage(
            entries: ShareStaging.plan(items: items),
            files: files,
            temporaryDirectory: URL(fileURLWithPath: s.path("tmp")),
            observer: observer,
            chunkSize: chunk
        )
        T.equal(urls?.map(\.lastPathComponent) ?? [], ["one.txt", "dir.zip", "two.bin"], "the staged files come back in selection order")
        if let urls {
            T.equal(FileManager.default.contents(atPath: urls[0].path), s.read("src/one.txt"), "a file is copied exactly")
            T.equal(FileManager.default.contents(atPath: urls[2].path), s.read("src/two.bin"), "a big file is copied exactly")
            let zip = FileManager.default.contents(atPath: urls[1].path).flatMap(MiniZip.init)
            T.equal(Set(zip?.entries.map(\.name) ?? []), ["dir/inner.txt", "dir/sub/more.bin"], "a folder is zipped under its own name")
            T.equal(zip?.entry("dir/inner.txt")?.data, s.read("src/dir/inner.txt"), "and the zipped content is intact")
            let parents = Set(urls.map { $0.deletingLastPathComponent().path })
            T.equal(parents.count, 1, "everything is in one folder")
            T.check(parents.first?.contains(ShareStaging.folderPrefix) ?? false, "named so the next share can sweep it")
            T.check(parents.first?.hasPrefix(s.path("tmp")) ?? false, "and under the temporary directory, not in the app's own data")
            if let result = runTool("/usr/bin/unzip", ["-t", urls[1].path]) { T.check(result.status == 0, "unzip accepts the staged zip") }
        }
        T.equal(counted, Int64(5 + 3 * chunk + 5 + 6 + 2 * chunk), "the observer saw all the bytes")
        T.check(s.exists("src/one.txt") && s.exists("src/dir/inner.txt"), "the originals are untouched")
    }

    // a staged file is a copy: changing the staged one leaves the original alone
    do {
        let s = Scratch("share-copy")
        s.write("src/a.txt", text: "original")
        s.mkdir("tmp")
        let urls = (try? ShareStaging.stage(
            entries: ShareStaging.plan(items: [testItem(s, "src/a.txt")]),
            temporaryDirectory: URL(fileURLWithPath: s.path("tmp"))
        )) ?? []
        if let url = urls.first { try? Data("changed".utf8).write(to: url) }
        T.equal(s.read("src/a.txt"), Data("original".utf8), "editing the staged copy does not touch the original")
    }

    // a single file shared as before still works
    do {
        let s = Scratch("share-single")
        s.write("src/only.txt", text: "just me")
        s.mkdir("tmp")
        let urls = (try? ShareStaging.stage(
            entries: ShareStaging.plan(items: [testItem(s, "src/only.txt")]),
            temporaryDirectory: URL(fileURLWithPath: s.path("tmp"))
        )) ?? []
        T.equal(urls.count, 1, "one item gives one url")
        T.equal(urls.first.flatMap { FileManager.default.contents(atPath: $0.path) }, Data("just me".utf8), "its content is intact")
    }

    // a failure part-way removes the whole staging folder
    if !runningAsRoot {
        let s = Scratch("share-fail")
        s.write("src/ok.txt", text: "ok")
        let locked = s.write("src/locked.txt", text: "secret")
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        s.mkdir("tmp")
        var failed = false
        do {
            _ = try ShareStaging.stage(
                entries: ShareStaging.plan(items: [testItem(s, "src/ok.txt"), testItem(s, "src/locked.txt")]),
                temporaryDirectory: URL(fileURLWithPath: s.path("tmp"))
            )
        } catch { failed = true }
        T.check(failed, "an unreadable file fails the share")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: s.path("tmp"))) ?? ["?"]
        T.check(left.isEmpty, "and no half-staged folder is left behind (\(left))")
    }

    // cancelling removes the staging folder too
    do {
        let s = Scratch("share-cancel")
        for index in 0..<4 { s.write("src/f\(index).bin", bytes: 4 * chunk) }
        s.mkdir("tmp")
        var seen: Int64 = 0
        let observer = TransferObserver(bytes: { seen += $0 }, isCancelled: { seen >= Int64(5 * chunk) })
        var cancelled = false
        do {
            _ = try ShareStaging.stage(
                entries: ShareStaging.plan(items: (0..<4).map { testItem(s, "src/f\($0).bin") }),
                temporaryDirectory: URL(fileURLWithPath: s.path("tmp")),
                observer: observer,
                chunkSize: chunk
            )
        } catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a cancelled share surfaces as JobCancelled")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: s.path("tmp"))) ?? ["?"]
        T.check(left.isEmpty, "and removes what it staged (\(left))")
        T.check(s.exists("src/f0.bin"), "the originals are untouched")
    }

    // an empty selection stages nothing but does not fail
    do {
        let s = Scratch("share-empty")
        s.mkdir("tmp")
        let urls = try? ShareStaging.stage(entries: [], temporaryDirectory: URL(fileURLWithPath: s.path("tmp")))
        T.equal(urls?.count ?? -1, 0, "no entries, no urls")
    }

    // sweeping only touches our own staging folders
    do {
        let s = Scratch("share-sweep")
        s.mkdir("tmp/escapeos-share-AAAA")
        s.write("tmp/escapeos-share-AAAA/old.txt", text: "x")
        s.mkdir("tmp/escapeos-share-BBBB")
        s.mkdir("tmp/escapeos-clip-CCCC")
        s.write("tmp/unrelated.txt", text: "keep")
        ShareStaging.sweepLeftovers(in: URL(fileURLWithPath: s.path("tmp")))
        T.check(!s.exists("tmp/escapeos-share-AAAA") && !s.exists("tmp/escapeos-share-BBBB"), "old share folders are removed")
        T.check(s.exists("tmp/escapeos-clip-CCCC"), "another feature's staging folder is left alone")
        T.check(s.exists("tmp/unrelated.txt"), "and so is anything else")
    }
}
