import Foundation

/// Exports an app's Data container (Documents, Library, tmp) into a zip
/// archive with a manifest of SHA-256 hashes. Read-only with respect to the
/// target app during export.
///
/// The writing itself is `BackupArchiver`, which has no limit on how many files or how much data a
/// backup holds; this opens access to the app's container and chooses where the archive goes.
final class BackupService {

    private let escape = SandboxEscape()
    private let archiver = BackupArchiver()

    /// Subtrees of a Data container we export and restore.
    static let backupRoots = BackupSelection.allowedRoots

    /// Export the given app's container to a zip inside Documents/Backups.
    ///
    /// - Parameters:
    ///   - selection: back up only these files and folders (issue #7). Nil backs up everything.
    ///   - estimate: told, once and before anything is written, roughly how many bytes there are
    ///     to back up, so progress can be a percentage. Not called for a tree too large to measure.
    ///   - bytes: told of bytes written, as they are written.
    func exportBackup(
        for app: InstalledApp,
        selection: BackupSelection? = nil,
        estimate: ((Int64) -> Void)? = nil,
        bytes: ((Int64) -> Void)? = nil,
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
        let source = BackupSource(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            containerPath: app.containerPath
        )
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

        do {
            return try escape.withHandle(for: app.containerPath) { _ in
                try archiver.write(
                    source: source,
                    selection: selection,
                    to: outURL,
                    spaceDirectory: backupsDir.path,
                    escapeOSVersion: version,
                    estimate: estimate,
                    bytes: bytes,
                    progress: progress,
                    isCancelled: isCancelled
                )
            }
        } catch let error as BackupError {
            throw error
        } catch {
            // The container could not be opened at all; nothing was written.
            throw BackupError.containerInaccessible(error.localizedDescription)
        }
    }
}
