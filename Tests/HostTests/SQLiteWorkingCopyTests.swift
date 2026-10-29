import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A database the way an app that stopped suddenly leaves it: write-ahead-log mode, with rows 51-60
/// only in the `-wal` file, no connection open. Reading it plainly would replay the log and tidy the
/// files, so the tests keep their own copy of the expected bytes.
private func makeLeftoverWALDatabase(_ s: Scratch, directory: String = "orig") -> String? {
    s.mkdir("src")
    guard let live = makeDatabase(s.path("src/app.db"), wal: true, [
        "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)",
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, text TEXT)",
    ]) else { return nil }
    for id in 1...50 { try? live.execute("INSERT INTO items VALUES (\(id), 'item \(id)', \(id))") }
    try? live.checkpointAndTruncate()
    for id in 51...60 { try? live.execute("INSERT INTO items VALUES (\(id), 'item \(id)', \(id))") }
    s.mkdir(directory)
    for suffix in ["", "-wal"] {
        try? FileManager.default.copyItem(atPath: s.path("src/app.db\(suffix)"), toPath: s.path("\(directory)/app.db\(suffix)"))
    }
    live.close()
    let path = s.path("\(directory)/app.db")
    let wal = ((try? FileManager.default.attributesOfItem(atPath: path + "-wal"))?[.size] as? NSNumber)?.intValue ?? 0
    return wal > 0 ? path : nil
}

