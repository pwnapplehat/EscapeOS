import Foundation

// Backups with no cap on files or bytes: the streaming hash, the ZIP64 writer and reader, writing a
// backup, and restoring one. The slow cases (hundreds of MB, and a 4 GB archive) run only when
// ESCAPEOS_SLOW=1 is set; they were run by hand before the release.

private let slowTests = ProcessInfo.processInfo.environment["ESCAPEOS_SLOW"] == "1"

/// An app's data folder with Documents, Library and tmp, for a backup to read.
private func makeContainer(_ s: Scratch, documents: Int = 0, library: Int = 0, tmp: Int = 0, bytesEach: Int = 10) {
    s.mkdir("app/Documents")
    s.mkdir("app/Library")
    s.mkdir("app/tmp")
    // Spread over folders, as an app does, so no one folder is a million entries.
    func spread(_ root: String, _ count: Int) {
        for i in 0..<count {
            s.write("app/\(root)/d\(i % 50)/f\(i).bin", bytes: bytesEach + i % 7, fill: UInt8(truncatingIfNeeded: i))
        }
    }
    spread("Documents", documents)
    spread("Library", library)
    spread("tmp", tmp)
}

private let source = { (s: Scratch) in
    BackupSource(bundleIdentifier: "com.example.app", appName: "Example", containerPath: s.path("app"))
}

/// Every file under `root`, as relative path → contents.
private func snapshot(_ root: String) -> [String: Data] {
    var result: [String: Data] = [:]
    guard let walker = FileManager.default.enumerator(atPath: root) else { return result }
    while let relative = walker.nextObject() as? String {
        let full = (root as NSString).appendingPathComponent(relative)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
            result[relative] = FileManager.default.contents(atPath: full)
        }
    }
    return result
}

/// Names of leftover scratch files (the manifest spool, or a half-written restore) under `root`.
private func leftovers(_ root: String) -> [String] {
    snapshot(root).keys.filter {
        $0.hasSuffix(".manifest.tmp") || ($0 as NSString).lastPathComponent.hasPrefix(BackupRestorer.scratchPrefix)
    }.sorted()
}

private func sha256sum(_ path: String) -> String? {
    runTool("/usr/bin/sha256sum", [path]).flatMap { $0.status == 0 ? String($0.output.prefix(64)) : nil }
}

