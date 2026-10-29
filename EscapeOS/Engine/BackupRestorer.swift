import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Progress callback for restore operations.
typealias RestoreProgress = (_ filesRestored: Int, _ totalFiles: Int, _ currentFile: String) -> Void

/// Reads a backup and writes its files back into an app's Data container.
///
/// Like writing one, restoring has no cap on how many files or how much data a backup holds. Each
/// file is streamed out of the archive into a scratch file beside its destination while its hash is
/// taken, checked against the manifest, and only then moved into place, so memory stays flat and a
/// damaged file never replaces a good one. The first file that fails stops the restore; the files
/// before it have been restored, as they always were.
final class BackupRestorer {

    struct Outcome {
        let filesRestored: Int
        let bytesWritten: Int64
        let metadata: BackupMetadata
    }

    private let files: FileService

    init(files: FileService = FileService()) {
        self.files = files
    }

    /// How often `progress` is told about files going by.
    var progressInterval: TimeInterval = 0.1

    /// Scratch files start with this. The rest is random and short, so a destination whose own name
    /// is nearly the longest a name can be still fits, and no file the app owns can have the name.
    static let scratchPrefix = ".escapeos-restore-"

    /// A path in `folder` that nothing is at, for a file to be written to before it is moved into place.
    static func scratchPath(inFolder folder: String) -> String {
        for _ in 0..<20 {
            let candidate = (folder as NSString).appendingPathComponent(scratchPrefix + UUID().uuidString.prefix(12))
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return (folder as NSString).appendingPathComponent(scratchPrefix + UUID().uuidString)
    }

    /// The files a backup holds, read from its manifest after checking the manifest against the
    /// checksum recorded in the backup's metadata. For the picker that chooses what to restore.
    func manifest(of archiveURL: URL) throws -> [BackupManifestEntry] {
        let reader = try ZipReader(url: archiveURL)
        return try verifiedManifest(in: reader).manifest
    }

    private func verifiedManifest(in reader: ZipReader) throws -> (metadata: BackupMetadata, manifest: [BackupManifestEntry]) {
        guard reader.entries[BackupPaths.manifestFileName] != nil else {
            throw BackupError.invalidArchive("Missing \(BackupPaths.manifestFileName)")
        }
        guard reader.entries[BackupPaths.metadataFileName] != nil else {
            throw BackupError.invalidArchive("Missing \(BackupPaths.metadataFileName)")
        }
        let metadata = try JSONDecoder().decode(
            BackupMetadata.self,
            from: try reader.readEntry(named: BackupPaths.metadataFileName)
        )
        let manifestData = try reader.readEntry(named: BackupPaths.manifestFileName)
        guard StreamingSHA256.hex(of: manifestData) == metadata.manifestSHA256 else {
            throw BackupError.invalidArchive("Manifest checksum does not match backup metadata.")
        }
        return (metadata, try JSONDecoder().decode([BackupManifestEntry].self, from: manifestData))
    }

    /// - Parameters:
    ///   - selection: restore only these files and folders of the backup (issue #7). Nil restores
    ///     all of it. A path whose folder no longer exists in the app is recreated.
    ///   - access: runs the writing with whatever access to the container it needs.
    ///   - estimate: told, once and before anything is written, how many bytes are to be restored.
    ///   - bytes: told of bytes written, as they are written (a single file can be large).
    func restore(
        archiveURL: URL,
        bundleIdentifier: String,
        containerPath: String,
        selection: BackupSelection? = nil,
        access: (() throws -> Void) throws -> Void = { try $0() },
        estimate: ((Int64) -> Void)? = nil,
        bytes: ((Int64) -> Void)? = nil,
        progress: RestoreProgress? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> Outcome {
        let reader = try ZipReader(url: archiveURL)
        let (metadata, fullManifest) = try verifiedManifest(in: reader)
        guard metadata.bundleIdentifier == bundleIdentifier else {
            throw BackupError.restoreBlocked(
                "Backup bundle ID \(metadata.bundleIdentifier) does not match \(bundleIdentifier)."
            )
        }
        guard !fullManifest.isEmpty else {
            throw BackupError.invalidArchive("Backup manifest is empty.")
        }
        // The whole manifest has been checked against the metadata above; a selection narrows what
        // is written, never what is verified, and each file written is still checked against its
        // own hash below.
        let manifest: [BackupManifestEntry]
        if let selection {
            manifest = selection.filter(fullManifest)
            guard !manifest.isEmpty else {
                throw BackupError.restoreBlocked("None of the chosen items are in this backup.")
            }
        } else {
            manifest = fullManifest
        }
        estimate?(manifest.reduce(Int64(0)) { $0 + Int64($1.size) })

        let observer = TransferObserver(bytes: { bytes?($0) }, isCancelled: isCancelled)
        var filesRestored = 0
        var bytesWritten: Int64 = 0
        var lastProgress: TimeInterval = -.infinity

        do {
            try access {
                for entry in manifest {
                    if isCancelled() { throw BackupError.cancelled }
                    try validateRelativePath(entry.path)
                    guard let member = reader.entries[entry.path] else {
                        throw BackupError.invalidArchive("Archive is missing \(entry.path)")
                    }
                    let absolute = (containerPath as NSString).appendingPathComponent(entry.path)
                    let written = try restoreFile(entry: entry, member: member, reader: reader, to: absolute, observer: observer)
                    filesRestored += 1
                    bytesWritten += written
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastProgress >= progressInterval || filesRestored == manifest.count {
                        lastProgress = now
                        progress?(filesRestored, manifest.count, entry.path)
                    }
                }
            }
        } catch is JobCancelled {
            throw BackupError.cancelled
        }
        return Outcome(filesRestored: filesRestored, bytesWritten: bytesWritten, metadata: metadata)
    }

    /// Write one file: out of the archive into a scratch file, checked, then moved over the
    /// destination. The destination is not touched unless the file is whole and matches its hash.
    private func restoreFile(
        entry: BackupManifestEntry,
        member: ZipMember,
        reader: ZipReader,
        to absolute: String,
        observer: TransferObserver
    ) throws -> Int64 {
        let parent = (absolute as NSString).deletingLastPathComponent
        if !files.exists(at: parent) {
            try files.createDirectory(at: parent)
        }
        if files.existingKind(at: absolute) == .directory {
            throw BackupError.restoreBlocked("A folder already exists where “\(entry.path)” belongs, so it was not restored.")
        }

        let scratch = Self.scratchPath(inFolder: parent)
        guard FileManager.default.createFile(atPath: scratch, contents: nil),
              let handle = FileHandle(forWritingAtPath: scratch) else {
            throw BackupError.restoreBlocked("Could not restore “\(entry.path)”: the file could not be created.")
        }
        var committed = false
        var closed = false
        defer {
            if !closed { try? handle.close() }
            if !committed { try? FileManager.default.removeItem(atPath: scratch) }
        }

        var hasher = StreamingSHA256()
        var size: Int64 = 0
        func accept(_ piece: Data) throws {
            try observer.checkCancelled()
            do { try handle.write(contentsOf: piece) } catch {
                throw BackupError.restoreBlocked("Could not restore “\(entry.path)”: \(error.localizedDescription)")
            }
            hasher.update(piece)
            size += Int64(piece.count)
            observer.bytes(Int64(piece.count))
        }

        do {
            if reader.canStream(member) {
                try reader.streamEntry(member, body: accept)
            } else {
                try accept(try reader.readEntry(member))
            }
        } catch let error as ZipReaderError {
            throw BackupError.invalidArchive("\(error.localizedDescription) (\(entry.path))")
        }
        guard hasher.finalize() == entry.sha256 else {
            throw BackupError.invalidArchive("Checksum mismatch for \(entry.path)")
        }
        guard size == Int64(entry.size) else {
            throw BackupError.invalidArchive("Size mismatch for \(entry.path)")
        }
        closed = true
        do { try handle.close() } catch {
            throw BackupError.restoreBlocked("Could not restore “\(entry.path)”: \(error.localizedDescription)")
        }

        // A link at the destination is replaced, not followed.
        if files.isSymlink(at: absolute) { try? FileManager.default.removeItem(atPath: absolute) }
        guard rename(scratch, absolute) == 0 else {
            let reason = String(cString: strerror(errno))
            throw BackupError.restoreBlocked("Could not restore “\(entry.path)”: \(reason)")
        }
        committed = true
        return size
    }

    private func validateRelativePath(_ path: String) throws {
        if path.hasPrefix("/") || path.contains("..") {
            throw BackupError.restoreBlocked("Unsafe path in backup: \(path)")
        }
        let root = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        guard let root, BackupSelection.allowedRoots.contains(root) else {
            throw BackupError.restoreBlocked("Backup path outside allowed roots: \(path)")
        }
    }
}
