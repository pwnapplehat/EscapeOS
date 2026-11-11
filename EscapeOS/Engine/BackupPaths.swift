import Foundation

/// A backup archive on disk with parsed metadata.
struct BackupRecord: Identifiable, Hashable {
    let id: String
    let archiveURL: URL
    let metadata: BackupMetadata
    let archiveFileName: String
    let archiveBytes: Int64
    let modified: Date?

    var displayTitle: String { metadata.appName }
    var displaySubtitle: String { BackupDescription.subtitle(for: metadata) }

    /// For a partial backup, what it covers by name; nil for a full one.
    var scopeSummary: String? { BackupDescription.scopeSummary(for: metadata) }
}

/// Shared paths and catalog helpers for backup archives.
enum BackupPaths {
    static let folderName = "Backups"
    static let metadataFileName = "backup.json"
    static let manifestFileName = "manifest.json"

    static func backupsDirectory() -> URL {
        documentsDirectory().appendingPathComponent(folderName, isDirectory: true)
    }

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    @discardableResult
    static func ensureBackupsDirectory() throws -> URL {
        let dir = backupsDirectory()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func isoTimestamp(from date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func fileTimestamp(from date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: date)
    }

    /// A name that does not replace a zip already in `directory`.
    static func uniqueArchiveURL(in directory: URL, preferredName: String) -> URL {
        let cleaned = preferredName.replacingOccurrences(of: "/", with: "_")
        let ns = cleaned as NSString
        var base = ns.deletingPathExtension
        var ext = ns.pathExtension
        if base.isEmpty { base = "Backup" }
        if ext.isEmpty { ext = "zip" }
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var number = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path), number < 1000 {
            candidate = directory.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    static let displayStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// Lists backup archives stored under Documents/Backups.
final class BackupCatalog {

    func loadRecords() throws -> [BackupRecord] {
        let dir = try BackupPaths.ensureBackupsDirectory()
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.lowercased().hasSuffix(".zip") }
            .sorted(by: >)

        var records: [BackupRecord] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            do {
                let record = try loadRecord(at: url)
                records.append(record)
            } catch {
                continue
            }
        }
        return records.sorted {
            ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
        }
    }

    func loadRecords(forBundleIdentifier bundleId: String) throws -> [BackupRecord] {
        try loadRecords().filter { $0.metadata.bundleIdentifier == bundleId }
    }

    func loadRecord(at url: URL) throws -> BackupRecord {
        // Only backup.json is wanted, and a backup can hold hundreds of thousands of entries.
        let reader = try ZipReader(url: url, only: [BackupPaths.metadataFileName])
        guard reader.entries[BackupPaths.metadataFileName] != nil else {
            throw BackupError.invalidArchive("Missing \(BackupPaths.metadataFileName)")
        }
        let metadataData = try reader.readEntry(named: BackupPaths.metadataFileName)
        let metadata = try JSONDecoder().decode(BackupMetadata.self, from: metadataData)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs?[.modificationDate] as? Date
        return BackupRecord(
            id: url.lastPathComponent,
            archiveURL: url,
            metadata: metadata,
            archiveFileName: url.lastPathComponent,
            archiveBytes: bytes,
            modified: modified
        )
    }

    func delete(record: BackupRecord) throws {
        try FileManager.default.removeItem(at: record.archiveURL)
    }

    func importArchive(from source: URL) throws -> BackupRecord {
        try importArchive(from: source, into: nil)
    }

    /// Copy an exported EscapeOS backup zip into `directory`, or the Backups folder when that is nil.
    ///
    /// A zip that is not one of these backups is refused. A name that is already there is kept,
    /// and the import lands beside it. A file that is already in that folder is left where it is.
    func importArchive(from source: URL, into directory: URL?) throws -> BackupRecord {
        #if os(iOS)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        #endif
        _ = try loadRecord(at: source)
        let folder = try directory ?? BackupPaths.ensureBackupsDirectory()
        let sourcePath = source.standardizedFileURL.path
        let root = folder.standardizedFileURL.path
        if sourcePath == root || sourcePath.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            return try loadRecord(at: source)
        }
        let destination = BackupPaths.uniqueArchiveURL(in: folder, preferredName: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return try loadRecord(at: destination)
    }
}
