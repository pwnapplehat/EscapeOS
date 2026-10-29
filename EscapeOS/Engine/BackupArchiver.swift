import Foundation

/// Progress callback for backup export.
typealias BackupProgress = (_ filesProcessed: Int, _ totalBytes: Int64, _ currentFile: String) -> Void

/// Result of a completed backup export.
struct BackupResult {
    let archiveURL: URL
    let fileCount: Int
    let totalBytes: Int64
    let manifestSHA256: String
    let metadata: BackupMetadata
}

/// Errors specific to backup / restore archives.
enum BackupError: Error, LocalizedError {
    case containerInaccessible(String)
    case writeFailed(String)
    case cancelled
    case invalidArchive(String)
    case restoreBlocked(String)
    case appNotInstalled(String)
    /// The archive would not fit on disk. The message is complete and shown as-is.
    case insufficientSpace(String)

    var errorDescription: String? {
        switch self {
        case .containerInaccessible(let m): return "Container inaccessible: \(m)"
        case .writeFailed(let m): return "Failed to write backup: \(m)"
        case .cancelled: return "Backup was cancelled."
        case .invalidArchive(let m): return "Invalid backup archive: \(m)"
        case .restoreBlocked(let m): return m
        case .appNotInstalled(let id): return "App is not installed: \(id)"
        case .insufficientSpace(let m): return m
        }
    }
}

/// Which app a backup is of.
struct BackupSource {
    let bundleIdentifier: String
    let appName: String
    let containerPath: String
}

/// Writes a backup: an app's Data container (Documents, Library, tmp), or chosen parts of it, as a
/// zip with a manifest of SHA-256 hashes. Read-only with respect to the app.
///
/// There is no cap on how many files or how much data. Every file is streamed through, hashed as it
/// goes, so memory stays flat; the manifest is written to a scratch file as the files go by instead
/// of being built up in memory; and the zip is written in ZIP64 form when it needs to be. The only
/// limit left is the free space on the device, which is checked first and again as the file grows.
final class BackupArchiver {

    private let files: FileService

    init(files: FileService = FileService()) {
        self.files = files
    }

    /// The size walk before the backup starts stops after this many entries on a huge tree; the
    /// backup then simply shows no percentage rather than a wrong one.
    var estimateNodeLimit = 200_000

    /// What the manifest's scratch file is called, after the archive's name.
    static let spoolSuffix = ".manifest.tmp"

