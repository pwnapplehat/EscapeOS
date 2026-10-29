import Foundation

/// Result of a completed restore.
struct RestoreResult {
    let filesRestored: Int
    let bytesWritten: Int64
    let targetApp: InstalledApp
    let backupMetadata: BackupMetadata
    /// True when only chosen files and folders of the backup were restored (issue #7).
    var isSelective: Bool = false
}

/// Pre-flight status for a backup against currently installed apps.
enum RestoreEligibility {
    case ready(app: InstalledApp, metadata: BackupMetadata, warnings: [String])
    case appNotInstalled(bundleIdentifier: String, appName: String)
    case invalidArchive(String)

    var canRestore: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Restores a backup archive into an installed app's Data container.
///
/// The reading and writing is `BackupRestorer`, which has no limit on how many files or how much
/// data a backup holds; this opens access to the app's container.
final class RestoreService {

    private let escape = SandboxEscape()
    private let restorer = BackupRestorer()

    /// Evaluate whether a backup can be restored right now.
    func eligibility(for record: BackupRecord, installedApps: [InstalledApp]) -> RestoreEligibility {
        let metadata = record.metadata
        guard let app = installedApps.first(where: { $0.bundleIdentifier == metadata.bundleIdentifier }) else {
            return .appNotInstalled(
                bundleIdentifier: metadata.bundleIdentifier,
                appName: metadata.appName
            )
        }

        var warnings: [String] = []
        if app.containerPath != metadata.containerPath {
            warnings.append(
                "The app's container path changed since this backup was taken. Restore will target the current container."
            )
        }
        if metadata.isPartialBackup {
            warnings.append("This is a partial backup. Only the files and folders in it are restored; everything else in the app is left alone.")
        }
        warnings.append("Close \(app.name) before restoring. Open databases may not restore cleanly while the app is running.")

        return .ready(app: app, metadata: metadata, warnings: warnings)
    }

    /// The files a backup holds, read from its manifest after checking the manifest against the
    /// checksum recorded in the backup's metadata. For the picker that chooses what to restore.
    func loadManifest(for record: BackupRecord) throws -> [BackupManifestEntry] {
        try restorer.manifest(of: record.archiveURL)
    }

    /// Restore a backup archive into the target app container.
    ///
    /// - Parameters:
    ///   - selection: restore only these files and folders of the backup (issue #7). Nil restores
    ///     all of it. A path whose folder no longer exists in the app is recreated.
    ///   - estimate: told, once and before anything is written, how many bytes are to be restored.
    ///   - bytes: told of bytes written, as they are written.
    func restore(
        record: BackupRecord,
        to app: InstalledApp,
        selection: BackupSelection? = nil,
        estimate: ((Int64) -> Void)? = nil,
        bytes: ((Int64) -> Void)? = nil,
        progress: RestoreProgress? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> RestoreResult {
        let outcome = try restorer.restore(
            archiveURL: record.archiveURL,
            bundleIdentifier: app.bundleIdentifier,
            containerPath: app.containerPath,
            selection: selection,
            access: { body in try self.escape.withHandle(for: app.containerPath) { _ in try body() } },
            estimate: estimate,
            bytes: bytes,
            progress: progress,
            isCancelled: isCancelled
        )
        return RestoreResult(
            filesRestored: outcome.filesRestored,
            bytesWritten: outcome.bytesWritten,
            targetApp: app,
            backupMetadata: outcome.metadata,
            isSelective: selection != nil
        )
    }
}
