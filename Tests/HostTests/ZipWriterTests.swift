import Foundation

/// Runs a command-line tool and returns its exit status and output, or nil if it is not installed.
func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A deliberately small, independent zip reader for stored entries, so the tests do not check the
/// writer against its own idea of the format.
struct MiniZip {
    struct Entry {
        let name: String
        let flags: UInt16
        let crc: UInt32
        let size: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
        let localOffset: Int
        let localCRC: UInt32
        let localSize: UInt32
        let data: Data
    }

    let entries: [Entry]

    init?(_ bytes: Data) {
        let b = [UInt8](bytes)
        func u16(_ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        guard b.count >= 22 else { return nil }
        var eocd = b.count - 22
        while eocd >= 0, !(b[eocd] == 0x50 && b[eocd + 1] == 0x4B && b[eocd + 2] == 5 && b[eocd + 3] == 6) { eocd -= 1 }
        guard eocd >= 0 else { return nil }
        let count = Int(u16(eocd + 10))
        var cursor = Int(u32(eocd + 16))
        var result: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= b.count, u32(cursor) == 0x02014b50 else { return nil }
            let flags = u16(cursor + 8)
            let dosTime = u16(cursor + 12)
            let dosDate = u16(cursor + 14)
            let crc = u32(cursor + 16)
            let size = u32(cursor + 24)
            let nameLength = Int(u16(cursor + 28))
            let extraLength = Int(u16(cursor + 30))
            let commentLength = Int(u16(cursor + 32))
            let local = Int(u32(cursor + 42))
            let name = String(decoding: b[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            guard local + 30 <= b.count, u32(local) == 0x04034b50 else { return nil }
            let localCRC = u32(local + 14)
            let localSize = u32(local + 18)
            let localName = Int(u16(local + 26))
            let localExtra = Int(u16(local + 28))
            let start = local + 30 + localName + localExtra
            guard start + Int(size) <= b.count else { return nil }
            result.append(Entry(
                name: name, flags: flags, crc: crc, size: size, dosTime: dosTime, dosDate: dosDate,
                localOffset: local, localCRC: localCRC, localSize: localSize,
                data: Data(b[start..<(start + Int(size))])
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        entries = result
    }

    func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }
}

func runZipWriterTests() {
    T.section("ZipWriter")
    let files = FileService()
    let chunk = 4096
    let unzip = "/usr/bin/unzip"

    // a tree goes in and comes out intact, read by an independent reader
    do {
        let s = Scratch("zip-tree")
        s.write("pack/zero.bin", bytes: 0)
        s.write("pack/one.bin", bytes: 1)
        s.write("pack/edge.bin", bytes: chunk)
        s.write("pack/over.bin", bytes: chunk + 1)
        s.write("pack/big.bin", bytes: 3 * chunk + 7)
        s.write("pack/sub/deep/note.txt", text: "hello zip")
        s.write("pack/café/ünï.txt", text: "non-ascii names")
        s.mkdir("pack/empty")
        let zipPath = s.path("out.zip")
        let writer = ZipWriter()
        var counted: Int64 = 0
        var named: [String] = []
        let observer = TransferObserver(bytes: { counted += $0 }, detail: { named.append($0) })
        var ok = true
        do {
            try writer.begin(at: URL(fileURLWithPath: zipPath))
            try writer.addItems([testItem(s, "pack", files: files)], files: files, skipPath: zipPath, observer: observer, chunkSize: chunk)
            try writer.finish()
        } catch { ok = false; print("  zip failed: \(error)") }
        T.check(ok, "a tree is zipped")

        let archive = FileManager.default.contents(atPath: zipPath).flatMap(MiniZip.init)
        T.check(archive != nil, "the archive parses")
        if let archive {
            let names = Set(archive.entries.map(\.name))
            let expected: Set<String> = [
                "pack/zero.bin", "pack/one.bin", "pack/edge.bin", "pack/over.bin", "pack/big.bin",
                "pack/sub/deep/note.txt", "pack/café/ünï.txt", "pack/empty/"
            ]
            T.equal(names, expected, "every file and the empty folder is in the archive, under the top folder's name")
            for name in ["zero.bin", "one.bin", "edge.bin", "over.bin", "big.bin", "sub/deep/note.txt", "café/ünï.txt"] {
                T.equal(archive.entry("pack/\(name)")?.data, s.read("pack/\(name)"), "\(name) comes out byte for byte")
            }
            for entry in archive.entries where !entry.name.hasSuffix("/") {
                T.equal(entry.localCRC, entry.crc, "\(entry.name): the patched local CRC matches the directory's")
                T.equal(entry.localSize, entry.size, "\(entry.name): the patched local size matches the directory's")
            }
            for entry in archive.entries {
                let nonASCII = entry.name.utf8.contains { $0 > 0x7F }
                T.equal(entry.flags & 0x0800 != 0, nonASCII, "\(entry.name): the UTF-8 flag is set exactly for non-ASCII names")
            }
            T.check(archive.entry("pack/empty/")?.size == 0, "the empty folder entry has no data")
        }
        let expectedBytes = Int64(0 + 1 + chunk + (chunk + 1) + (3 * chunk + 7) + 9 + 15)
        T.equal(counted, expectedBytes, "the observer saw every byte of file content once")
        T.check(Set(named) == ["zero.bin", "one.bin", "edge.bin", "over.bin", "big.bin", "note.txt", "ünï.txt"], "each file is named as it is written")

        if let result = runTool(unzip, ["-t", zipPath]) {
            T.check(result.status == 0, "an independent unzip accepts the archive and its CRCs (\(result.output.split(separator: "\n").last ?? ""))")
        }
    }

    // data added from memory (the backup manifest) still works beside streamed files
    do {
        let s = Scratch("zip-mixed")
        s.write("a.txt", text: "from disk")
        let zipPath = s.path("mixed.zip")
        let writer = ZipWriter()
        var ok = true
        do {
            try writer.begin(at: URL(fileURLWithPath: zipPath))
            try writer.addFile(name: "manifest.json", data: Data("[{\"k\":1}]".utf8))
            try writer.addFile(name: "a.txt", fromPath: s.path("a.txt"), modified: Date())
            try writer.finish()
        } catch { ok = false }
        T.check(ok, "memory and disk entries mix")
        let archive = FileManager.default.contents(atPath: zipPath).flatMap(MiniZip.init)
        T.equal(archive?.entry("manifest.json")?.data, Data("[{\"k\":1}]".utf8), "the in-memory entry is intact")
        T.equal(archive?.entry("a.txt")?.data, Data("from disk".utf8), "the streamed entry is intact")
        if let result = runTool(unzip, ["-t", zipPath]) { T.check(result.status == 0, "unzip accepts the mixed archive") }
    }

    // cancelling mid-file stops the write
    do {
        let s = Scratch("zip-cancel")
        s.write("pack/a.bin", bytes: 10 * chunk)
        let zipPath = s.path("cancelled.zip")
        let writer = ZipWriter()
        var seen: Int64 = 0
        var cancelled = false
        do {
            try writer.begin(at: URL(fileURLWithPath: zipPath))
            try writer.addItems(
                [testItem(s, "pack", files: files)], files: files, skipPath: zipPath,
                observer: TransferObserver(bytes: { seen += $0 }, isCancelled: { seen >= Int64(3 * chunk) }),
                chunkSize: chunk
            )
        } catch is JobCancelled { cancelled = true } catch {}
        writer.abandon()
        T.check(cancelled, "a cancel surfaces as JobCancelled")
        T.equal(seen, Int64(3 * chunk), "it stopped at the next chunk")
        writer.abandon()
        T.check(true, "abandoning twice is harmless")
    }

    // links inside a folder are left out: one can point back up the tree, and following it would never end
    do {
        let s = Scratch("zip-links")
        s.write("pack/real.txt", text: "real")
        s.write("pack/sub/inner.txt", text: "inner")
        try? FileManager.default.createSymbolicLink(atPath: s.path("pack/up"), withDestinationPath: s.path("pack"))
        try? FileManager.default.createSymbolicLink(atPath: s.path("pack/alias.txt"), withDestinationPath: s.path("pack/real.txt"))
        try? FileManager.default.createSymbolicLink(atPath: s.path("pack/dangling"), withDestinationPath: "nowhere")
        let zipPath = s.path("links.zip")
        let writer = ZipWriter()
        var ok = true
        do {
            try writer.begin(at: URL(fileURLWithPath: zipPath))
            try writer.addItems([testItem(s, "pack", files: files)], files: files, skipPath: zipPath)
            try writer.finish()
        } catch { ok = false; writer.abandon() }
        T.check(ok, "a folder holding links is zipped without looping or failing")
        let names = Set((FileManager.default.contents(atPath: zipPath).flatMap(MiniZip.init)?.entries.map(\.name)) ?? [])
        T.check(names.contains("pack/real.txt") && names.contains("pack/sub/inner.txt"), "the real files are in it")
        T.check(!names.contains { $0.hasPrefix("pack/up") }, "the link back up the tree is not followed")
        T.check(!names.contains("pack/alias.txt"), "a link to a file is not stored as a copy of it")
        T.check(!names.contains("pack/dangling"), "and a dangling link is left out")
    }

    // the archive being written is never packed into itself
    do {
        let s = Scratch("zip-self")
        s.write("pack/a.txt", text: "a")
        let zipPath = s.path("pack/self.zip")
        let writer = ZipWriter()
        try? writer.begin(at: URL(fileURLWithPath: zipPath))
        try? writer.addItems([testItem(s, "pack", files: files)], files: files, skipPath: zipPath)
        try? writer.finish()
        let names = (FileManager.default.contents(atPath: zipPath).flatMap(MiniZip.init)?.entries.map(\.name)) ?? []
        T.equal(names, ["pack/a.txt"], "zipping the folder that holds the zip leaves the zip out")
    }

    // symlinks are skipped, and a loop cannot run away
    do {
        let s = Scratch("zip-links")
        s.write("pack/real/f.txt", text: "f")
        try? FileManager.default.createSymbolicLink(atPath: s.path("pack/link-dir"), withDestinationPath: s.path("pack/real"))
        try? FileManager.default.createSymbolicLink(atPath: s.path("pack/link-file"), withDestinationPath: s.path("pack/real/f.txt"))
        try? FileManager.default.createSymbolicLink(atPath: s.path("pack/loop"), withDestinationPath: s.path("pack"))
        let zipPath = s.path("links.zip")
        let writer = ZipWriter()
        var ok = true
        do {
            try writer.begin(at: URL(fileURLWithPath: zipPath))
            try writer.addItems([testItem(s, "pack", files: files)], files: files, skipPath: zipPath)
            try writer.finish()
        } catch { ok = false }
        T.check(ok, "a folder with links, one pointing back up, zips")
        let names = Set((FileManager.default.contents(atPath: zipPath).flatMap(MiniZip.init)?.entries.map(\.name)) ?? [])
        T.equal(names, ["pack/real/f.txt"], "only real files are packed; links are not followed")
    }

    // nothing to zip
    do {
        let s = Scratch("zip-nothing")
        let writer = ZipWriter()
        try? writer.begin(at: URL(fileURLWithPath: s.path("n.zip")))
        var message = ""
        do { try writer.addItems([], files: files, skipPath: s.path("n.zip")) } catch { message = error.localizedDescription }
        writer.abandon()
        T.equal(message, "Operation failed: Nothing to zip.", "no items is a clear error")
    }

    // used before it is opened
    do {
        let s = Scratch("zip-closed")
        let writer = ZipWriter()
        var failed = false
        do { try writer.addFile(name: "x", data: Data()) } catch ZipWriterError.notOpen { failed = true } catch {}
        T.check(failed, "adding to a writer that was never begun is an error, not a crash")
        failed = false
        do { try writer.addFile(name: "x", fromPath: s.path("nope"), modified: Date()) } catch ZipWriterError.notOpen { failed = true } catch {}
        T.check(failed, "and so is streaming into one")
    }

    // modification time is the file's own
    do {
        let s = Scratch("zip-time")
        let path = s.write("t.txt", text: "t")
        var parts = DateComponents()
        parts.year = 2021; parts.month = 3; parts.day = 4; parts.hour = 5; parts.minute = 6; parts.second = 8
        let stamp = Calendar(identifier: .gregorian).date(from: parts) ?? Date()
        try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path)
        let zipPath = s.path("t.zip")
        let writer = ZipWriter()
        try? writer.begin(at: URL(fileURLWithPath: zipPath))
        try? writer.addItems([testItem(s, "t.txt", files: files)], files: files, skipPath: zipPath)
        try? writer.finish()
        if let entry = FileManager.default.contents(atPath: zipPath).flatMap(MiniZip.init)?.entries.first {
            T.equal(Int(entry.dosDate >> 9) + 1980, 2021, "the year is the file's")
            T.equal(Int((entry.dosDate >> 5) & 0xF), 3, "the month is the file's")
            T.equal(Int(entry.dosDate & 0x1F), 4, "the day is the file's")
            T.equal(Int(entry.dosTime >> 11), 5, "the hour is the file's")
            T.equal(Int((entry.dosTime >> 5) & 0x3F), 6, "the minute is the file's")
            T.equal(Int(entry.dosTime & 0x1F) * 2, 8, "the second is the file's, to the zip format's two-second step")
        } else {
            T.check(false, "the timestamp test archive parses")
        }
    }

    // an unreadable file is a clear error
    if !runningAsRoot {
        let s = Scratch("zip-locked")
        let locked = s.write("pack/locked.txt", text: "secret")
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        let writer = ZipWriter()
        try? writer.begin(at: URL(fileURLWithPath: s.path("l.zip")))
        var message = ""
        do { try writer.addItems([testItem(s, "pack", files: files)], files: files, skipPath: s.path("l.zip")) } catch { message = error.localizedDescription }
        writer.abandon()
        T.check(message.contains("locked.txt"), "the error names the file it could not read (\(message))")
    }
}
