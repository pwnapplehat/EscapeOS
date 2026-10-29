import Foundation

private let appRef = { (container: String) in
    TrashSource(bundleIdentifier: "com.example.app", appName: "Example", containerPath: container)
}

/// Writes a record file the way the store does, so recovery can be tested against states a crash
/// would leave behind.
private func writeRecord(_ record: TrashRecord, root: String) {
    let folder = (root as NSString).appendingPathComponent(record.id)
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(record) {
        FileManager.default.createFile(atPath: (folder as NSString).appendingPathComponent(TrashStore.recordFileName), contents: data)
    }
}

private func sampleRecord(id: String = UUID().uuidString, state: TrashRecord.State, bytes: Int64 = 10, entries: Int = 1) -> TrashRecord {
    TrashRecord(
        id: id, name: "x.txt", storedName: "x.txt", isDirectory: false, bytes: bytes, entryCount: entries,
        deletedAt: Date(timeIntervalSince1970: 1_700_000_000), bundleIdentifier: "com.example.app", appName: "Example",
        relativePath: "Documents/x.txt", originalPath: "/gone/Documents/x.txt", reason: nil, state: state
    )
}

func runTrashStoreTests() {
    T.section("TrashStore")
    let files = FileService()
    let chunk = 4096
    var clockTick = 0.0
    let tickingClock: () -> Date = {
        clockTick += 1
        return Date(timeIntervalSince1970: 1_700_000_000 + clockTick)
    }

    // moving a file in
    do {
        let s = Scratch("trash-file")
        s.write("C/Documents/notes/a.txt", text: "hello trash")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")), now: tickingClock)
        let item = testItem(s, "C/Documents/notes/a.txt")
        let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C")), reason: "Deleted in EscapeOS")
        T.check(record != nil, "a file moves to the Trash")
        T.equal(record?.name ?? "", "a.txt", "the name is kept")
        T.equal(record?.relativePath ?? "", "Documents/notes/a.txt", "where it was is recorded from the container, not as a device path")
        T.equal(record?.parentRelativePath ?? "", "Documents/notes", "the folder it was in")
        T.equal(record?.bytes ?? -1, 11, "its size is recorded")
        T.equal(record?.entryCount ?? -1, 1, "a file is one entry")
        T.equal(record?.state, .ready, "it is ready to restore")
        T.equal(record?.bundleIdentifier ?? "", "com.example.app", "the app it came from is recorded")
        T.equal(record?.appName ?? "", "Example", "and its name")
        T.equal(record?.reason ?? "", "Deleted in EscapeOS", "and why")
        T.check(!s.exists("C/Documents/notes/a.txt"), "the original is gone from the app")
        T.check(s.exists("C/Documents/notes"), "its folder is left in place")
        if let record {
            T.equal(FileManager.default.contents(atPath: store.payloadURL(for: record).path), Data("hello trash".utf8), "the content is in the Trash")
            T.equal(store.records().map(\.id), [record.id], "it is listed")
            T.equal(store.totalBytes(), 11, "the Trash reports its size")
        }
    }

    // moving a folder in
    do {
        let s = Scratch("trash-folder")
        s.write("C/Documents/proj/one.txt", text: "1")
        s.write("C/Documents/proj/sub/two.bin", bytes: 5_000)
        s.mkdir("C/Documents/proj/empty")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let item = testItem(s, "C/Documents/proj")
        let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: true, from: appRef(s.path("C")))
        T.equal(record?.isDirectory, true, "a folder is marked as one")
        T.equal(record?.bytes ?? -1, 5_001, "a folder's size is its content")
        T.equal(record?.entryCount ?? -1, 5, "the folder itself, two folders and two files are counted")
        T.check(!s.exists("C/Documents/proj"), "the folder is gone from the app")
        if let record {
            let payload = store.payloadURL(for: record).path
            T.equal(FileManager.default.contents(atPath: payload + "/sub/two.bin")?.count ?? -1, 5_000, "its contents are intact in the Trash")
            T.check(files.isDirectory(at: payload + "/empty"), "an empty folder inside is kept")
        }
    }

    // only what is inside the app's data may be moved
    do {
        let s = Scratch("trash-guard")
        s.write("C/Documents/ok.txt", text: "ok")
        s.write("elsewhere/secret.txt", text: "not yours")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let app = appRef(s.path("C"))
        var error: TrashError?
        do { _ = try store.moveToTrash(path: s.path("elsewhere/secret.txt"), name: "secret.txt", isDirectory: false, from: app) }
        catch let e as TrashError { error = e } catch {}
        T.equal(error, .outsideContainer("secret.txt"), "a path outside the container is refused")
        T.check(s.exists("elsewhere/secret.txt"), "and left where it was")
        error = nil
        do { _ = try store.moveToTrash(path: s.path("C"), name: "C", isDirectory: true, from: app) }
        catch let e as TrashError { error = e } catch {}
        T.equal(error, .outsideContainer("C"), "the container itself cannot be trashed")
        error = nil
        do { _ = try store.moveToTrash(path: s.path("C/Documents/../../elsewhere/secret.txt"), name: "secret.txt", isDirectory: false, from: app) }
        catch let e as TrashError { error = e } catch {}
        T.equal(error, .outsideContainer("secret.txt"), "dot-dot cannot climb out of the container")
        T.check(s.exists("elsewhere/secret.txt"), "the file outside is still there")
        T.equal(store.records().count, 0, "nothing was added")
        let sibling = Scratch("trash-sibling")
        sibling.write("C2/x.txt", text: "x")
        error = nil
        do { _ = try store.moveToTrash(path: sibling.path("C2/x.txt"), name: "x.txt", isDirectory: false, from: appRef(sibling.path("C"))) }
        catch let e as TrashError { error = e } catch {}
        T.equal(error, .outsideContainer("x.txt"), "a folder whose name merely starts like the container's is not inside it")
    }

    // a missing item
    do {
        let s = Scratch("trash-missing")
        s.mkdir("C/Documents")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        var error: TrashError?
        do { _ = try store.moveToTrash(path: s.path("C/Documents/gone.txt"), name: "gone.txt", isDirectory: false, from: appRef(s.path("C"))) }
        catch let e as TrashError { error = e } catch {}
        T.equal(error, .missing("gone.txt"), "an item that is not there is reported, not half-recorded")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: s.path("trash"))) ?? []
        T.check(left.isEmpty, "and leaves nothing behind in the Trash (\(left))")
    }

    // the same name twice, and awkward names
    do {
        let s = Scratch("trash-names")
        s.write("C/Documents/a/same.txt", text: "first")
        s.write("C/Documents/b/same.txt", text: "second")
        s.write("C/Documents/odd:name.txt", text: "odd")
        s.write("C/Documents/.hidden", text: "dot")
        s.write("C/Documents/ünï cødé.txt", text: "unicode")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let app = appRef(s.path("C"))
        var ids: [String] = []
        for rel in ["C/Documents/a/same.txt", "C/Documents/b/same.txt", "C/Documents/odd:name.txt", "C/Documents/.hidden", "C/Documents/ünï cødé.txt"] {
            let item = testItem(s, rel)
            if let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: app) { ids.append(record.id) }
        }
        T.equal(ids.count, 5, "all five are moved in")
        T.equal(Set(ids).count, 5, "each gets its own folder, so equal names do not collide")
        let records = store.records()
        let first = records.first { $0.relativePath == "Documents/a/same.txt" }
        let second = records.first { $0.relativePath == "Documents/b/same.txt" }
        T.equal(first.flatMap { FileManager.default.contents(atPath: store.payloadURL(for: $0).path) }, Data("first".utf8), "the first same-named file kept its own content")
        T.equal(second.flatMap { FileManager.default.contents(atPath: store.payloadURL(for: $0).path) }, Data("second".utf8), "the second kept its own")
        let odd = records.first { $0.name == "odd:name.txt" }
        T.equal(odd?.storedName ?? "", "odd-name.txt", "a colon in the name is replaced in the stored name")
        T.equal(odd?.name ?? "", "odd:name.txt", "but the real name is remembered for restore")
        T.check(records.contains { $0.name == ".hidden" }, "a dotfile is trashed like any other")
        T.check(records.contains { $0.name == "ünï cødé.txt" }, "and so is a name with accents")
    }

    // keeping a copy of something that is not being deleted
    do {
        let s = Scratch("trash-keepcopy")
        s.write("elsewhere/app.sqlite", bytes: 3 * chunk)
        s.mkdir("C/Documents/db")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")), now: tickingClock)
        var counted: Int64 = 0
        let record = try? store.keepCopy(
            of: s.path("elsewhere/app.sqlite"), name: "app.sqlite", restoringTo: "Documents/db/app.sqlite",
            from: appRef(s.path("C")), reason: "Kept before saving an edit",
            observer: TransferObserver(bytes: { counted += $0 }), chunkSize: chunk
        )
        T.check(record != nil, "a copy is kept")
        T.check(s.exists("elsewhere/app.sqlite"), "the source is left where it was")
        T.equal(counted, Int64(3 * chunk), "its progress is reported")
        T.equal(record?.relativePath ?? "", "Documents/db/app.sqlite", "it will restore to the given place in the app")
        T.equal(record?.reason ?? "", "Kept before saving an edit", "with the reason shown")
        T.equal(record?.state, .ready, "and is ready")
        T.equal(record?.bytes ?? -1, Int64(3 * chunk), "with its size")
        if let record {
            T.equal(FileManager.default.contents(atPath: store.payloadURL(for: record).path)?.count ?? -1, 3 * chunk, "the copy is complete")
            let restored = try? store.restore(record, toContainer: s.path("C"))
            T.equal(restored?.path ?? "", s.path("C/Documents/db/app.sqlite"), "restoring puts it at that place")
            T.equal(restored?.renamed, false, "under its own name")
        }
        var refused = false
        do { _ = try store.keepCopy(of: s.path("elsewhere/app.sqlite"), name: "x", restoringTo: "../out", from: appRef(s.path("C")), reason: "r") } catch { refused = true }
        T.check(refused, "a location that climbs out of the app is refused")
        var missing: TrashError?
        do { _ = try store.keepCopy(of: s.path("elsewhere/gone"), name: "gone", restoringTo: "Documents/gone", from: appRef(s.path("C")), reason: "r") }
        catch let e as TrashError { missing = e } catch {}
        T.equal(missing, .missing("gone"), "a missing source is reported")
        var seen: Int64 = 0
        var cancelled = false
        do {
            _ = try store.keepCopy(
                of: s.path("elsewhere/app.sqlite"), name: "app.sqlite", restoringTo: "Documents/db/app.sqlite", from: appRef(s.path("C")), reason: "r",
                observer: TransferObserver(bytes: { seen += $0 }, isCancelled: { seen >= Int64(chunk) }), chunkSize: chunk
            )
        } catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a cancelled copy surfaces as JobCancelled")
        T.check(s.exists("elsewhere/app.sqlite"), "and the source is still there")
        T.equal(store.records().count, 0, "with nothing half-made in the Trash")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: s.path("trash"))) ?? ["?"]
        T.check(left.isEmpty, "not even an empty folder (\(left))")
    }

    // newest first
    do {
        let s = Scratch("trash-order")
        for name in ["a", "b", "c"] { s.write("C/Documents/\(name).txt", text: name) }
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")), now: tickingClock)
        for name in ["a", "b", "c"] {
            let item = testItem(s, "C/Documents/\(name).txt")
            _ = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C")))
        }
        T.equal(store.records().map(\.name), ["c.txt", "b.txt", "a.txt"], "the most recently deleted is first")
        T.equal(store.records(forBundleIdentifier: "com.example.app").count, 3, "listing by app finds them")
        T.equal(store.records(forBundleIdentifier: "com.other").count, 0, "and not another app's")
    }

    // restoring
    do {
        let s = Scratch("trash-restore")
        s.write("C/Documents/notes/a.txt", text: "bring me back")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let item = testItem(s, "C/Documents/notes/a.txt")
        guard let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C"))) else {
            T.check(false, "set-up: trash the file"); return
        }
        let restored = try? store.restore(record, toContainer: s.path("C"))
        T.equal(restored?.path ?? "", s.path("C/Documents/notes/a.txt"), "it comes back to the same place")
        T.equal(restored?.renamed, false, "under its own name")
        T.equal(s.read("C/Documents/notes/a.txt"), Data("bring me back".utf8), "with its content")
        T.equal(store.records().count, 0, "it leaves the Trash")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: s.path("trash"))) ?? ["?"]
        T.check(left.isEmpty, "and its folder is cleaned up (\(left))")
    }

    // restoring when the app was reinstalled and its container moved
    do {
        let s = Scratch("trash-reinstall")
        s.write("OLD/Documents/keep.txt", text: "survives a reinstall")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let item = testItem(s, "OLD/Documents/keep.txt")
        guard let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("OLD"))) else {
            T.check(false, "set-up"); return
        }
        s.mkdir("NEW/Documents")
        let restored = try? store.restore(record, toContainer: s.path("NEW"))
        T.equal(restored?.path ?? "", s.path("NEW/Documents/keep.txt"), "it goes into the app's current container")
        T.equal(s.read("NEW/Documents/keep.txt"), Data("survives a reinstall".utf8), "with its content")
    }

    // restoring when the name is taken: nothing is replaced
    do {
        let s = Scratch("trash-collide")
        s.write("C/Documents/a.txt", text: "old version")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let item = testItem(s, "C/Documents/a.txt")
        guard let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C"))) else {
            T.check(false, "set-up"); return
        }
        s.write("C/Documents/a.txt", text: "newer file made since")
        let restored = try? store.restore(record, toContainer: s.path("C"))
        T.equal(restored?.renamed, true, "the result says it came back under a new name")
        T.equal(restored?.path ?? "", s.path("C/Documents/a 2.txt"), "as 'a 2.txt'")
        T.equal(s.read("C/Documents/a.txt"), Data("newer file made since".utf8), "the file that was there is untouched")
        T.equal(s.read("C/Documents/a 2.txt"), Data("old version".utf8), "the restored one has the old content")
    }

    // restoring when the folder it was in is gone
    do {
        let s = Scratch("trash-parent")
        s.write("C/Documents/deep/er/file.txt", text: "x")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let item = testItem(s, "C/Documents/deep/er/file.txt")
        guard let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C"))) else {
            T.check(false, "set-up"); return
        }
        try? FileManager.default.removeItem(atPath: s.path("C/Documents/deep"))
        let restored = try? store.restore(record, toContainer: s.path("C"))
        T.equal(restored?.path ?? "", s.path("C/Documents/deep/er/file.txt"), "the missing folders are recreated")
        T.equal(s.read("C/Documents/deep/er/file.txt"), Data("x".utf8), "and the file is back in them")
    }

    // a damaged or hostile record cannot send an item outside the container
    do {
        let s = Scratch("trash-hostile")
        s.write("C/Documents/a.txt", text: "a")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let item = testItem(s, "C/Documents/a.txt")
        guard let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C"))) else {
            T.check(false, "set-up"); return
        }
        for bad in ["../escape.txt", "/abs/escape.txt", "Documents/../../escape.txt", "", "Documents//a.txt"] {
            var tampered = record
            tampered.relativePath = bad
            var refused = false
            do { _ = try store.restore(tampered, toContainer: s.path("C")) } catch { refused = true }
            T.check(refused, "a location of '\(bad)' is refused")
        }
        T.check(!s.exists("escape.txt"), "nothing was written outside the container")
        T.equal(store.records().count, 1, "and the item is still in the Trash")
        var notReady = record
        notReady.state = .moving
        var refused = false
        do { _ = try store.restore(notReady, toContainer: s.path("C")) } catch { refused = true }
        T.check(refused, "an item that is still being moved cannot be restored")
    }

    // restoring something whose payload has gone
    do {
        let s = Scratch("trash-lost")
        s.write("C/Documents/a.txt", text: "a")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let item = testItem(s, "C/Documents/a.txt")
        guard let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C"))) else {
            T.check(false, "set-up"); return
        }
        try? FileManager.default.removeItem(at: store.payloadURL(for: record))
        T.equal(store.records().count, 0, "an entry whose item was removed in Files is not listed")
        var error: TrashError?
        do { _ = try store.restore(record, toContainer: s.path("C")) } catch let e as TrashError { error = e } catch {}
        T.equal(error, .missing("a.txt"), "restoring it says it is gone")
    }

    // deleting for good, and emptying
    do {
        let s = Scratch("trash-empty")
        for name in ["a", "b", "c"] { s.write("C/Documents/\(name).txt", text: name) }
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        var made: [TrashRecord] = []
        for name in ["a", "b", "c"] {
            let item = testItem(s, "C/Documents/\(name).txt")
            if let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C"))) { made.append(record) }
        }
        try? store.deletePermanently(made[0])
        T.equal(store.records().count, 2, "deleting one for good removes just that one")
        T.check(!s.exists("trash/\(made[0].id)"), "and its folder")
        s.write("trash/stray-folder/leftover.txt", text: "unrecognised")
        let removed = (try? store.empty()) ?? -1
        T.equal(removed, 2, "emptying reports the items it removed")
        T.equal(store.records().count, 0, "the Trash is empty")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: s.path("trash"))) ?? ["?"]
        T.check(left.isEmpty, "emptying also clears anything unrecognised in it (\(left))")
        T.equal((try? store.empty()) ?? -1, 0, "emptying an empty Trash is fine")
        T.equal(store.totalBytes(), 0, "and it reports no size")
    }

    // an item that will not delete does not stop the rest
    if !runningAsRoot {
        let s = Scratch("trash-stuck")
        for name in ["a", "b"] { s.write("C/Documents/\(name).txt", text: name) }
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        var made: [TrashRecord] = []
        for name in ["a", "b"] {
            let item = testItem(s, "C/Documents/\(name).txt")
            if let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C"))) { made.append(record) }
        }
        let stuckFolder = s.path("trash/\(made[0].id)")
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuckFolder)
        var message = ""
        do { _ = try store.empty() } catch { message = error.localizedDescription }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuckFolder)
        T.check(message.contains("1 item could not be deleted"), "emptying says what it could not remove (\(message))")
        T.check(!s.exists("trash/\(made[1].id)"), "the other item was still removed")
    }

    // the copy-and-delete route, used when a rename is not possible
    do {
        let s = Scratch("trash-copy")
        s.write("C/Documents/big.bin", bytes: 5 * chunk)
        s.write("C/Documents/dir/x.txt", text: "x")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")), renamer: { _, _ in false })
        var counted: Int64 = 0
        let observer = TransferObserver(bytes: { counted += $0 })
        let item = testItem(s, "C/Documents/big.bin")
        let record = try? store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C")), observer: observer, chunkSize: chunk)
        T.check(record != nil, "an item moves in by copy when it cannot be renamed")
        T.equal(counted, Int64(5 * chunk), "its progress is reported")
        T.check(!s.exists("C/Documents/big.bin"), "the original is removed after the copy")
        if let record {
            T.equal(FileManager.default.contents(atPath: store.payloadURL(for: record).path)?.count ?? -1, 5 * chunk, "the copy is complete")
            let restored = try? store.restore(record, toContainer: s.path("C"), observer: observer, chunkSize: chunk)
            T.equal(restored?.path ?? "", s.path("C/Documents/big.bin"), "and it restores by copy too")
            T.equal(s.read("C/Documents/big.bin")?.count ?? -1, 5 * chunk, "with all its content")
            T.equal(store.records().count, 0, "and leaves the Trash")
        }
    }

    // cancelling a copy leaves the item where it was and nothing in the Trash
    do {
        let s = Scratch("trash-cancel")
        s.write("C/Documents/big.bin", bytes: 8 * chunk)
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")), renamer: { _, _ in false })
        var seen: Int64 = 0
        let observer = TransferObserver(bytes: { seen += $0 }, isCancelled: { seen >= Int64(2 * chunk) })
        let item = testItem(s, "C/Documents/big.bin")
        var cancelled = false
        do { _ = try store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C")), observer: observer, chunkSize: chunk) }
        catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a cancel surfaces as JobCancelled")
        T.equal(s.read("C/Documents/big.bin")?.count ?? -1, 8 * chunk, "the original is intact")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: s.path("trash"))) ?? ["?"]
        T.check(left.isEmpty, "and no half-copy is left in the Trash (\(left))")
        T.equal(store.records().count, 0, "nothing is listed")
    }

    // a cancel requested before anything starts moves nothing
    do {
        let s = Scratch("trash-precancel")
        s.write("C/Documents/a.txt", text: "a")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let item = testItem(s, "C/Documents/a.txt")
        var cancelled = false
        do { _ = try store.moveToTrash(path: item.path, name: item.name, isDirectory: false, from: appRef(s.path("C")), observer: TransferObserver(isCancelled: { true })) }
        catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "an early cancel is honoured")
        T.check(s.exists("C/Documents/a.txt"), "and the item stays put")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: s.path("trash"))) ?? ["?"]
        T.check(left.isEmpty, "with no folder left in the Trash (\(left))")
    }

    // a symlink is trashed and restored as a link
    do {
        let s = Scratch("trash-link")
        s.mkdir("C/Documents")
        try? FileManager.default.createSymbolicLink(atPath: s.path("C/Documents/link"), withDestinationPath: "nowhere/at/all")
        let store = TrashStore(root: URL(fileURLWithPath: s.path("trash")))
        let record = try? store.moveToTrash(path: s.path("C/Documents/link"), name: "link", isDirectory: false, from: appRef(s.path("C")))
        T.check(record != nil, "a dangling link can be trashed")
        T.equal(record?.bytes ?? -1, 0, "it has no content")
        T.check(!files.isSymlink(at: s.path("C/Documents/link")), "and is gone from the app")
        if let record {
            _ = try? store.restore(record, toContainer: s.path("C"))
            T.equal(try? FileManager.default.destinationOfSymbolicLink(atPath: s.path("C/Documents/link")), "nowhere/at/all", "it comes back as the same link")
        }
    }

    // recovery after a crash
    do {
        let s = Scratch("trash-recover")
        let root = s.path("trash")
        let store = TrashStore(root: URL(fileURLWithPath: root))

        let complete = sampleRecord(state: .moving, bytes: 10, entries: 1)
        writeRecord(complete, root: root)
        s.write("trash/\(complete.id)/x.txt", bytes: 10)

        let partial = sampleRecord(state: .moving, bytes: 1_000, entries: 1)
        writeRecord(partial, root: root)
        s.write("trash/\(partial.id)/x.txt", bytes: 400)

        let nothing = sampleRecord(state: .moving)
        writeRecord(nothing, root: root)

        let vanished = sampleRecord(state: .ready)
        writeRecord(vanished, root: root)

        let healthy = sampleRecord(state: .ready, bytes: 10, entries: 1)
        writeRecord(healthy, root: root)
        s.write("trash/\(healthy.id)/x.txt", bytes: 10)

        s.mkdir("trash/empty-folder")
        s.write("trash/unrecognised/data.txt", text: "someone's file with no record")

        T.equal(store.records().map(\.id), [healthy.id], "before recovery only the healthy item is listed")
        store.recoverInterrupted()

        let ids = Set(store.records().map(\.id))
        T.check(ids.contains(complete.id), "a complete payload is promoted to ready")
        T.check(store.records().first { $0.id == complete.id }?.reason == nil, "and not flagged")
        T.check(ids.contains(partial.id), "a payload that does not match is kept, not deleted")
        T.equal(store.records().first { $0.id == partial.id }?.reason ?? "", TrashStore.interruptedReason, "but flagged as possibly incomplete")
        T.check(!s.exists("trash/\(nothing.id)"), "an entry with no payload is removed")
        T.check(!s.exists("trash/\(vanished.id)"), "a ready entry whose payload is gone is removed")
        T.check(ids.contains(healthy.id), "a healthy item is untouched")
        T.check(!s.exists("trash/empty-folder"), "an empty folder is removed")
        T.check(s.exists("trash/unrecognised/data.txt"), "a folder with content but no record is never deleted")
        T.equal(s.read("trash/\(partial.id)/x.txt")?.count ?? -1, 400, "and the kept partial payload is untouched")
        store.recoverInterrupted()
        T.equal(Set(store.records().map(\.id)), ids, "running recovery again changes nothing")
    }

    // a record that does not belong to its folder is ignored
    do {
        let s = Scratch("trash-mismatch")
        let root = s.path("trash")
        let record = sampleRecord(state: .ready)
        writeRecord(record, root: root)
        s.write("trash/\(record.id)/x.txt", bytes: 10)
        try? FileManager.default.moveItem(atPath: s.path("trash/\(record.id)"), toPath: s.path("trash/renamed-folder"))
        let store = TrashStore(root: URL(fileURLWithPath: root))
        T.equal(store.records().count, 0, "a record whose id does not match its folder is not trusted")
        try? Data("{not json".utf8).write(to: URL(fileURLWithPath: s.path("trash/renamed-folder/\(TrashStore.recordFileName)")))
        T.equal(store.records().count, 0, "a damaged record is ignored rather than crashing")
    }

    // helpers
    do {
        T.equal(TrashStore.relativePath(of: "/c/Documents/a/b.txt", in: "/c"), "Documents/a/b.txt", "relative path inside the container")
        T.equal(TrashStore.relativePath(of: "/var/x/C/Documents/a", in: "/private/var/x/C"), "Documents/a", "/var and /private/var agree")
        T.check(TrashStore.relativePath(of: "/c", in: "/c") == nil, "the container itself has no relative path")
        T.check(TrashStore.relativePath(of: "/c2/a", in: "/c") == nil, "a sibling with the same prefix is outside")
        T.check(TrashStore.relativePath(of: "/c/a", in: "/") == nil, "an empty container path matches nothing")
        T.check(TrashStore.isSafeRelative("Documents/a.txt"), "a normal relative path is safe")
        T.check(!TrashStore.isSafeRelative(""), "empty is not safe")
        T.check(!TrashStore.isSafeRelative("/abs"), "absolute is not safe")
        T.check(!TrashStore.isSafeRelative("a/../b"), "dot-dot is not safe")
        T.check(!TrashStore.isSafeRelative("a//b"), "an empty component is not safe")
        let suite = UserDefaults(suiteName: "escapeos-trash-tests-\(UUID().uuidString)")!
        T.check(TrashPreference.isEnabled(in: suite), "the Trash is on by default")
        TrashPreference.setEnabled(false, in: suite)
        T.check(!TrashPreference.isEnabled(in: suite), "and can be turned off")
        TrashPreference.setEnabled(true, in: suite)
        T.check(TrashPreference.isEnabled(in: suite), "and back on")
    }
}