/// A backup archive built by hand, for the cases a real backup would never produce.
private func makeBackup(
    at url: URL,
    bundle: String = "com.example.app",
    entries: [(path: String, data: Data)],
    manifest manifestOverride: [BackupManifestEntry]? = nil,
    stompManifestHash: Bool = false
) throws {
    let writer = ZipWriter()
    try writer.begin(at: url)
    var manifest: [BackupManifestEntry] = []
    for entry in entries {
        try writer.addFile(name: entry.path, data: entry.data)
        manifest.append(BackupManifestEntry(path: entry.path, size: entry.data.count, sha256: StreamingSHA256.hex(of: entry.data)))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let manifestData = try encoder.encode(manifestOverride ?? manifest)
    try writer.addFile(name: BackupPaths.manifestFileName, data: manifestData)
    let metadata = BackupMetadata(
        bundleIdentifier: bundle, appName: "Example", containerPath: "/old",
        createdAt: "2026-10-29T00:00:00Z", fileCount: entries.count,
        totalBytes: Int64(entries.reduce(0) { $0 + $1.data.count }),
        manifestSHA256: stompManifestHash ? String(repeating: "0", count: 64) : StreamingSHA256.hex(of: manifestData),
        escapeOSVersion: "test"
    )
    try writer.addFile(name: BackupPaths.metadataFileName, data: try encoder.encode(metadata))
    try writer.finish()
}

func runBackupArchiveTests() {
    T.section("StreamingSHA256")
    do {
        T.equal(StreamingSHA256.hex(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "the digest of nothing")
        T.equal(StreamingSHA256.hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "the digest of abc")
        T.equal(
            StreamingSHA256.hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            "the two-block published vector"
        )
        var million = StreamingSHA256()
        let hundred = Data(repeating: 0x61, count: 100)
        for _ in 0..<10_000 { million.update(hundred) }
        T.equal(million.finalize(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "a million a's, in pieces")

        // Pieces of every awkward size give the digest of the whole, and match the system's sha256sum.
        let s = Scratch("sha")
        let blob = s.write("blob.bin", bytes: 300_017)
        let whole = StreamingSHA256.hex(of: FileManager.default.contents(atPath: blob) ?? Data())
        for piece in [1, 7, 55, 56, 63, 64, 65, 1000, 4096, 100_000] {
            var h = StreamingSHA256()
            var at = 0
            let data = FileManager.default.contents(atPath: blob) ?? Data()
            while at < data.count {
                h.update(data.subdata(in: at..<min(at + piece, data.count)))
                at += piece
            }
            T.equal(h.finalize(), whole, "pieces of \(piece) bytes give the same digest")
        }
        if let expected = sha256sum(blob) { T.equal(whole, expected, "the digest matches sha256sum") }
        var twice = StreamingSHA256()
        twice.update(Data("abc".utf8))
        let first = twice.finalize()
        T.equal(twice.finalize(), first, "reading the digest does not disturb it")
    }

    T.section("ZipWriter ZIP64")
    let unzip = "/usr/bin/unzip"
    func python(_ script: String, _ path: String) -> String? {
        runTool("/usr/bin/python3", ["-c", script, path]).map { $0.output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    let pyCheck = "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); print(z.testzip(), len(z.namelist()))"

    // a small archive is a plain zip: no ZIP64 records at all
    do {
        let s = Scratch("zip64-plain")
        let path = s.path("plain.zip")
        let writer = ZipWriter()
        var ok = true
        do {
            try writer.begin(at: URL(fileURLWithPath: path))
            try writer.addFile(name: "a.txt", data: Data("hello".utf8))
            try writer.finish()
        } catch { ok = false }
        T.check(ok, "a small zip is written")
        let bytes = [UInt8](FileManager.default.contents(atPath: path) ?? Data())
        func contains(_ sig: [UInt8]) -> Bool { (0...(max(bytes.count - 4, 0))).contains { i in i + 4 <= bytes.count && Array(bytes[i..<(i + 4)]) == sig } }
        T.check(!contains([0x50, 0x4B, 0x06, 0x06]) && !contains([0x50, 0x4B, 0x06, 0x07]), "no ZIP64 end records in a small archive")
    }

    // the ZIP64 records, forced by lowering the thresholds, are accepted by independent readers
    do {
        let s = Scratch("zip64-forced")
        let path = s.path("forced.zip")
        s.write("small.bin", bytes: 5)
        s.write("medium.bin", bytes: 25)
        s.write("large.bin", bytes: 4096 * 3 + 11)
        let writer = ZipWriter()
        writer.zip64Threshold = 20
        writer.zip64EntryLimit = 4
        var ok = true
        do {
            try writer.begin(at: URL(fileURLWithPath: path))
            try writer.addFile(name: "mem-small.txt", data: Data("tiny".utf8))
            try writer.addFile(name: "small.bin", fromPath: s.path("small.bin"), modified: Date(), chunkSize: 8)
            try writer.addFile(name: "medium.bin", fromPath: s.path("medium.bin"), modified: Date(), chunkSize: 8)
            try writer.addFile(name: "mem-big.txt", data: Data(repeating: 0x42, count: 64))
            try writer.addFile(name: "large.bin", fromPath: s.path("large.bin"), modified: Date(), chunkSize: 4096)
            try writer.finish()
        } catch { ok = false; print("  zip64 write failed: \(error)") }
        T.check(ok, "a zip with every ZIP64 record is written")
        if let result = runTool(unzip, ["-t", path]) {
            T.check(result.status == 0, "unzip accepts the ZIP64 archive and its CRCs (\(result.output.split(separator: "\n").last ?? ""))")
        }
        if let out = python(pyCheck, path) { T.equal(out, "None 5", "python's zipfile reads the ZIP64 archive, all 5 entries, no bad CRC") }
        if let reader = try? ZipReader(url: URL(fileURLWithPath: path)) {
            T.equal(reader.entries.count, 5, "our reader sees every entry of the ZIP64 archive")
            T.equal(try? reader.readEntry(named: "medium.bin"), s.read("medium.bin"), "a ZIP64-sized streamed file reads back exactly")
            T.equal(try? reader.readEntry(named: "large.bin"), s.read("large.bin"), "a larger ZIP64 file reads back exactly")
            T.equal(try? reader.readEntry(named: "mem-big.txt"), Data(repeating: 0x42, count: 64), "a ZIP64-sized in-memory entry reads back exactly")
            T.equal(try? reader.readEntry(named: "small.bin"), s.read("small.bin"), "a small file in a ZIP64 archive reads back exactly")
        } else {
            T.check(false, "our reader opens the ZIP64 archive")
        }
    }

    // more than 65,535 entries: the real limit of the plain format
    do {
        let s = Scratch("zip-many")
        let path = s.path("many.zip")
        let count = 70_000
        let writer = ZipWriter()
        var ok = true
        do {
            try writer.begin(at: URL(fileURLWithPath: path))
            for i in 0..<count { try writer.addFile(name: "d\(i % 100)/f\(i).txt", data: Data("n\(i)".utf8)) }
            try writer.finish()
        } catch { ok = false; print("  many-entry write failed: \(error)") }
        T.check(ok, "\(count) entries are written")
        if let result = runTool(unzip, ["-t", path]) {
            T.check(result.status == 0, "unzip accepts \(count) entries (\(result.output.split(separator: "\n").last ?? ""))")
        }
        if let out = python(pyCheck, path) { T.equal(out, "None \(count)", "python's zipfile counts all \(count)") }
        if let reader = try? ZipReader(url: URL(fileURLWithPath: path)) {
            T.equal(reader.entries.count, count, "our reader sees all \(count)")
            T.equal(try? reader.readEntry(named: "d7/f69907.txt"), Data("n69907".utf8), "an entry past 65,535 reads back")
            T.equal(try? reader.readEntry(named: "d0/f0.txt"), Data("n0".utf8), "the first entry reads back")
        } else {
            T.check(false, "our reader opens \(count) entries")
        }
        if let small = try? ZipReader(url: URL(fileURLWithPath: path), only: ["d3/f3.txt"]) {
            T.equal(small.entries.count, 1, "a reader asked for one entry builds only that one")
        } else {
            T.check(false, "a reader limited to one entry opens")
        }
    }

    // a file that grows past the ZIP64 size while it is read is taken back out of the archive
    do {
        let s = Scratch("zip-grow")
        let path = s.path("grow.zip")
        s.write("grow.bin", bytes: 8)
        s.write("after.txt", text: "still fine")
        let writer = ZipWriter()
        writer.zip64Threshold = 30
        var threw = false
        var ok = true
        do {
            try writer.begin(at: URL(fileURLWithPath: path))
            try writer.addFile(name: "before.txt", data: Data("first".utf8))
            do {
                var grown = false
                try writer.addFile(name: "grow.bin", fromPath: s.path("grow.bin"), modified: Date(), chunkSize: 4, onChunk: { _ in
                    if !grown, let h = FileHandle(forWritingAtPath: s.path("grow.bin")) {
                        _ = try? h.seekToEnd()
                        try? h.write(contentsOf: Data(repeating: 0x5A, count: 64))
                        try? h.close()
                        grown = true
                    }
                })
            } catch ZipWriterError.unreadable { threw = true }
            try writer.addFile(name: "after.txt", fromPath: s.path("after.txt"), modified: Date())
            try writer.finish()
        } catch { ok = false; print("  grow write failed: \(error)") }
        T.check(ok && threw, "a file that outgrows its header is reported as unreadable")
        let controlPath = s.path("control.zip")
        let control = ZipWriter()
        control.zip64Threshold = 30
        try? control.begin(at: URL(fileURLWithPath: controlPath))
        try? control.addFile(name: "before.txt", data: Data("first".utf8))
        try? control.addFile(name: "after.txt", fromPath: s.path("after.txt"), modified: Date())
        try? control.finish()
        let sizeOf = { (path: String) in ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? -1 }
        T.equal(sizeOf(path), sizeOf(controlPath), "and what had been written for it is cut out, so the archive is no larger than one without it")
        if let reader = try? ZipReader(url: URL(fileURLWithPath: path)) {
            T.equal(Set(reader.entries.keys), ["before.txt", "after.txt"], "nothing of the file that grew is left in the archive")
            T.equal(try? reader.readEntry(named: "after.txt"), Data("still fine".utf8), "the entry after it is intact")
        } else {
            T.check(false, "the archive is still valid")
        }
        if let result = runTool(unzip, ["-t", path]) { T.check(result.status == 0, "unzip accepts it") }
    }

    // a file that fails part-way through being read is taken back out too (a folder opens but cannot be read)
    do {
        let s = Scratch("zip-readfail")
        s.mkdir("folder")
        s.write("ok.txt", text: "ok")
        let path = s.path("rf.zip")
        let writer = ZipWriter()
        var threw = false
        try? writer.begin(at: URL(fileURLWithPath: path))
        try? writer.addFile(name: "first.txt", data: Data("1".utf8))
        do { try writer.addFile(name: "folder", fromPath: s.path("folder"), modified: Date()) } catch ZipWriterError.unreadable { threw = true } catch {}
        try? writer.addFile(name: "ok.txt", fromPath: s.path("ok.txt"), modified: Date())
        try? writer.finish()
        let controlPath = s.path("rf-control.zip")
        let control = ZipWriter()
        try? control.begin(at: URL(fileURLWithPath: controlPath))
        try? control.addFile(name: "first.txt", data: Data("1".utf8))
        try? control.addFile(name: "ok.txt", fromPath: s.path("ok.txt"), modified: Date())
        try? control.finish()
        let sizeOf = { (p: String) in ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? -1 }
        T.check(threw, "a read that fails part-way is reported as unreadable")
        T.equal(sizeOf(path), sizeOf(controlPath), "and its header is cut back out of the archive")
        T.equal(Set((try? ZipReader(url: URL(fileURLWithPath: path)))?.entries.keys.map { $0 } ?? []), ["first.txt", "ok.txt"], "the archive lists only the files that went in")
    }

    // an archive another tool wrote with exactly 65,535 entries has no ZIP64 records, and still opens
    do {
        let s = Scratch("zip-65535")
        let path = s.path("exact.zip")
        if runTool("/usr/bin/python3", ["-c", "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],'w'); [z.writestr('f%d'%i,b'x') for i in range(65535)]; z.close()", path]) != nil {
            if let reader = try? ZipReader(url: URL(fileURLWithPath: path)) {
                T.equal(reader.entries.count, 65535, "a zip with exactly 65,535 entries opens")
                T.equal(try? reader.readEntry(named: "f65534"), Data("x".utf8), "and its last entry reads")
            } else {
                T.check(false, "a zip with exactly 65,535 entries opens")
            }
        }
    }

    // a damaged ZIP64 locator is an error, not a crash
    do {
        var bytes = Data()
        bytes.append(contentsOf: [0x50, 0x4B, 0x06, 0x07])                      // ZIP64 end locator
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(contentsOf: [0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]) // offset near Int.max
        bytes.append(contentsOf: [1, 0, 0, 0])
        bytes.append(contentsOf: [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        var rejected = false
        do { _ = try ZipReader(data: bytes) } catch { rejected = true }
        T.check(rejected, "a ZIP64 locator pointing past the end of the world is refused, not trapped on")
    }

    // a file that cannot be opened is reported as unreadable and leaves nothing behind
    if !runningAsRoot {
        let s = Scratch("zip-locked")
        let path = s.path("locked.zip")
        let locked = s.write("locked.bin", bytes: 100)
        chmod(locked, 0)
        let writer = ZipWriter()
        var threw = false
        do {
            try writer.begin(at: URL(fileURLWithPath: path))
            do { try writer.addFile(name: "locked.bin", fromPath: locked, modified: Date()) } catch ZipWriterError.unreadable { threw = true }
            try writer.addFile(name: "ok.txt", data: Data("ok".utf8))
            try writer.finish()
        } catch { print("  locked write failed: \(error)") }
        chmod(locked, 0o644)
        T.check(threw, "an unreadable file is reported as such")
        T.equal((try? ZipReader(url: URL(fileURLWithPath: path)))?.entries.count, 1, "and is not in the archive")
    }

    if slowTests {
        // A file of 4.2 GB (sparse on disk, so cheap to make): the offsets and sizes past 4 GB.
        let s = Scratch("zip-4gb")
        let path = s.path("big.zip")
        let big = s.path("big.bin")
        FileManager.default.createFile(atPath: big, contents: nil)
        if let h = FileHandle(forWritingAtPath: big) {
            try? h.truncate(atOffset: 4_400_000_000)
            try? h.seek(toOffset: 4_399_999_989)
            try? h.write(contentsOf: Data("END-MARKER!".utf8))
            try? h.close()
        }
        s.write("small-after.txt", text: "after the big one")
        let writer = ZipWriter()
        var ok = true
        do {
            try writer.begin(at: URL(fileURLWithPath: path))
            try writer.addFile(name: "big.bin", fromPath: big, modified: Date())
            try writer.addFile(name: "small-after.txt", fromPath: s.path("small-after.txt"), modified: Date())
            try writer.finish()
        } catch { ok = false; print("  4 GB write failed: \(error)") }
        T.check(ok, "an archive past 4 GB is written")
        if let result = runTool(unzip, ["-t", path]) {
            T.check(result.status == 0, "unzip accepts the 4 GB archive (\(result.output.split(separator: "\n").last ?? ""))")
        }
        if let out = python(pyCheck, path) { T.equal(out, "None 2", "python's zipfile reads the 4 GB archive") }
        if let reader = try? ZipReader(url: URL(fileURLWithPath: path)) {
            T.equal(try? reader.readEntry(named: "small-after.txt"), Data("after the big one".utf8), "an entry whose offset is past 4 GB reads back")
            if let member = reader.entries["big.bin"] {
                T.equal(member.uncompressedSize, 4_400_000_000, "the big file's size is the real one")
                var tail = Data()
                var seen = 0
                try? reader.streamEntry(member) { piece in
                    seen += piece.count
                    if seen > 4_399_999_900 { tail.append(piece.suffix(20)) }
                }
                T.equal(seen, 4_400_000_000, "the big file streams out whole")
                T.check(String(decoding: tail, as: UTF8.self).hasSuffix("END-MARKER!"), "and ends with the marker")
            } else { T.check(false, "the big file is in the archive") }
        } else { T.check(false, "our reader opens the 4 GB archive") }
    }

    T.section("BackupArchiver")
    // more than the old 5,000-file limit
    do {
        let s = Scratch("backup-many")
        makeContainer(s, documents: 4000, library: 1500, tmp: 300)
        let out = URL(fileURLWithPath: s.path("out/backup.zip"))
        s.mkdir("out")
        let archiver = BackupArchiver()
        archiver.progressInterval = 0
        var progressCalls = 0
        var estimated: Int64?
        var streamed: Int64 = 0
        var result: BackupResult?
        var failure: Error?
        do {
            result = try archiver.write(
                source: source(s), to: out, spaceDirectory: s.path("out"), escapeOSVersion: "test",
                estimate: { estimated = $0 },
                bytes: { streamed += $0 },
                progress: { _, _, _ in progressCalls += 1 }
            )
        } catch { failure = error }
        T.check(failure == nil, "5,800 files are backed up (\(failure.map { "\($0)" } ?? "ok"))")
        T.equal(result?.fileCount, 5800, "all 5,800 files are counted")
        let sourceFiles = snapshot(s.path("app"))
        let expectedBytes = Int64(sourceFiles.values.reduce(0) { $0 + $1.count })
        T.equal(result?.totalBytes, expectedBytes, "the byte total is the real one")
        T.equal(streamed, expectedBytes, "every byte was reported as it was written")
        T.equal(estimated, expectedBytes, "the size estimate before the start is exact")
        T.equal(progressCalls, 5800, "progress is reported for each file when not throttled")
        T.equal(leftovers(s.path("out")), [], "no scratch file is left behind")

        if let reader = try? ZipReader(url: out) {
            T.equal(reader.entries.count, 5800 + 2, "the archive holds every file, the manifest and the metadata")
            // the manifest is exactly what encoding the whole list at once gives, so the format is unchanged
            if let manifestData = try? reader.readEntry(named: BackupPaths.manifestFileName),
               let manifest = try? JSONDecoder().decode([BackupManifestEntry].self, from: manifestData) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                T.equal(manifestData, try! encoder.encode(manifest), "the streamed manifest is byte for byte the whole-list encoding")
                T.equal(StreamingSHA256.hex(of: manifestData), result?.manifestSHA256, "its hash is the one recorded")
                T.equal(manifest.count, 5800, "the manifest lists every file")
                var wrong = 0
                for entry in manifest {
                    guard let data = sourceFiles[entry.path], data.count == entry.size, StreamingSHA256.hex(of: data) == entry.sha256 else { wrong += 1; continue }
                }
                T.equal(wrong, 0, "every manifest line has the real size and SHA-256 of its file")
            } else {
                T.check(false, "the manifest reads")
            }
            if let metadataData = try? reader.readEntry(named: BackupPaths.metadataFileName),
               let metadata = try? JSONDecoder().decode(BackupMetadata.self, from: metadataData) {
                T.equal(metadata.fileCount, 5800, "the metadata's file count")
                T.equal(metadata.manifestSHA256, result?.manifestSHA256, "the metadata's manifest hash")
                T.check(metadata.isPartial == nil, "a full backup is not marked partial")
            } else {
                T.check(false, "the metadata reads")
            }
        } else {
            T.check(false, "the archive opens")
        }
        if let check = runTool(unzip, ["-t", out.path]) { T.check(check.status == 0, "unzip accepts the backup") }

        // the catalog lists it by reading only backup.json
        if let record = try? BackupCatalog().loadRecord(at: out) {
            T.equal(record.metadata.fileCount, 5800, "the Backups list reads its metadata")
        } else {
            T.check(false, "the Backups list opens a large backup")
        }

        // and it restores, all of it, into an empty container
        let target = Scratch("backup-many-target")
        target.mkdir("app")
        var restored: BackupRestorer.Outcome?
        var restoreFailure: Error?
        do {
            restored = try BackupRestorer().restore(archiveURL: out, bundleIdentifier: "com.example.app", containerPath: target.path("app"))
        } catch { restoreFailure = error }
        T.check(restoreFailure == nil, "5,800 files are restored (\(restoreFailure.map { "\($0)" } ?? "ok"))")
        T.equal(restored?.filesRestored, 5800, "all are restored")
        T.check(snapshot(target.path("app")) == sourceFiles, "every restored file is byte for byte the original")
        T.equal(leftovers(target.path("app")), [], "no half-written file is left")
    }

    // an app whose own data holds the folder the backup is written to (EscapeOS backing itself up)
    do {
        let s = Scratch("backup-self")
        s.write("app/Documents/notes.txt", text: "notes")
        s.write("app/Documents/Backups/old.zip", text: "an earlier backup")
        s.write("app/Documents/Backups/dead.zip", text: "cut off by a kill")
        s.write("app/Documents/Backups/dead.zip.manifest.tmp", text: "[")
        s.write("app/Documents/.escapeos-restore-abc123", text: "half a restore")
        let folder = s.path("app/Documents/Backups")
        let out = URL(fileURLWithPath: folder + "/new.zip")
        var result: BackupResult?
        var failure: Error?
        do { result = try BackupArchiver().write(source: source(s), to: out, spaceDirectory: folder, escapeOSVersion: "test") } catch { failure = error }
        T.check(failure == nil, "an app that holds the backup folder can be backed up (\(failure.map { "\($0)" } ?? "ok"))")
        if let url = result?.archiveURL, let manifest = try? BackupRestorer().manifest(of: url) {
            T.equal(Set(manifest.map(\.path)), ["Documents/notes.txt", "Documents/Backups/old.zip"], "the archive being written, its manifest and a half-restored file are left out; an earlier backup is kept")
        } else { T.check(false, "the self-backup's manifest reads") }
        T.check(!s.exists("app/Documents/Backups/dead.zip") && !s.exists("app/Documents/Backups/dead.zip.manifest.tmp"), "a backup cut off earlier is cleaned up: its archive and scratch manifest are removed")
        T.check(s.exists("app/Documents/Backups/old.zip"), "a finished backup is not touched")
        T.equal(leftovers(folder).filter { $0.hasSuffix(".manifest.tmp") }, [], "and no scratch manifest is left")
    }

    // streaming: the bytes arrive in pieces, never a whole big file at once
    do {
        let s = Scratch("backup-stream")
        s.mkdir("app/Documents")
        s.write("app/Documents/big.bin", bytes: 10 * 1024 * 1024 + 5)
        s.mkdir("out")
        var pieces: [Int64] = []
        let result = try? BackupArchiver().write(
            source: source(s), to: URL(fileURLWithPath: s.path("out/b.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test",
            bytes: { pieces.append($0) }
        )
        T.equal(result?.fileCount, 1, "the big file is backed up")
        T.check(pieces.count >= 3 && (pieces.max() ?? 0) <= Int64(FileService.transferChunkBytes), "a 10 MB file goes through in chunks of at most \(FileService.transferChunkBytes / 1024 / 1024) MB (\(pieces.count) pieces)")
        T.equal(pieces.reduce(0, +), Int64(10 * 1024 * 1024 + 5), "and the pieces add up to the file")
    }

    // a partial backup holds only what was chosen
    do {
        let s = Scratch("backup-partial")
        makeContainer(s, documents: 60, library: 30)
        s.mkdir("out")
        let selection = BackupSelection(paths: ["Documents/d3", "Library/d1/f1.bin"])!
        let result = try? BackupArchiver().write(
            source: source(s), selection: selection, to: URL(fileURLWithPath: s.path("out/p.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test"
        )
        let expected = snapshot(s.path("app")).keys.filter { selection.covers($0) }.sorted()
        T.check(!expected.isEmpty, "the fixture has something chosen")
        T.equal(result?.fileCount, expected.count, "only the chosen files are backed up")
        T.equal(result?.metadata.isPartial, true, "it is marked partial")
        T.equal(result?.metadata.scope ?? [], selection.paths, "and records what was chosen")
        if let url = result?.archiveURL, let manifest = try? BackupRestorer().manifest(of: url) {
            T.equal(manifest.map(\.path).sorted(), expected, "the manifest lists exactly the chosen files")
        } else { T.check(false, "the partial backup's manifest reads") }
    }

    // an empty selection target, links, odd names, unreadable and missing things
    do {
        let s = Scratch("backup-odd")
        s.mkdir("app/Documents/empty")
        s.write("app/Documents/ünï cödé/a b.txt", text: "unicode and spaces")
        s.write("app/Documents/zero.bin", bytes: 0)
        s.write("app/Library/keep.txt", text: "keep")
        s.write("elsewhere/secret.txt", text: "outside the container")
        try? FileManager.default.createSymbolicLink(atPath: s.path("app/Documents/link-to-outside"), withDestinationPath: s.path("elsewhere"))
        try? FileManager.default.createSymbolicLink(atPath: s.path("app/Documents/loop"), withDestinationPath: s.path("app/Documents"))
        try? FileManager.default.createSymbolicLink(atPath: s.path("app/Documents/link-to-file"), withDestinationPath: s.path("elsewhere/secret.txt"))
        var locked = ""
        if !runningAsRoot {
            locked = s.write("app/Documents/locked.bin", bytes: 50)
            chmod(locked, 0)
        }
        s.mkdir("out")
        var failure: Error?
        var result: BackupResult?
        do {
            result = try BackupArchiver().write(
                source: source(s), to: URL(fileURLWithPath: s.path("out/odd.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test"
            )
        } catch { failure = error }
        if !locked.isEmpty { chmod(locked, 0o644) }
        T.check(failure == nil, "a container with links and an unreadable file still backs up (\(failure.map { "\($0)" } ?? "ok"))")
        if let url = result?.archiveURL, let manifest = try? BackupRestorer().manifest(of: url) {
            T.equal(
                Set(manifest.map(\.path)),
                ["Documents/ünï cödé/a b.txt", "Documents/zero.bin", "Library/keep.txt"],
                "links are not followed, an unreadable file is skipped, an empty file is kept"
            )
        } else { T.check(false, "the odd backup's manifest reads") }
        T.equal(leftovers(s.path("out")), [], "no scratch left")
    }

    // nothing to back up, and a missing container
    do {
        let s = Scratch("backup-none")
        s.mkdir("app/Documents/onlyempty")
        s.mkdir("out")
        let archiver = BackupArchiver()
        let selection = BackupSelection(paths: ["Documents/onlyempty"])!
        var message = ""
        do {
            _ = try archiver.write(source: source(s), selection: selection, to: URL(fileURLWithPath: s.path("out/a.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test")
        } catch { message = error.localizedDescription }
        T.check(message.contains("nothing to back up"), "a chosen empty folder is refused with a reason")
        T.check(!s.exists("out/a.zip") && leftovers(s.path("out")).isEmpty, "and leaves no file behind")
        var missing = ""
        do {
            _ = try archiver.write(source: BackupSource(bundleIdentifier: "x", appName: "x", containerPath: s.path("nope")), to: URL(fileURLWithPath: s.path("out/b.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test")
        } catch { missing = error.localizedDescription }
        T.check(missing.contains("not visible"), "a container with no Documents, Library or tmp is refused")
        T.check(!s.exists("out/b.zip"), "and leaves no file behind")
    }

    // cancelling, between files and in the middle of a big one, removes everything
    do {
        let s = Scratch("backup-cancel")
        makeContainer(s, documents: 300)
        s.write("app/Library/huge.bin", bytes: 9 * 1024 * 1024)
        s.mkdir("out")
        var seen = 0
        var error1: Error?
        let eager = BackupArchiver()
        eager.progressInterval = 0
        do {
            _ = try eager.write(
                source: source(s), to: URL(fileURLWithPath: s.path("out/c1.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test",
                progress: { _, _, _ in seen += 1 }, isCancelled: { seen >= 50 }
            )
        } catch { error1 = error }
        T.check((error1 as? BackupError).map { if case .cancelled = $0 { return true } else { return false } } ?? false, "cancelling between files stops with 'cancelled'")
        T.check(!s.exists("out/c1.zip") && leftovers(s.path("out")).isEmpty, "and removes the archive and the scratch file")

        var streamedBytes: Int64 = 0
        var error2: Error?
        do {
            _ = try BackupArchiver().write(
                source: BackupSource(bundleIdentifier: "x", appName: "x", containerPath: s.path("app")),
                selection: BackupSelection(paths: ["Library/huge.bin"])!,
                to: URL(fileURLWithPath: s.path("out/c2.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test",
                bytes: { streamedBytes += $0 }, isCancelled: { streamedBytes >= Int64(FileService.transferChunkBytes) }
            )
        } catch { error2 = error }
        T.check((error2 as? BackupError).map { if case .cancelled = $0 { return true } else { return false } } ?? false, "cancelling in the middle of a big file stops with 'cancelled'")
        T.check(streamedBytes < 9 * 1024 * 1024, "and stops before the whole file was written (\(streamedBytes) bytes)")
        T.check(!s.exists("out/c2.zip") && leftovers(s.path("out")).isEmpty, "removing what was written")
    }

    // progress is throttled, not per file
    do {
        let s = Scratch("backup-throttle")
        makeContainer(s, documents: 800)
        s.mkdir("out")
        let archiver = BackupArchiver()
        archiver.progressInterval = 3600
        var calls = 0
        _ = try? archiver.write(source: source(s), to: URL(fileURLWithPath: s.path("out/t.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test", progress: { _, _, _ in calls += 1 })
        T.equal(calls, 1, "with a long interval progress is reported once, not for each of 800 files")
    }

    // a tree too large to measure gives no estimate but still backs up
    do {
        let s = Scratch("backup-bound")
        makeContainer(s, documents: 120)
        s.mkdir("out")
        let archiver = BackupArchiver()
        archiver.estimateNodeLimit = 40
        var estimated: Int64?
        let result = try? archiver.write(source: source(s), to: URL(fileURLWithPath: s.path("out/e.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test", estimate: { estimated = $0 })
        T.equal(result?.fileCount, 120, "a tree past the measuring bound is still backed up in full")
        T.check(estimated == nil, "but no total is claimed for it")
    }

    T.section("BackupRestorer")
    // bad archives are refused and nothing in the app changes
    do {
        let s = Scratch("restore-bad")
        let archive = URL(fileURLWithPath: s.path("good.zip"))
        try? makeBackup(at: archive, entries: [
            ("Documents/a.txt", Data("backup copy of a".utf8)),
            ("Documents/sub/b.txt", Data("backup copy of b".utf8)),
        ])
        s.write("app/Documents/a.txt", text: "current a")
        let restorer = BackupRestorer()

        // a good one first, so the harness is proven before the damaged ones
        do {
            let outcome = try restorer.restore(archiveURL: archive, bundleIdentifier: "com.example.app", containerPath: s.path("app"))
            T.equal(outcome.filesRestored, 2, "a good backup restores both files")
            T.equal(s.read("app/Documents/a.txt"), Data("backup copy of a".utf8), "an existing file is replaced")
            T.equal(s.read("app/Documents/sub/b.txt"), Data("backup copy of b".utf8), "a missing folder is recreated")
        } catch { T.check(false, "a good backup restores (\(error))") }

        func message(_ work: () throws -> Void) -> String {
            do { try work(); return "" } catch { return error.localizedDescription }
        }

        // wrong app
        s.write("app2/Documents/a.txt", text: "current a")
        T.check(message { _ = try restorer.restore(archiveURL: archive, bundleIdentifier: "com.other.app", containerPath: s.path("app2")) }.contains("does not match"), "a backup of another app is refused")
        T.equal(s.read("app2/Documents/a.txt"), Data("current a".utf8), "and nothing is written")

        // a damaged file: flip a byte of its stored payload
        let damaged = URL(fileURLWithPath: s.path("damaged.zip"))
        try? makeBackup(at: damaged, entries: [
            ("Documents/a.txt", Data("ZZZ-original-payload-ZZZ".utf8)),
        ])
        if var bytes = FileManager.default.contents(atPath: damaged.path), let at = bytes.range(of: Data("original".utf8)) {
            bytes[at.lowerBound] ^= 0x01
            try? bytes.write(to: damaged)
        } else { T.check(false, "the test can find the payload to damage") }
        s.write("app3/Documents/a.txt", text: "current a")
        let flipped = message { _ = try restorer.restore(archiveURL: damaged, bundleIdentifier: "com.example.app", containerPath: s.path("app3")) }
        T.check(!flipped.isEmpty, "a damaged file stops the restore (\(flipped))")
        T.equal(s.read("app3/Documents/a.txt"), Data("current a".utf8), "the file it would have replaced is untouched")
        T.equal(leftovers(s.path("app3")), [], "and no half-written file is left")

        // a manifest that does not match its recorded hash
        let stomped = URL(fileURLWithPath: s.path("stomped.zip"))
        try? makeBackup(at: stomped, entries: [("Documents/a.txt", Data("x".utf8))], stompManifestHash: true)
        T.check(message { _ = try restorer.restore(archiveURL: stomped, bundleIdentifier: "com.example.app", containerPath: s.path("app3")) }.contains("Manifest checksum"), "a changed manifest is refused")
        T.check(message { _ = try restorer.manifest(of: stomped) }.contains("Manifest checksum"), "and the picker refuses it too")

        // a manifest that lies about a file's hash or size
        let liar = URL(fileURLWithPath: s.path("liar.zip"))
        try? makeBackup(at: liar, entries: [("Documents/a.txt", Data("real".utf8))],
                        manifest: [BackupManifestEntry(path: "Documents/a.txt", size: 4, sha256: String(repeating: "a", count: 64))])
        T.check(message { _ = try restorer.restore(archiveURL: liar, bundleIdentifier: "com.example.app", containerPath: s.path("app3")) }.contains("Checksum mismatch"), "a wrong hash in the manifest is caught")
        let sizeLiar = URL(fileURLWithPath: s.path("size-liar.zip"))
        try? makeBackup(at: sizeLiar, entries: [("Documents/a.txt", Data("real".utf8))],
                        manifest: [BackupManifestEntry(path: "Documents/a.txt", size: 9, sha256: StreamingSHA256.hex(of: Data("real".utf8)))])
        T.check(message { _ = try restorer.restore(archiveURL: sizeLiar, bundleIdentifier: "com.example.app", containerPath: s.path("app3")) }.contains("Size mismatch"), "a wrong size in the manifest is caught")

        // a manifest that names a file the archive does not have
        let missing = URL(fileURLWithPath: s.path("missing.zip"))
        try? makeBackup(at: missing, entries: [("Documents/a.txt", Data("real".utf8))],
                        manifest: [BackupManifestEntry(path: "Documents/ghost.txt", size: 1, sha256: StreamingSHA256.hex(of: Data("x".utf8)))])
        T.check(message { _ = try restorer.restore(archiveURL: missing, bundleIdentifier: "com.example.app", containerPath: s.path("app3")) }.contains("missing"), "a file the archive lacks is reported")

        // paths that would escape the container
        for bad in ["Documents/../../escape.txt", "/etc/escape.txt", "Other/escape.txt", "escape.txt"] {
            let evil = URL(fileURLWithPath: s.path("evil-\(abs(bad.hashValue)).zip"))
            try? makeBackup(at: evil, entries: [(bad, Data("pwn".utf8))])
            let said = message { _ = try restorer.restore(archiveURL: evil, bundleIdentifier: "com.example.app", containerPath: s.path("app3")) }
            T.check(!said.isEmpty, "a backup naming “\(bad)” is refused (\(said))")
        }
        T.check(!s.exists("escape.txt") && !s.exists("app3/escape.txt") && !s.exists("../escape.txt"), "nothing escaped the container")

        // a destination with a name nearly as long as a name can be, beside a file named like old scratch files
        let longName = String(repeating: "n", count: 250)
        let long = URL(fileURLWithPath: s.path("long.zip"))
        try? makeBackup(at: long, entries: [("Documents/\(longName)", Data("long".utf8)), ("Documents/x", Data("x".utf8))])
        s.write("app6/Documents/x.escapeos-restore", text: "mine")
        s.write("app6/Documents/\(longName).escapeos-restore", text: "also mine")
        let longOutcome = try? restorer.restore(archiveURL: long, bundleIdentifier: "com.example.app", containerPath: s.path("app6"))
        T.equal(longOutcome?.filesRestored, 2, "a 250-character file name restores")
        T.equal(s.read("app6/Documents/\(longName)"), Data("long".utf8), "with its content")
        T.equal(s.read("app6/Documents/x.escapeos-restore"), Data("mine".utf8), "a file that merely looks like a scratch file is not deleted")

        // an empty manifest
        let empty = URL(fileURLWithPath: s.path("empty.zip"))
        try? makeBackup(at: empty, entries: [])
        T.check(message { _ = try restorer.restore(archiveURL: empty, bundleIdentifier: "com.example.app", containerPath: s.path("app3")) }.contains("empty"), "an empty backup is refused")

        // a folder where a file belongs
        s.mkdir("app4/Documents/a.txt")
        T.check(message { _ = try restorer.restore(archiveURL: archive, bundleIdentifier: "com.example.app", containerPath: s.path("app4")) }.contains("folder already exists"), "a folder in the way is reported, not replaced")
        T.check(s.exists("app4/Documents/a.txt") && leftovers(s.path("app4")).isEmpty, "and the folder is still there")

        // a link where a file belongs is replaced, not followed
        s.write("outside.txt", text: "must not change")
        s.mkdir("app5/Documents")
        try? FileManager.default.createSymbolicLink(atPath: s.path("app5/Documents/a.txt"), withDestinationPath: s.path("outside.txt"))
        _ = try? restorer.restore(archiveURL: archive, bundleIdentifier: "com.example.app", containerPath: s.path("app5"))
        T.equal(s.read("outside.txt"), Data("must not change".utf8), "a link at the destination is not written through")
        T.equal(s.read("app5/Documents/a.txt"), Data("backup copy of a".utf8), "it is replaced by the real file")
    }

    // restoring only what was chosen
    do {
        let s = Scratch("restore-select")
        let archive = URL(fileURLWithPath: s.path("b.zip"))
        try? makeBackup(at: archive, entries: [
            ("Documents/keep/a.txt", Data("A".utf8)),
            ("Documents/keep/b.txt", Data("B".utf8)),
            ("Documents/other/c.txt", Data("C".utf8)),
            ("Library/d.txt", Data("D".utf8)),
        ])
        s.write("app/Documents/keep/a.txt", text: "old A")
        s.write("app/Documents/other/c.txt", text: "old C")
        var told: Int64?
        let outcome = try? BackupRestorer().restore(
            archiveURL: archive, bundleIdentifier: "com.example.app", containerPath: s.path("app"),
            selection: BackupSelection(paths: ["Documents/keep", "Library/d.txt"]),
            estimate: { told = $0 }
        )
        T.equal(outcome?.filesRestored, 3, "three files are in the choice")
        T.equal(told, 3, "the bytes to restore are told up front")
        T.equal(s.read("app/Documents/keep/a.txt"), Data("A".utf8), "a chosen file is restored")
        T.equal(s.read("app/Documents/keep/b.txt"), Data("B".utf8), "a chosen folder is restored whole")
        T.equal(s.read("app/Documents/other/c.txt"), Data("old C".utf8), "a file that was not chosen is left alone")
        T.equal(s.read("app/Library/d.txt"), Data("D".utf8), "a chosen file in a folder that did not exist is created")
        var message = ""
        do { _ = try BackupRestorer().restore(archiveURL: archive, bundleIdentifier: "com.example.app", containerPath: s.path("app"), selection: BackupSelection(paths: ["tmp/none"])) } catch { message = error.localizedDescription }
        T.check(message.contains("None of the chosen"), "a choice with nothing in the backup is refused")
    }

    // cancelling a restore, between files and inside a big one
    do {
        let s = Scratch("restore-cancel")
        var entries: [(path: String, data: Data)] = (0..<200).map { ("Documents/f\($0).txt", Data("file \($0)".utf8)) }
        entries.append(("Library/huge.bin", Data(repeating: 0x33, count: 9 * 1024 * 1024)))
        let archive = URL(fileURLWithPath: s.path("b.zip"))
        try? makeBackup(at: archive, entries: entries)
        s.write("app/Library/huge.bin", text: "old huge")

        var done = 0
        var e1: Error?
        let eager = BackupRestorer()
        eager.progressInterval = 0
        do {
            _ = try eager.restore(archiveURL: archive, bundleIdentifier: "com.example.app", containerPath: s.path("app"),
                                             progress: { d, _, _ in done = d }, isCancelled: { done >= 20 })
        } catch { e1 = error }
        T.check((e1 as? BackupError).map { if case .cancelled = $0 { return true } else { return false } } ?? false, "cancelling between files stops with 'cancelled'")
        T.check(snapshot(s.path("app/Documents")).count < 200, "and stops partway")
        T.equal(leftovers(s.path("app")), [], "leaving no half-written file")

        var written: Int64 = 0
        var e2: Error?
        do {
            _ = try BackupRestorer().restore(archiveURL: archive, bundleIdentifier: "com.example.app", containerPath: s.path("app"),
                                             selection: BackupSelection(paths: ["Library/huge.bin"]),
                                             bytes: { written += $0 }, isCancelled: { written >= Int64(FileService.transferChunkBytes) })
        } catch { e2 = error }
        T.check((e2 as? BackupError).map { if case .cancelled = $0 { return true } else { return false } } ?? false, "cancelling inside a big file stops with 'cancelled'")
        T.equal(s.read("app/Library/huge.bin"), Data("old huge".utf8), "the file it would have replaced is untouched")
        T.equal(leftovers(s.path("app")), [], "and its scratch copy is gone")
    }

    // the reader notices a damaged stored entry on its own, before any hash is compared
    do {
        let s = Scratch("stream-crc")
        let archive = URL(fileURLWithPath: s.path("b.zip"))
        try? makeBackup(at: archive, entries: [("Documents/a.txt", Data("ABCDEFGH-payload-IJKLMNOP".utf8))])
        if var bytes = FileManager.default.contents(atPath: archive.path), let at = bytes.range(of: Data("payload".utf8)) {
            bytes[at.lowerBound] ^= 0x01
            try? bytes.write(to: archive)
        }
        if let reader = try? ZipReader(url: archive), let member = reader.entries["Documents/a.txt"] {
            var failed = false
            do { try reader.streamEntry(member) { _ in } } catch ZipReaderError.checksumMismatch { failed = true } catch {}
            T.check(failed, "streaming a damaged entry ends in a checksum error")
            var whole = false
            do { _ = try reader.readEntry(member) } catch ZipReaderError.checksumMismatch { whole = true } catch {}
            T.check(whole, "and so does reading it whole")
        } else { T.check(false, "the damaged archive still opens") }
    }

    // a deflated entry (a backup repackaged by another tool) restores too
    if let zipTool = Optional("/usr/bin/zip"), FileManager.default.isExecutableFile(atPath: zipTool) {
        let s = Scratch("restore-deflate")
        s.write("pack/Documents/words.txt", text: String(repeating: "deflate me ", count: 500))
        let plain = URL(fileURLWithPath: s.path("plain.zip"))
        try? makeBackup(at: plain, entries: [("Documents/words.txt", s.read("pack/Documents/words.txt") ?? Data())])
        // unpack the manifest and metadata, then repack everything with deflate
        _ = runTool("/usr/bin/unzip", ["-o", "-q", plain.path, "-d", s.path("unpacked")])
        if let ok = runTool("/bin/sh", ["-c", "cd '\(s.path("unpacked"))' && /usr/bin/zip -q -r -9 '\(s.path("deflated.zip"))' ."]) {
            T.equal(ok.status, 0, "the test can repack a backup with deflate")
        }
        let deflated = URL(fileURLWithPath: s.path("deflated.zip"))
        if let reader = try? ZipReader(url: deflated), let member = reader.entries["Documents/words.txt"] {
            T.check(member.compression == 8, "the repacked entry really is deflated")
            T.check(!reader.canStream(member), "and is not streamed")
        } else { T.check(false, "the repacked archive opens") }
        // zip -r from a folder puts the entries at the root, as a backup does
        let outcome = try? BackupRestorer().restore(archiveURL: deflated, bundleIdentifier: "com.example.app", containerPath: s.path("app"))
        T.equal(outcome?.filesRestored, 1, "a deflated backup restores")
        T.equal(s.read("app/Documents/words.txt"), s.read("pack/Documents/words.txt"), "byte for byte")
    }

    if slowTests {
        // More than the old 512 MB limit, and a single file bigger than the old limit.
        let s = Scratch("backup-huge")
        s.mkdir("app/Documents")
        s.mkdir("out")
        var total = 0
        for i in 0..<6 {
            s.write("app/Documents/chunk\(i).bin", bytes: 110 * 1024 * 1024, fill: UInt8(i * 30))
            total += 110 * 1024 * 1024
        }
        let start = Date()
        var result: BackupResult?
        var failure: Error?
        do {
            result = try BackupArchiver().write(source: source(s), to: URL(fileURLWithPath: s.path("out/huge.zip")), spaceDirectory: s.path("out"), escapeOSVersion: "test")
        } catch { failure = error }
        T.check(failure == nil, "660 MB backs up (\(failure.map { "\($0)" } ?? "ok"), \(Int(Date().timeIntervalSince(start))) s)")
        T.equal(result?.totalBytes, Int64(total), "the byte total is 660 MB")
        let target = Scratch("backup-huge-target")
        target.mkdir("app")
        let outcome = try? BackupRestorer().restore(archiveURL: URL(fileURLWithPath: s.path("out/huge.zip")), bundleIdentifier: "com.example.app", containerPath: target.path("app"))
        T.equal(outcome?.filesRestored, 6, "and restores")
        for i in 0..<6 {
            T.equal(sha256sum(s.path("app/Documents/chunk\(i).bin")), sha256sum(target.path("app/Documents/chunk\(i).bin")), "chunk \(i) restored byte for byte")
        }
    }
}