private func bytes(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

private func itemCount(_ db: SQLiteDatabase) -> Int {
    guard let t = table(db, "items") else { return -1 }
    return (try? db.rowCount(of: t.name)) ?? -1
}

private func names(in directory: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
}

func runSQLiteWorkingCopyTests() {
    T.section("SQLiteWorkingCopy")
    let files = FileService()

    // opening copies the database and its log, and leaves the original alone
    do {
        let s = Scratch("wc-open")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up: a database with a log"); return }
        s.mkdir("tmp")
        let mainBefore = bytes(original), walBefore = bytes(original + "-wal")
        let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0)
        T.check(copy != nil, "a database with a leftover log opens")
        if let copy {
            T.equal(itemCount(copy.database), 60, "the copy includes the rows that were only in the log")
            T.check(copy.workingPath.hasPrefix(s.path("tmp")), "the copy is in the temporary folder")
            T.check(copy.workingPath != original, "and is not the original")
            T.check(!copy.hasUnsavedChanges, "nothing is unsaved yet")
            T.check(!copy.hasOriginalChanged(), "and the original is as it was when copied")
        }
        T.equal(bytes(original), mainBefore, "the original database file is byte for byte unchanged")
        T.equal(bytes(original + "-wal"), walBefore, "and so is its log")
        T.check(!FileManager.default.fileExists(atPath: original + "-shm"), "opening it did not create files beside the original")
        copy?.discard()
    }

    // editing changes the copy only
    do {
        let s = Scratch("wc-edit")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        guard let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0),
              let items = table(copy.database, "items") else { T.check(false, "set-up: open"); return }
        let mainBefore = bytes(original), walBefore = bytes(original + "-wal")
        try? copy.database.update(table: items, key: .rowID(1), column: "name", to: .text("EDITED"))
        T.check(copy.hasUnsavedChanges, "an edit is an unsaved change")
        T.equal(bytes(original), mainBefore, "the original database is untouched by an edit")
        T.equal(bytes(original + "-wal"), walBefore, "and so is its log")
        T.check(!copy.hasOriginalChanged(), "editing the copy does not count as the original changing")
        copy.discard()
    }

    // saving, end to end
    do {
        let s = Scratch("wc-save")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        guard let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0),
              let items = table(copy.database, "items") else { T.check(false, "set-up: open"); return }
        try? copy.database.update(table: items, key: .rowID(1), column: "name", to: .text("EDITED"))
        try? copy.database.update(table: items, key: .rowID(60), column: "name", to: .text("EDITED LOG ROW"))

        var keepCalls = 0
        var snapshotName = ""
        var snapshotFolderFiles: [String] = []
        var snapshotRows = -1
        var snapshotFirst: SQLiteValue?
        var snapshotLast: SQLiteValue?
        var snapshotHealth = ""
        var kept: Data?
        var saved = true
        do {
            try copy.saveToOriginal { snapshot in
                keepCalls += 1
                snapshotName = (snapshot as NSString).lastPathComponent
                snapshotFolderFiles = names(in: (snapshot as NSString).deletingLastPathComponent)
                if let db = try? SQLiteDatabase(path: snapshot, readOnly: true), let t = table(db, "items") {
                    snapshotRows = (try? db.rowCount(of: "items")) ?? -1
                    let rows = (try? db.rows(in: t, offset: 0, limit: 100)) ?? []
                    snapshotFirst = rows.first?.cells[1].value
                    snapshotLast = rows.last?.cells[1].value
                    snapshotHealth = (try? db.quickCheck()) ?? ""
                }
                kept = bytes(snapshot)
            }
        } catch { saved = false; print("  save failed: \(error.localizedDescription)") }
        T.check(saved, "the edited database is saved")
        T.equal(keepCalls, 1, "the caller was asked to keep the original once")
        T.equal(snapshotName, "app.db", "the snapshot carries the database's own name, so it restores under it")
        T.equal(snapshotFolderFiles, ["app.db"], "and is one file: the log is folded in, not left beside it")
        T.equal(snapshotRows, 60, "it holds all 60 rows, including those that were only in the log")
        T.equal(snapshotFirst, .text("item 1"), "as they were before the edit")
        T.equal(snapshotLast, .text("item 60"), "including the row that came from the log")
        T.equal(snapshotHealth, "ok", "and it is a healthy database")
        T.check((kept?.count ?? 0) > 0, "and it could be read while the closure ran")

        T.check(!FileManager.default.fileExists(atPath: original + "-wal"), "the old log is gone: it described the old file")
        T.check(!FileManager.default.fileExists(atPath: original + "-shm"), "so is the old index")
        T.check(!FileManager.default.fileExists(atPath: original + "-journal"), "and no journal is left")
        T.equal(names(in: s.path("orig")), ["app.db"], "only the database is in the folder: no temporary or set-aside files remain")
        T.check(!copy.hasUnsavedChanges, "nothing is unsaved after a save")
        T.check(!copy.hasOriginalChanged(), "and the original matches what was just written")

        guard let check = try? SQLiteDatabase(path: original) else { T.check(false, "the saved database opens"); return }
        T.equal(itemCount(check), 60, "all 60 rows are there, including the ones that were only in the log")
        T.equal((try? check.quickCheck()) ?? "", "ok", "and the database is healthy")
        if let t = table(check, "items") {
            let rows = (try? check.rows(in: t, offset: 0, limit: 100)) ?? []
            T.equal(rows.first?.cells[1].value, .text("EDITED"), "the edit is in the saved database")
            T.equal(rows.last?.cells[1].value, .text("EDITED LOG ROW"), "and so is the edit to a row that came from the log")
            T.equal(rows[10].cells[1].value, .text("item 11"), "other rows are as they were")
        }
        check.close()

        // the copy keeps working, and can be saved again
        try? copy.database.update(table: items, key: .rowID(2), column: "name", to: .text("SECOND"))
        T.check(copy.hasUnsavedChanges, "after a save, a new edit is unsaved again")
        var second = true
        do { try copy.saveToOriginal { _ in } } catch { second = false }
        T.check(second, "a second save works")
        if let again = try? SQLiteDatabase(path: original), let t = table(again, "items") {
            T.equal((try? again.rows(in: t, offset: 0, limit: 5))?[1].cells[1].value, .text("SECOND"), "with the second edit in it")
            again.close()
        }
        T.equal(names(in: s.path("orig")), ["app.db"], "and still nothing left over")
        copy.discard()
    }

    // the app writes to the original while the save is under way: caught just before the swap
    do {
        let s = Scratch("wc-changed-late")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        guard let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0),
              let items = table(copy.database, "items") else { T.check(false, "set-up: open"); return }
        try? copy.database.update(table: items, key: .rowID(1), column: "name", to: .text("EDITED"))
        copy.beforeSwap = {
            if let handle = FileHandle(forWritingAtPath: original + "-wal") {
                handle.seekToEndOfFile()
                handle.write(Data(repeating: 0, count: 64))
                try? handle.close()
            }
        }
        let mainBefore = bytes(original), walBefore = bytes(original + "-wal")
        var error: WorkingCopyError?
        do { try copy.saveToOriginal { _ in } } catch let e as WorkingCopyError { error = e } catch {}
        T.equal(error, .originalChanged, "a change made after the first check still stops the save")
        T.equal(bytes(original), mainBefore, "the original database is untouched")
        T.check(bytes(original + "-wal") != nil && (bytes(original + "-wal")?.count ?? 0) >= (walBefore?.count ?? 0), "and its log is still beside it")
        let leftovers = names(in: (original as NSString).deletingLastPathComponent).filter { $0.hasPrefix(".escapeos-") }
        T.equal(leftovers, [], "no temporary file is left next to it")
        T.check(copy.hasUnsavedChanges, "the edits are still there")
        copy.discard()
    }

    // the app changed the database after it was opened: refuse, change nothing
    do {
        let s = Scratch("wc-changed")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        guard let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0),
              let items = table(copy.database, "items") else { T.check(false, "set-up: open"); return }
        try? copy.database.update(table: items, key: .rowID(1), column: "name", to: .text("EDITED"))
        // the app appends to its log
        if let handle = FileHandle(forWritingAtPath: original + "-wal") {
            handle.seekToEndOfFile()
            handle.write(Data(repeating: 0, count: 64))
            try? handle.close()
        }
        let mainBefore = bytes(original), walBefore = bytes(original + "-wal")
        T.check(copy.hasOriginalChanged(), "a change to the log is noticed")
        var keepCalled = false
        var error: WorkingCopyError?
        do { try copy.saveToOriginal { _ in keepCalled = true } } catch let e as WorkingCopyError { error = e } catch {}
        T.equal(error, .originalChanged, "saving over a changed original is refused")
        T.check(!keepCalled, "without even keeping a copy")
        T.equal(bytes(original), mainBefore, "the original database is untouched")
        T.equal(bytes(original + "-wal"), walBefore, "and so is its log")
        T.check(copy.hasUnsavedChanges, "the edits are still there to share")
        T.check((error?.errorDescription ?? "").contains("overwrite those changes"), "the message says why")
        copy.discard()
    }

    // a change to the main file is noticed too
    do {
        let s = Scratch("wc-changed-main")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        guard let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0) else { T.check(false, "set-up: open"); return }
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3_600)], ofItemAtPath: original)
        T.check(copy.hasOriginalChanged(), "a new modification time on the database is noticed")
        copy.discard()
    }

    // if the original cannot be kept, nothing is saved
    do {
        let s = Scratch("wc-keepfail")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        guard let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0),
              let items = table(copy.database, "items") else { T.check(false, "set-up: open"); return }
        try? copy.database.update(table: items, key: .rowID(1), column: "name", to: .text("EDITED"))
        let mainBefore = bytes(original), walBefore = bytes(original + "-wal")
        struct NoRoom: LocalizedError { var errorDescription: String? { "The Trash is full." } }
        var error: WorkingCopyError?
        do { try copy.saveToOriginal { _ in throw NoRoom() } } catch let e as WorkingCopyError { error = e } catch {}
        T.equal(error, .safetyCopyFailed("The Trash is full."), "failing to keep the original stops the save")
        T.check((error?.errorDescription ?? "").contains("nothing was saved"), "and says nothing was saved")
        T.equal(bytes(original), mainBefore, "the original is untouched")
        T.equal(bytes(original + "-wal"), walBefore, "and so is its log")
        T.check(copy.hasUnsavedChanges, "the edits are still unsaved")
        T.check(copy.database.isOpen, "and the copy is still open to try again")
        var retried = true
        do { try copy.saveToOriginal { _ in } } catch { retried = false }
        T.check(retried, "trying again works")
        copy.discard()
    }

    // the swap fails: the original and its log are put back exactly
    do {
        let s = Scratch("wc-swapfail")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        let failSwap: (String, String) -> Bool = { from, to in
            if to == original { return false }
            return rename(from, to) == 0
        }
        guard let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0, renamer: failSwap),
              let items = table(copy.database, "items") else { T.check(false, "set-up: open"); return }
        try? copy.database.update(table: items, key: .rowID(1), column: "name", to: .text("EDITED"))
        let mainBefore = bytes(original), walBefore = bytes(original + "-wal")
        var error: WorkingCopyError?
        do { try copy.saveToOriginal { _ in } } catch let e as WorkingCopyError { error = e } catch {}
        if case .saveFailed? = error { T.check(true, "a failed swap is a save failure") } else { T.check(false, "a failed swap is a save failure") }
        T.check((error?.errorDescription ?? "").contains("original was left as it was"), "and says the original was left alone")
        T.equal(bytes(original), mainBefore, "the original database is untouched")
        T.equal(bytes(original + "-wal"), walBefore, "and its log was put back")
        T.equal(names(in: s.path("orig")), ["app.db", "app.db-wal"], "with no temporary or set-aside files left in its folder")
        T.check(copy.hasUnsavedChanges, "the edits are still unsaved")
        T.check(copy.database.isOpen, "and the copy is open again")
        if let again = table(copy.database, "items") {
            T.equal((try? copy.database.rows(in: again, offset: 0, limit: 1))?.first?.cells[1].value, .text("EDITED"), "with the edit still in it")
        }
        copy.discard()
    }

    // setting the log aside fails: nothing has changed
    do {
        let s = Scratch("wc-asidefail")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        let failAside: (String, String) -> Bool = { from, to in
            if from == original + "-wal" { return false }
            return rename(from, to) == 0
        }
        guard let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0, renamer: failAside),
              let items = table(copy.database, "items") else { T.check(false, "set-up: open"); return }
        try? copy.database.update(table: items, key: .rowID(1), column: "name", to: .text("EDITED"))
        let mainBefore = bytes(original), walBefore = bytes(original + "-wal")
        var failed = false
        do { try copy.saveToOriginal { _ in } } catch { failed = true }
        T.check(failed, "failing to set the log aside fails the save")
        T.equal(bytes(original), mainBefore, "the original database is untouched")
        T.equal(bytes(original + "-wal"), walBefore, "and so is its log")
        T.equal(names(in: s.path("orig")), ["app.db", "app.db-wal"], "and nothing is left over")
        copy.discard()
    }

    // the app writes while the copy is being made
    do {
        let s = Scratch("wc-inuse")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        func touch() {
            if let handle = FileHandle(forWritingAtPath: original + "-wal") {
                handle.seekToEndOfFile()
                handle.write(Data(repeating: 0, count: 32))
                try? handle.close()
            }
        }
        var attempts = 0
        let copy = try? SQLiteWorkingCopy.open(
            original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")),
            afterCopy: { attempt in attempts = attempt; if attempt == 1 { touch() } }, retryDelay: 0
        )
        T.check(copy != nil, "a copy that was torn once is taken again and succeeds")
        T.equal(attempts, 2, "on the second attempt")
        copy?.discard()
        let leftover = names(in: s.path("tmp"))
        T.check(leftover.isEmpty, "the torn copy was removed (\(leftover))")

        var error: WorkingCopyError?
        attempts = 0
        do {
            _ = try SQLiteWorkingCopy.open(
                original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")),
                afterCopy: { attempt in attempts = attempt; touch() }, retryDelay: 0
            )
        } catch let e as WorkingCopyError { error = e } catch {}
        T.equal(error, .inUse, "a database that keeps changing is reported as in use")
        T.equal(attempts, 3, "after three tries")
        T.check(names(in: s.path("tmp")).isEmpty, "and no copy is left behind")
        T.check((error?.errorDescription ?? "").contains("Close the app"), "with advice to close the app")
    }

    // things that are not databases, and things that are not there
    do {
        let s = Scratch("wc-bad")
        s.write("orig/notes.db", text: "this is not a database")
        s.mkdir("tmp")
        var error: SQLiteError?
        do { _ = try SQLiteWorkingCopy.open(original: s.path("orig/notes.db"), files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp"))) } catch let e as SQLiteError { error = e } catch {}
        T.equal(error, .notADatabase, "a file that is not a database is refused")
        T.check(names(in: s.path("tmp")).isEmpty, "and leaves no copy behind")
        T.equal(bytes(s.path("orig/notes.db")), Data("this is not a database".utf8), "or any change to the file")
        var missing = false
        do { _ = try SQLiteWorkingCopy.open(original: s.path("orig/gone.db"), files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp"))) } catch { missing = true }
        T.check(missing, "a missing file is an error")
        T.check(names(in: s.path("tmp")).isEmpty, "with nothing left behind")
    }

    // cancelling while copying leaves nothing
    do {
        let s = Scratch("wc-cancel")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        var cancelled = false
        do {
            _ = try SQLiteWorkingCopy.open(
                original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")),
                observer: TransferObserver(isCancelled: { true })
            )
        } catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a cancel while opening surfaces as JobCancelled")
        T.check(names(in: s.path("tmp")).isEmpty, "and leaves no copy")
    }

    // a database that is not in log mode
    do {
        let s = Scratch("wc-plain")
        s.mkdir("orig")
        makeDatabase(s.path("orig/plain.db"), ["CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", "INSERT INTO t VALUES (1, 'a')", "INSERT INTO t VALUES (2, 'b')"])?.close()
        s.mkdir("tmp")
        guard let copy = try? SQLiteWorkingCopy.open(original: s.path("orig/plain.db"), files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0),
              let t = table(copy.database, "t") else { T.check(false, "set-up: open"); return }
        try? copy.database.update(table: t, key: .rowID(1), column: "v", to: .text("changed"))
        T.check((try? copy.saveToOriginal { _ in }) != nil, "an ordinary database saves")
        T.equal(names(in: s.path("orig")), ["plain.db"], "with nothing left over")
        if let check = try? SQLiteDatabase(path: s.path("orig/plain.db")), let ct = table(check, "t") {
            T.equal((try? check.rows(in: ct, offset: 0, limit: 5))?.first?.cells[1].value, .text("changed"), "and the edit is in it")
            T.equal((try? check.quickCheck()) ?? "", "ok", "and it is healthy")
            check.close()
        }
        copy.discard()
    }

    // sharing a copy: one self-contained file
    do {
        let s = Scratch("wc-share")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        guard let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0),
              let items = table(copy.database, "items") else { T.check(false, "set-up: open"); return }
        try? copy.database.update(table: items, key: .rowID(60), column: "name", to: .text("SHARED EDIT"))
        let path = (try? copy.shareablePath()) ?? ""
        s.mkdir("out")
        try? FileManager.default.copyItem(atPath: path, toPath: s.path("out/shared.db"))
        T.check(!FileManager.default.fileExists(atPath: s.path("out/shared.db-wal")), "the shared file has no log beside it")
        if let shared = try? SQLiteDatabase(path: s.path("out/shared.db")), let t = table(shared, "items") {
            T.equal(itemCount(shared), 60, "yet holds every row, including those that were in the log")
            T.equal((try? shared.rows(in: t, offset: 59, limit: 1))?.first?.cells[1].value, .text("SHARED EDIT"), "and the edit")
            shared.close()
        } else {
            T.check(false, "the shared file opens on its own")
        }
        copy.discard()
    }

    // a folder that cannot be written to
    if !runningAsRoot {
        let s = Scratch("wc-readonly")
        s.mkdir("orig")
        makeDatabase(s.path("orig/ro.db"), ["CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", "INSERT INTO t VALUES (1, 'a')"])?.close()
        s.mkdir("tmp")
        guard let copy = try? SQLiteWorkingCopy.open(original: s.path("orig/ro.db"), files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0),
              let t = table(copy.database, "t") else { T.check(false, "set-up: open"); return }
        try? copy.database.update(table: t, key: .rowID(1), column: "v", to: .text("changed"))
        let before = bytes(s.path("orig/ro.db"))
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: s.path("orig"))
        var failed = false
        do { try copy.saveToOriginal { _ in } } catch { failed = true }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.path("orig"))
        T.check(failed, "saving into a folder that cannot be written fails")
        T.equal(bytes(s.path("orig/ro.db")), before, "and leaves the original as it was")
        T.check(copy.hasUnsavedChanges && copy.database.isOpen, "with the edits kept and the copy still open")
        copy.discard()
    }

    // discarding, and sweeping old working folders
    do {
        let s = Scratch("wc-discard")
        guard let original = makeLeftoverWALDatabase(s) else { T.check(false, "set-up"); return }
        s.mkdir("tmp")
        let copy = try? SQLiteWorkingCopy.open(original: original, files: files, temporaryDirectory: URL(fileURLWithPath: s.path("tmp")), retryDelay: 0)
        T.check(!names(in: s.path("tmp")).isEmpty, "an open copy has a folder")
        copy?.discard()
        T.check(names(in: s.path("tmp")).isEmpty, "discarding removes it")
        s.mkdir("tmp/escapeos-db-OLD")
        s.write("tmp/escapeos-db-OLD/x.db", bytes: 10)
        s.mkdir("tmp/escapeos-drop-KEEP")
        SQLiteWorkingCopy.sweepLeftovers(in: URL(fileURLWithPath: s.path("tmp")))
        T.check(!s.exists("tmp/escapeos-db-OLD"), "a working folder left by an earlier run is swept")
        T.check(s.exists("tmp/escapeos-drop-KEEP"), "another feature's folder is not")
    }
}
