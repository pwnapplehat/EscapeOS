import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
import CXattr
#endif

/// Makes a scratch folder for one test and removes it afterwards.
final class Scratch {
    let root: String
    private let fm = FileManager.default

    init(_ label: String = "scratch") {
        root = fm.temporaryDirectory.appendingPathComponent("escapeos-\(label)-\(UUID().uuidString)").path
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        // Folders a test made read-only must be writable again before they can be removed.
        makeWritable(root)
        try? fm.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String { (root as NSString).appendingPathComponent(relative) }

    @discardableResult
    func write(_ relative: String, bytes: Int = 0, fill: UInt8 = 0x41, text: String? = nil) -> String {
        let full = path(relative)
        try? fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = text.map { Data($0.utf8) } ?? Data((0..<bytes).map { UInt8(truncatingIfNeeded: Int(fill) &+ $0 % 251) })
        fm.createFile(atPath: full, contents: data)
        return full
    }

    func mkdir(_ relative: String) {
        try? fm.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func read(_ relative: String) -> Data? { fm.contents(atPath: path(relative)) }
    func exists(_ relative: String) -> Bool { fm.fileExists(atPath: path(relative)) }

    private func makeWritable(_ dir: String) {
        guard let walker = fm.enumerator(atPath: dir) else { return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        while let relative = walker.nextObject() as? String {
            let full = (dir as NSString).appendingPathComponent(relative)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full)
        }
    }
}

/// A `FileItem` for something in a scratch folder, read from disk.
func testItem(_ s: Scratch, _ relative: String, files: FileService = FileService()) -> FileItem {
    let path = s.path(relative)
    let isDirectory = files.isDirectory(at: path)
    let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    return FileItem(
        name: (path as NSString).lastPathComponent,
        path: path,
        kind: isDirectory ? .directory : .regular,
        size: size,
        modified: nil,
        isReadable: true,
        isWritable: true
    )
}

/// Running as root ignores file permissions, which would make the permission tests pass for the
/// wrong reason, so they are skipped there.
let runningAsRoot = geteuid() == 0

func runFileTransferTests() {
    T.section("FileTransfer")
    let files = FileService()
    let chunk = 4096

    // a file is copied byte for byte, at every size around a chunk boundary
    for size in [0, 1, chunk - 1, chunk, chunk + 1, 3 * chunk + 7] {
        let s = Scratch("copy-file")
        let src = s.write("a.bin", bytes: size)
        var counted: Int64 = 0
        let observer = TransferObserver(bytes: { counted += $0 })
        let copied = (try? files.copyTree(from: src, to: s.path("b.bin"), observer: observer, chunkSize: chunk)) ?? -1
        T.equal(s.read("b.bin"), s.read("a.bin"), "a \(size)-byte file is copied exactly")
        T.equal(copied, Int64(size), "the byte count returned for \(size) bytes")
        T.equal(counted, Int64(size), "the bytes reported for \(size) bytes")
    }

    // a folder tree: nested files, an empty folder, and the observer sees every byte
    do {
        let s = Scratch("copy-tree")
        s.write("src/top.txt", text: "top")
        s.write("src/a/b/deep.bin", bytes: 10_000)
        s.write("src/a/other.bin", bytes: 5_000)
        s.mkdir("src/empty/inside")
        var counted: Int64 = 0
        var names: [String] = []
        let observer = TransferObserver(bytes: { counted += $0 }, detail: { names.append($0) })
        let copied = (try? files.copyTree(from: s.path("src"), to: s.path("dst"), observer: observer, chunkSize: chunk)) ?? -1
        T.equal(copied, 3 + 10_000 + 5_000, "the tree's byte total")
        T.equal(counted, copied, "the observer saw every byte once")
        T.equal(s.read("dst/top.txt"), s.read("src/top.txt"), "top file copied")
        T.equal(s.read("dst/a/b/deep.bin"), s.read("src/a/b/deep.bin"), "deep file copied")
        T.check(files.isDirectory(at: s.path("dst/empty/inside")), "an empty folder is kept")
        T.check(Set(names) == ["top.txt", "deep.bin", "other.bin"], "each file is named as it is copied")
        T.check(s.exists("src/a/b/deep.bin"), "a copy leaves the original alone")
    }

    // a symlink is recreated, never followed
    do {
        let s = Scratch("copy-link")
        s.write("src/real/big.bin", bytes: 20_000)
        try? FileManager.default.createSymbolicLink(atPath: s.path("src/link-to-dir"), withDestinationPath: s.path("src/real"))
        try? FileManager.default.createSymbolicLink(atPath: s.path("src/link-to-file"), withDestinationPath: "real/big.bin")
        try? FileManager.default.createSymbolicLink(atPath: s.path("src/dangling"), withDestinationPath: "nowhere")
        var counted: Int64 = 0
        let observer = TransferObserver(bytes: { counted += $0 })
        let ok = (try? files.copyTree(from: s.path("src"), to: s.path("dst"), observer: observer, chunkSize: chunk)) != nil
        T.check(ok, "a tree with links copies")
        T.equal(counted, 20_000, "the target behind a link is not copied a second time")
        T.check(files.isSymlink(at: s.path("dst/link-to-dir")), "a link to a folder stays a link")
        T.equal(
            try? FileManager.default.destinationOfSymbolicLink(atPath: s.path("dst/link-to-file")),
            "real/big.bin",
            "a relative link keeps its target text"
        )
        T.check(files.isSymlink(at: s.path("dst/dangling")), "a dangling link is copied as a link")
        T.check(!files.isDirectory(at: s.path("dst/link-to-dir")) || files.isSymlink(at: s.path("dst/link-to-dir")), "a linked folder is not expanded")
    }

    // a link that points back up the tree cannot make the copy endless
    do {
        let s = Scratch("copy-loop")
        s.write("src/file.txt", text: "x")
        try? FileManager.default.createSymbolicLink(atPath: s.path("src/up"), withDestinationPath: s.path("src"))
        let ok = (try? files.copyTree(from: s.path("src"), to: s.path("dst"))) != nil
        T.check(ok, "a self-referencing link copies without looping")
        T.check(files.isSymlink(at: s.path("dst/up")), "and stays a link")
    }

    // permissions and modification time survive
    do {
        let s = Scratch("copy-attrs")
        let src = s.write("run.sh", text: "#!/bin/sh\n")
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: stamp], ofItemAtPath: src)
        _ = try? files.copyTree(from: src, to: s.path("copy.sh"))
        let attrs = try? FileManager.default.attributesOfItem(atPath: s.path("copy.sh"))
        T.equal((attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1, 0o755, "the executable bit is kept")
        T.equal((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1, 1_500_000_000, "the modification time is kept")
    }

    // extended attributes survive (iOS keeps "do not back up" in one)
    do {
        let s = Scratch("copy-xattr")
        let src = s.write("src/cache.dat", text: "cached")
        s.mkdir("src/dir")
        let value = Array("keep me".utf8)
        #if canImport(Darwin)
        let setFile = setxattr(src, "com.apple.MobileBackup", value, value.count, 0, 0)
        let setDir = setxattr(s.path("src/dir"), "com.apple.MobileBackup", value, value.count, 0, 0)
        #else
        let setFile = setxattr(src, "user.escapeos.test", value, value.count, 0)
        let setDir = setxattr(s.path("src/dir"), "user.escapeos.test", value, value.count, 0)
        #endif
        if setFile == 0 && setDir == 0 {
            _ = try? files.copyTree(from: s.path("src"), to: s.path("dst"), chunkSize: chunk)
            func read(_ path: String) -> String? {
                var buffer = [UInt8](repeating: 0, count: 64)
                #if canImport(Darwin)
                let length = getxattr(path, "com.apple.MobileBackup", &buffer, buffer.count, 0, 0)
                #else
                let length = getxattr(path, "user.escapeos.test", &buffer, buffer.count)
                #endif
                return length < 0 ? nil : String(decoding: buffer[0..<length], as: UTF8.self)
            }
            T.equal(read(s.path("dst/cache.dat")) ?? "<none>", "keep me", "a file's extended attribute is copied")
            T.equal(read(s.path("dst/dir")) ?? "<none>", "keep me", "and a folder's")
        } else {
            print("  (extended attributes not supported on this volume; check skipped)")
        }
    }

    // refusing to overwrite
    do {
        let s = Scratch("copy-exists")
        let src = s.write("a.txt", text: "new")
        s.write("b.txt", text: "precious")
        var failed = false
        do { _ = try files.copyTree(from: src, to: s.path("b.txt")) } catch { failed = true }
        T.check(failed, "copying onto an existing file is refused")
        T.equal(s.read("b.txt"), Data("precious".utf8), "and the existing file is untouched")
        s.mkdir("folder")
        failed = false
        do { _ = try files.copyTree(from: src, to: s.path("folder")) } catch { failed = true }
        T.check(failed, "copying onto an existing folder is refused")
        try? FileManager.default.createSymbolicLink(atPath: s.path("link"), withDestinationPath: "nowhere")
        failed = false
        do { _ = try files.copyTree(from: src, to: s.path("link")) } catch { failed = true }
        T.check(failed, "copying onto a dangling link is refused too")
    }

    // a missing source
    do {
        let s = Scratch("copy-missing")
        var failed = false
        do { _ = try files.copyTree(from: s.path("nope"), to: s.path("dst")) } catch { failed = true }
        T.check(failed, "a missing source is an error")
        T.check(!s.exists("dst"), "and leaves no destination behind")
    }

    // cancelling in the middle of a file leaves nothing
    do {
        let s = Scratch("cancel-file")
        let src = s.write("big.bin", bytes: 10 * chunk)
        var seen: Int64 = 0
        let observer = TransferObserver(bytes: { seen += $0 }, isCancelled: { seen >= Int64(3 * chunk) })
        var cancelled = false
        do { _ = try files.copyTree(from: src, to: s.path("copy.bin"), observer: observer, chunkSize: chunk) }
        catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a cancel surfaces as JobCancelled")
        T.check(!s.exists("copy.bin"), "a half-copied file is removed")
        T.equal(seen, Int64(3 * chunk), "it stopped at the next chunk boundary, not later")
        T.check(s.exists("big.bin"), "the original is untouched")
    }

    // cancelling between files in a tree removes the partial tree
    do {
        let s = Scratch("cancel-tree")
        for index in 0..<5 { s.write("src/f\(index).bin", bytes: 2 * chunk) }
        var seen: Int64 = 0
        let observer = TransferObserver(bytes: { seen += $0 }, isCancelled: { seen >= Int64(4 * chunk) })
        var cancelled = false
        do { _ = try files.copyTree(from: s.path("src"), to: s.path("dst"), observer: observer, chunkSize: chunk) }
        catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "cancelling a tree copy surfaces as JobCancelled")
        T.check(!s.exists("dst"), "the partial tree is gone entirely")
        for index in 0..<5 { T.check(s.exists("src/f\(index).bin"), "source file \(index) is untouched") }
    }

    // a cancel that is already set stops before anything is written
    do {
        let s = Scratch("cancel-first")
        let src = s.write("a.bin", bytes: 100)
        var cancelled = false
        do { _ = try files.copyTree(from: src, to: s.path("b.bin"), observer: TransferObserver(isCancelled: { true })) }
        catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a cancel already requested is honoured")
        T.check(!s.exists("b.bin"), "and nothing was written")
    }

    // an unreadable file stops the copy and removes it
    if !runningAsRoot {
        let s = Scratch("unreadable")
        s.write("src/ok.txt", text: "ok")
        let locked = s.write("src/locked.txt", text: "secret")
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        var failed = false
        do { _ = try files.copyTree(from: s.path("src"), to: s.path("dst")) } catch { failed = true }
        T.check(failed, "a file that cannot be read fails the copy, not silently skips it")
        T.check(!s.exists("dst"), "and the partial copy is removed")
    }

    // MARK: move

    // same-volume move is a rename: instant, nothing counted
    do {
        let s = Scratch("move-rename")
        s.write("src/a.txt", text: "hello")
        var counted: Int64 = 0
        let moved = (try? files.moveTree(from: s.path("src"), to: s.path("dst"), observer: TransferObserver(bytes: { counted += $0 }))) ?? -1
        T.equal(moved, 0, "a rename reports no bytes copied")
        T.equal(counted, 0, "and the observer is not told of any")
        T.check(!s.exists("src"), "the source is gone")
        T.equal(s.read("dst/a.txt"), Data("hello".utf8), "the content is at the destination")
    }

    // when rename is not possible it copies, then deletes
    do {
        let s = Scratch("move-copy")
        s.write("src/a.bin", bytes: 3 * chunk)
        s.write("src/sub/b.bin", bytes: 100)
        var counted: Int64 = 0
        let moved = (try? files.moveTree(
            from: s.path("src"),
            to: s.path("dst"),
            observer: TransferObserver(bytes: { counted += $0 }),
            chunkSize: chunk,
            rename: { _, _ in false }
        )) ?? -1
        T.equal(moved, Int64(3 * chunk + 100), "the fallback reports the bytes it copied")
        T.equal(counted, moved, "and the observer saw them")
        T.check(!s.exists("src"), "the original is deleted after the copy")
        T.equal(s.read("dst/a.bin")?.count ?? -1, 3 * chunk, "the copy is complete")
    }

    // cancelling the copy fallback keeps the original and removes the partial copy
    do {
        let s = Scratch("move-cancel")
        s.write("src/a.bin", bytes: 6 * chunk)
        var seen: Int64 = 0
        var cancelled = false
        do {
            _ = try files.moveTree(
                from: s.path("src"),
                to: s.path("dst"),
                observer: TransferObserver(bytes: { seen += $0 }, isCancelled: { seen >= Int64(2 * chunk) }),
                chunkSize: chunk,
                rename: { _, _ in false }
            )
        } catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a cancelled move surfaces as JobCancelled")
        T.check(s.exists("src/a.bin"), "the original is still there")
        T.check(!s.exists("dst"), "and the partial copy is gone")
    }

    // if the original cannot be removed, no duplicate is left behind
    if !runningAsRoot {
        let s = Scratch("move-undeletable")
        s.write("box/src/a.txt", text: "keep me")
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: s.path("box"))
        var message = ""
        do {
            _ = try files.moveTree(from: s.path("box/src"), to: s.path("dst"), rename: { _, _ in false })
        } catch { message = error.localizedDescription }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.path("box"))
        T.check(message.contains("nothing was moved"), "the failure says nothing was moved")
        T.check(s.exists("box/src/a.txt"), "the original is intact")
        T.check(!s.exists("dst"), "the copy was taken back out")
    }

    // a removal that gets part of the way leaves the copy as the only complete one: it is kept
    do {
        let s = Scratch("move-partial-removal")
        s.write("src/a.txt", text: "a")
        s.write("src/b.txt", text: "b")
        var message = ""
        do {
            _ = try files.moveTree(
                from: s.path("src"),
                to: s.path("dst"),
                rename: { _, _ in false },
                removeSource: { path in
                    try FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent("a.txt"))
                    throw FileServiceError.operationFailed("disk error")
                }
            )
        } catch { message = error.localizedDescription }
        T.check(s.exists("dst/a.txt") && s.exists("dst/b.txt"), "the complete copy is kept when the original is half removed")
        T.equal(s.read("dst/a.txt"), Data("a".utf8), "with its content")
        T.check(message.contains("The complete copy is at"), "and the error says where it is")
        T.check(!message.contains("nothing was moved"), "and does not claim nothing was moved")
    }

    // a removal that fails before removing anything still takes the copy back out
    do {
        let s = Scratch("move-removal-fails-at-once")
        s.write("src/a.txt", text: "a")
        var message = ""
        do {
            _ = try files.moveTree(
                from: s.path("src"),
                to: s.path("dst"),
                rename: { _, _ in false },
                removeSource: { _ in throw FileServiceError.operationFailed("locked") }
            )
        } catch { message = error.localizedDescription }
        T.check(s.exists("src/a.txt"), "the original is whole")
        T.check(!s.exists("dst"), "so there is no second copy")
        T.check(message.contains("nothing was moved"), "and the error says nothing was moved")
    }

    // refusing to overwrite, and a missing source
    do {
        let s = Scratch("move-guards")
        s.write("a.txt", text: "a")
        s.write("b.txt", text: "b")
        var failed = false
        do { _ = try files.moveTree(from: s.path("a.txt"), to: s.path("b.txt")) } catch { failed = true }
        T.check(failed, "moving onto an existing file is refused")
        T.equal(s.read("b.txt"), Data("b".utf8), "the existing file is untouched")
        T.check(s.exists("a.txt"), "and so is the source")
        failed = false
        do { _ = try files.moveTree(from: s.path("gone"), to: s.path("c.txt")) } catch { failed = true }
        T.check(failed, "a missing source is an error")
    }

    // a cancel already requested stops a move before it renames anything
    do {
        let s = Scratch("move-precancel")
        s.write("a.txt", text: "a")
        var cancelled = false
        do { _ = try files.moveTree(from: s.path("a.txt"), to: s.path("b.txt"), observer: TransferObserver(isCancelled: { true })) }
        catch is JobCancelled { cancelled = true } catch {}
        T.check(cancelled, "a move honours a cancel requested before it starts")
        T.check(s.exists("a.txt") && !s.exists("b.txt"), "and moves nothing")
    }
}
