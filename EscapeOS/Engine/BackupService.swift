import Foundation
import CryptoKit

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

/// Exports an app's Data container (Documents, Library, tmp) into a zip
/// archive with a manifest of SHA-256 hashes. Read-only with respect to the
/// target app during export.
final class BackupService {

    private let escape = SandboxEscape()
    private let files = FileService()

    /// Subtrees of a Data container we export and restore.
    static let backupRoots = BackupSelection.allowedRoots

    /// Maximum number of files / total bytes as a safety guard.
    private let maxFiles = 5000
    private let maxTotalBytes: Int64 = 512 * 1024 * 1024

    /// Export the given app's container to a zip inside Documents/Backups.
    ///
    /// - Parameters:
    ///   - selection: back up only these files and folders (issue #7). Nil backs up everything.
    ///   - estimate: told, once and before anything is written, roughly how many bytes there are
    ///     to back up, so progress can be a percentage. A lower bound on a very large tree.
    func exportBackup(
        for app: InstalledApp,
        selection: BackupSelection? = nil,
        estimate: ((Int64) -> Void)? = nil,
        progress: BackupProgress? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> BackupResult {
        let backupsDir = try BackupPaths.ensureBackupsDirectory()
        let stamp = BackupPaths.fileTimestamp()
        let safeName = app.name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        let kind = selection == nil ? "backup" : "partial"
        let outURL = backupsDir.appendingPathComponent("\(safeName)_\(kind)_\(stamp).zip")

        var manifest: [BackupManifestEntry] = []
        var totalBytes: Int64 = 0

        let zip = ZipWriter()
        do {
            try zip.begin(at: outURL)
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }

        do {
            try escape.withHandle(for: app.containerPath) { _ in
                // Sizes are cheap to read and the archive can be as large as the data it holds,
                // so check before writing anything. The walk refuses more than maxTotalBytes
                // anyway, so that is the most this can need. The walk is bounded, so a container with
                // a huge cache cannot stall the start; a partial total can only refuse, never allow.
                var needed: Int64 = 0
                if let selection {
                    for path in selection.paths {
                        let absolute = (app.containerPath as NSString).appendingPathComponent(path)
                        needed += files.treeBytes(at: absolute, maxNodes: 100_000)
                    }
                } else {
                    for root in Self.backupRoots {
                        let rootPath = (app.containerPath as NSString).appendingPathComponent(root)
                        if files.isDirectory(at: rootPath) { needed += files.treeBytes(at: rootPath, maxNodes: 100_000) }
                    }
                }
                needed = min(needed, maxTotalBytes)
                estimate?(needed)
                if case .notEnough(let need, let available) = SpaceCheck.verdict(
                    needed: needed,
                    available: files.availableCapacity(at: backupsDir.path)
                ) {
                    throw BackupError.insufficientSpace(
                        SpaceCheck.message(for: "back up this app", needed: need, available: available)
                    )
                }
                if let selection {
                    var foundAny = false
                    for relative in selection.paths {
                        if isCancelled() { throw BackupError.cancelled }
                        let absolute = (app.containerPath as NSString).appendingPathComponent(relative)
                        // Chosen a moment ago, so it can have gone since; a link is never followed.
                        guard let type = (try? files.attributes(at: absolute))?[.type] as? FileAttributeType else { continue }
                        if type == FileAttributeType.typeDirectory {
                            foundAny = true
                            try walk(
                                path: absolute,
                                relativePrefix: relative,
                                zip: zip,
                                manifest: &manifest,
                                totalBytes: &totalBytes,
                                progress: progress,
                                isCancelled: isCancelled
                            )
                        } else if type == FileAttributeType.typeRegular {
                            foundAny = true
                            // A folder is checked as the walk enters it; a chosen file is checked here.
                            if manifest.count >= maxFiles || totalBytes > maxTotalBytes {
                                throw BackupError.writeFailed("Safety limit exceeded (too many files or too much data).")
                            }
                            try addFileEntry(
                                path: absolute,
                                relative: relative,
                                zip: zip,
                                manifest: &manifest,
                                totalBytes: &totalBytes,
                                progress: progress
                            )
                        }
                    }
                    if !foundAny {
                        throw BackupError.containerInaccessible(
                            "None of the chosen files or folders could be found in the app's data any more."
                        )
                    }
                } else {
                    var foundRoot = false
                    for root in Self.backupRoots {
                        if isCancelled() { throw BackupError.cancelled }
                        let rootPath = (app.containerPath as NSString).appendingPathComponent(root)
                        guard files.isDirectory(at: rootPath) else { continue }
                        foundRoot = true
                        try walk(
                            path: rootPath,
                            relativePrefix: root,
                            zip: zip,
                            manifest: &manifest,
                            totalBytes: &totalBytes,
                            progress: progress,
                            isCancelled: isCancelled
                        )
                    }
                    if !foundRoot {
                        throw BackupError.containerInaccessible(
                            "Documents, Library, and tmp were not visible after opening \(app.containerPath)"
                        )
                    }
                }
            }
        } catch let error as BackupError {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw BackupError.containerInaccessible(error.localizedDescription)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let manifestHash = SHA256.hash(data: manifestData)
            .map { String(format: "%02x", $0) }
            .joined()
        try zip.addFile(name: BackupPaths.manifestFileName, data: manifestData)

        let metadata = BackupMetadata(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            containerPath: app.containerPath,
            createdAt: BackupPaths.isoTimestamp(),
            fileCount: manifest.count,
            totalBytes: totalBytes,
            manifestSHA256: manifestHash,
            escapeOSVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            isPartial: selection == nil ? nil : true,
            scope: selection?.paths
        )
        let metadataData = try encoder.encode(metadata)
        try zip.addFile(name: BackupPaths.metadataFileName, data: metadataData)

        do {
            try zip.finish()
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw BackupError.writeFailed(error.localizedDescription)
        }

        return BackupResult(
            archiveURL: outURL,
            fileCount: manifest.count,
            totalBytes: totalBytes,
            manifestSHA256: manifestHash,
            metadata: metadata
        )
    }

    private func walk(
        path: String,
        relativePrefix: String,
        zip: ZipWriter,
        manifest: inout [BackupManifestEntry],
        totalBytes: inout Int64,
        progress: BackupProgress?,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw BackupError.cancelled }
        if manifest.count >= maxFiles || totalBytes > maxTotalBytes {
            throw BackupError.writeFailed("Safety limit exceeded (too many files or too much data).")
        }

        let entries: [FileItem]
        do {
            entries = try files.list(directory: path)
        } catch {
            throw BackupError.containerInaccessible(error.localizedDescription)
        }

        for entry in entries {
            if isCancelled() { throw BackupError.cancelled }
            let rel = "\(relativePrefix)/\(entry.name)"

            if entry.isDirectory {
                try walk(
                    path: entry.path,
                    relativePrefix: rel,
                    zip: zip,
                    manifest: &manifest,
                    totalBytes: &totalBytes,
                    progress: progress,
                    isCancelled: isCancelled
                )
            } else if entry.kind == .regular {
                try addFileEntry(
                    path: entry.path,
                    relative: rel,
                    zip: zip,
                    manifest: &manifest,
                    totalBytes: &totalBytes,
                    progress: progress
                )
            }
        }
    }

    /// Read one file, record its hash in the manifest and add it to the archive. A file that cannot
    /// be read is skipped, as it always was, so one locked file does not stop the whole backup.
    private func addFileEntry(
        path: String,
        relative rel: String,
        zip: ZipWriter,
        manifest: inout [BackupManifestEntry],
        totalBytes: inout Int64,
        progress: BackupProgress?
    ) throws {
        let data: Data
        do {
            data = try files.readFile(at: path)
        } catch {
            return
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try zip.addFile(name: rel, data: data)
        manifest.append(BackupManifestEntry(path: rel, size: data.count, sha256: hash))
        totalBytes += Int64(data.count)
        progress?(manifest.count, totalBytes, rel)
    }
}