    /// A backup that was cut off (the app was closed or killed part-way) leaves its archive, which
    /// has no directory and cannot be opened, and its scratch manifest, which only exists while a
    /// backup is being written. Backups run one at a time, so a scratch manifest found at the start
    /// of one is a dead backup's: remove it and the archive it belongs to.
    static func removeOrphans(in folder: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return }
        for name in names where name.hasSuffix(".zip" + spoolSuffix) {
            let spool = (folder as NSString).appendingPathComponent(name)
            try? fm.removeItem(atPath: spool)
            try? fm.removeItem(atPath: String(spool.dropLast(spoolSuffix.count)))
        }
    }

    /// How often `progress` is told about files going by. A backup of a hundred thousand small files
    /// would otherwise flood whatever shows the progress.
    var progressInterval: TimeInterval = 0.1

    /// - Parameters:
    ///   - selection: back up only these files and folders (issue #7). Nil backs up everything.
    ///   - spaceDirectory: the folder the archive is written to, whose free space is checked.
    ///   - estimate: told, once and before anything is written, how many bytes there are to back up,
    ///     so progress can be a percentage. Not called when the tree is too large to measure.
    ///   - bytes: told of bytes written, as they are written (a single file can be large).
    ///   - progress: told which file is being written and how many files and bytes are done so far.
    func write(
        source: BackupSource,
        selection: BackupSelection? = nil,
        to outURL: URL,
        spaceDirectory: String,
        escapeOSVersion: String,
        estimate: ((Int64) -> Void)? = nil,
        bytes: ((Int64) -> Void)? = nil,
        progress: BackupProgress? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> BackupResult {
        Self.removeOrphans(in: outURL.deletingLastPathComponent().path)
        let zip = ZipWriter()
        let spoolPath = outURL.path + Self.spoolSuffix
        let spool: ManifestSpool
        do {
            try zip.begin(at: outURL)
            spool = try ManifestSpool(path: spoolPath)
        } catch {
            zip.abandon()
            try? FileManager.default.removeItem(at: outURL)
            throw BackupError.writeFailed(error.localizedDescription)
        }
        func cleanUp() {
            zip.abandon()
            spool.discard()
            try? FileManager.default.removeItem(at: outURL)
        }

        let run = Run(ownFiles: [outURL.path, spoolPath], zip: zip, spool: spool, bytes: bytes, progress: progress, isCancelled: isCancelled, interval: progressInterval)
        do {
            try spaceCheck(source: source, selection: selection, spaceDirectory: spaceDirectory, estimate: estimate)
            try collect(source: source, selection: selection, run: run)
        } catch let error as BackupError {
            cleanUp()
            throw error
        } catch is JobCancelled {
            cleanUp()
            throw BackupError.cancelled
        } catch {
            cleanUp()
            throw BackupError.containerInaccessible(error.localizedDescription)
        }

        do {
            // The manifest goes in last, from its scratch file, and its hash is taken as it goes.
            let manifestHash = try spool.finish(into: zip, name: BackupPaths.manifestFileName)
            let metadata = BackupMetadata(
                bundleIdentifier: source.bundleIdentifier,
                appName: source.appName,
                containerPath: source.containerPath,
                createdAt: BackupPaths.isoTimestamp(),
                fileCount: run.fileCount,
                totalBytes: run.totalBytes,
                manifestSHA256: manifestHash,
                escapeOSVersion: escapeOSVersion,
                isPartial: selection == nil ? nil : true,
                scope: selection?.paths
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try zip.addFile(name: BackupPaths.metadataFileName, data: try encoder.encode(metadata))
            try zip.finish()
            spool.discard()
            return BackupResult(
                archiveURL: outURL,
                fileCount: run.fileCount,
                totalBytes: run.totalBytes,
                manifestSHA256: manifestHash,
                metadata: metadata
            )
        } catch {
            cleanUp()
            throw BackupError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Pre-flight

    /// Sizes are cheap to read and the archive can be as large as the data it holds, so check before
    /// writing anything. The walk is bounded, so a container with a huge cache cannot stall the
    /// start; a partial total can only refuse, never allow.
    private func spaceCheck(
        source: BackupSource,
        selection: BackupSelection?,
        spaceDirectory: String,
        estimate: ((Int64) -> Void)?
    ) throws {
        var needed: Int64 = 0
        var complete = true
        let roots: [String]
        if let selection {
            roots = selection.paths
        } else {
            roots = BackupSelection.allowedRoots.filter { files.isDirectory(at: (source.containerPath as NSString).appendingPathComponent($0)) }
        }
        for relative in roots {
            let absolute = (source.containerPath as NSString).appendingPathComponent(relative)
            let measured = files.treeBytesBounded(at: absolute, maxNodes: estimateNodeLimit)
            needed += measured.bytes
            if !measured.complete { complete = false }
        }
        if complete { estimate?(needed) }
        if case .notEnough(let need, let available) = SpaceCheck.verdict(
            needed: needed,
            available: files.availableCapacity(at: spaceDirectory)
        ) {
            throw BackupError.insufficientSpace(
                SpaceCheck.message(for: "back up this app", needed: need, available: available)
            )
        }
    }

    // MARK: - Walking

    /// Everything that changes while the files go into the archive.
    private final class Run {
        let zip: ZipWriter
        let spool: ManifestSpool
        let bytes: ((Int64) -> Void)?
        let progress: BackupProgress?
        let isCancelled: () -> Bool
        let interval: TimeInterval
        var fileCount = 0
        var totalBytes: Int64 = 0
        var lastProgress: TimeInterval = -.infinity

        /// What this backup is writing, as path components. When an app's own data holds the Backups
        /// folder (EscapeOS backing itself up), the walk must not read the archive it is writing.
        let ownFiles: [[String]]

        init(
            ownFiles: [String],
            zip: ZipWriter,
            spool: ManifestSpool,
            bytes: ((Int64) -> Void)?,
            progress: BackupProgress?,
            isCancelled: @escaping () -> Bool,
            interval: TimeInterval
        ) {
            self.ownFiles = ownFiles.map { PathContainment.components(of: $0) }
            self.zip = zip
            self.spool = spool
            self.bytes = bytes
            self.progress = progress
            self.isCancelled = isCancelled
            self.interval = interval
        }

        func checkCancelled() throws {
            if isCancelled() { throw BackupError.cancelled }
        }

        /// True for the archive and manifest being written, and for a restore's half-written file.
        func isOwnFile(_ path: String) -> Bool {
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(BackupRestorer.scratchPrefix) { return true }
            guard name.hasSuffix(".zip") || name.hasSuffix(BackupArchiver.spoolSuffix) else { return false }
            return ownFiles.contains(PathContainment.components(of: path))
        }

        var observer: TransferObserver {
            TransferObserver(bytes: { [bytes] in bytes?($0) }, isCancelled: isCancelled)
        }
    }

    private func collect(source: BackupSource, selection: BackupSelection?, run: Run) throws {
        if let selection {
            var foundAny = false
            for relative in selection.paths {
                try run.checkCancelled()
                let absolute = (source.containerPath as NSString).appendingPathComponent(relative)
                // Chosen a moment ago, so it can have gone since; a link is never followed.
                guard let attrs = try? files.attributes(at: absolute),
                      let type = attrs[.type] as? FileAttributeType else { continue }
                if type == FileAttributeType.typeDirectory {
                    foundAny = true
                    try walk(path: absolute, relativePrefix: relative, run: run)
                } else if type == FileAttributeType.typeRegular {
                    foundAny = true
                    try addFileEntry(
                        path: absolute,
                        relative: relative,
                        modified: (attrs[.modificationDate] as? Date) ?? Date(),
                        run: run
                    )
                }
            }
            if !foundAny {
                throw BackupError.containerInaccessible(
                    "None of the chosen files or folders could be found in the app's data any more."
                )
            }
            // An empty folder, or files that could not be read, would make a backup with
            // nothing in it that no restore accepts: better to say so now.
            if run.fileCount == 0 {
                throw BackupError.containerInaccessible(
                    "The chosen items contain no files that could be read, so there is nothing to back up."
                )
            }
        } else {
            var foundRoot = false
            for root in BackupSelection.allowedRoots {
                try run.checkCancelled()
                let rootPath = (source.containerPath as NSString).appendingPathComponent(root)
                guard files.isDirectory(at: rootPath) else { continue }
                foundRoot = true
                try walk(path: rootPath, relativePrefix: root, run: run)
            }
            if !foundRoot {
                throw BackupError.containerInaccessible(
                    "Documents, Library, and tmp were not visible after opening \(source.containerPath)"
                )
            }
        }
    }

    private func walk(path: String, relativePrefix: String, run: Run) throws {
        try run.checkCancelled()

        let entries: [FileItem]
        do {
            entries = try files.list(directory: path)
        } catch {
            throw BackupError.containerInaccessible(error.localizedDescription)
        }

        for entry in entries {
            try run.checkCancelled()
            let rel = "\(relativePrefix)/\(entry.name)"

            if entry.isDirectory {
                try walk(path: entry.path, relativePrefix: rel, run: run)
            } else if entry.kind == .regular {
                try addFileEntry(path: entry.path, relative: rel, modified: entry.modified ?? Date(), run: run)
            }
        }
    }

    /// Stream one file into the archive, hashing the bytes as they go, and record it in the
    /// manifest. A file that cannot be read is skipped, as it always was, so one locked file does
    /// not stop the whole backup; a failure to write is not skipped, since the archive would be wrong.
    private func addFileEntry(path: String, relative rel: String, modified: Date, run: Run) throws {
        if run.isOwnFile(path) { return }
        var hasher = StreamingSHA256()
        let size: Int64
        do {
            size = try run.zip.addFile(
                name: rel,
                fromPath: path,
                modified: modified,
                observer: run.observer,
                onChunk: { hasher.update($0) }
            )
        } catch ZipWriterError.unreadable {
            return
        } catch let error as JobCancelled {
            throw error
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }
        do {
            try run.spool.append(BackupManifestEntry(path: rel, size: Int(size), sha256: hasher.finalize()))
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }
        run.fileCount += 1
        run.totalBytes += size
        let now = ProcessInfo.processInfo.systemUptime
        if now - run.lastProgress >= run.interval {
            run.lastProgress = now
            run.progress?(run.fileCount, run.totalBytes, rel)
        }
    }
}

/// The backup's manifest, written to a scratch file one entry at a time as the files go into the
/// archive, so it never has to exist in memory in full. The bytes are exactly what encoding the whole
/// list at once gives (a JSON array of the same objects with sorted keys), so the format of a backup
/// has not changed.
final class ManifestSpool {
    private let path: String
    private var handle: FileHandle?
    private let encoder: JSONEncoder
    private var first = true
    private var buffer = Data()

    init(path: String) throws {
        self.path = path
        FileManager.default.createFile(atPath: path, contents: nil)
        self.handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        buffer.append(contentsOf: Array("[".utf8))
    }

    func append(_ entry: BackupManifestEntry) throws {
        if !first { buffer.append(contentsOf: Array(",".utf8)) }
        first = false
        buffer.append(try encoder.encode(entry))
        if buffer.count >= 256 * 1024 { try flush() }
    }

    private func flush() throws {
        guard let handle, !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// Close the manifest, add it to the archive as `name`, and return its SHA-256.
    func finish(into zip: ZipWriter, name: String) throws -> String {
        buffer.append(contentsOf: Array("]".utf8))
        try flush()
        try handle?.close()
        handle = nil
        var hasher = StreamingSHA256()
        try zip.addFile(name: name, fromPath: path, modified: Date(), onChunk: { hasher.update($0) })
        return hasher.finalize()
    }

    /// Remove the scratch file. Safe to call at any point, and more than once.
    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(atPath: path)
    }
}
