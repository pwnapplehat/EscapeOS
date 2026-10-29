import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What a file looked like when it was copied: enough to tell whether something changed it since.
struct FileSignature: Equatable {
    let exists: Bool
    let size: Int64
    let modified: TimeInterval
}

enum WorkingCopyError: Error, LocalizedError, Equatable {
    /// The database changed while it was being copied: the app is writing to it right now.
    case inUse
    /// The database changed after it was opened, so saving would overwrite someone else's changes.
    case originalChanged
    case safetyCopyFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .inUse:
            return "This database is being written to right now, so a consistent copy could not be made. Close the app that owns it and open the file again."
        case .originalChanged:
            return "The database changed in the app after you opened it, so saving would overwrite those changes. Nothing was saved. Close the app, open the file again, and redo your edits, or use Share a Copy to keep what you have."
        case .safetyCopyFailed(let message):
            return "A copy of the original could not be kept, so nothing was saved. \(message)"
        case .saveFailed(let message):
            return "The database could not be saved, and the original was left as it was. \(message)"
        }
    }
}

/// A private copy of another app's SQLite database, to browse and edit (issue #8).
///
/// Writing to a database while its app has it open can corrupt it, so nothing here ever touches the
/// original until the person chooses Save, and then only after these checks:
///
/// 1. The original is unchanged since it was copied. If the app wrote to it meanwhile, saving would
///    throw those writes away, so it refuses.
/// 2. A snapshot of the original, with its write-ahead log folded in so it is one ordinary file, is
///    handed to the caller to keep (EscapeOS puts it in the Trash), so a bad edit can be undone.
/// 3. The edited copy is written next to the original under a temporary name and swapped in with one
///    atomic rename, so the file is always either the old database or the new one, never half of each.
/// 4. The original's `-wal`, `-shm` and `-journal` files are removed. They describe the OLD main
///    file; left in place, SQLite would replay them into the new one and corrupt it.
final class SQLiteWorkingCopy {
    /// Files that sit beside a database and belong to it.
    static let sidecarSuffixes = ["-wal", "-shm", "-journal"]
    /// Copied with the database. `-shm` is not: it is an index of the log that SQLite rebuilds, and
    /// a stale one is worse than none.
    private static let copiedSuffixes = ["", "-wal", "-journal"]
    /// Compared to tell whether the original changed. `-shm` is left out: it changes when a database
    /// is merely opened.
    private static let watchedSuffixes = ["", "-wal", "-journal"]
    static let folderPrefix = "escapeos-db-"

    let originalPath: String
    let workingPath: String
    private let folder: URL
    private let files: FileService
    private let renamer: (String, String) -> Bool
    private var opened: [String: FileSignature] = [:]
    /// SQLite counts changes per connection, and a connection is reopened after a save attempt, so
    /// edits made before the reopen are carried here rather than lost from the count.
    private var carriedChanges = 0
    private var changesBaseline = 0
    private(set) var database: SQLiteDatabase

    /// Edits made to the copy that are not saved to the app yet.
    var hasUnsavedChanges: Bool { carriedChanges + (database.totalChanges - changesBaseline) > 0 }

    private init(
        originalPath: String,
        folder: URL,
        workingPath: String,
        database: SQLiteDatabase,
        files: FileService,
        renamer: @escaping (String, String) -> Bool
    ) {
        self.originalPath = originalPath
        self.folder = folder
        self.workingPath = workingPath
        self.database = database
        self.files = files
        self.renamer = renamer
    }

    // MARK: - Opening

    /// Copy the database into a private folder and open the copy.
    ///
    /// - Parameters:
    ///   - afterCopy: called after each copy attempt with its number; for tests to change the original mid-copy.
    ///   - retryDelay: wait between attempts when the database changes while it is being copied.
    static func open(
        original: String,
        files: FileService = FileService(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes,
        afterCopy: (Int) -> Void = { _ in },
        retryDelay: TimeInterval = 0.25,
        renamer: @escaping (String, String) -> Bool = { rename($0, $1) == 0 }
    ) throws -> SQLiteWorkingCopy {
        let fm = FileManager.default
        let leaf = (original as NSString).lastPathComponent
        var attempt = 0
        while true {
            attempt += 1
            try observer.checkCancelled()
            let before = signatures(of: original, files: files)
            guard before[""]?.exists == true else { throw FileServiceError.pathNotFound(original) }

            var needed: Int64 = 0
            for suffix in copiedSuffixes { needed += before[suffix]?.size ?? 0 }
            try SpaceCheck.require(needed, at: temporaryDirectory.path, for: "open this database", files: files)

            let folder = temporaryDirectory.appendingPathComponent("\(folderPrefix)\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                for suffix in copiedSuffixes where files.existingKind(at: original + suffix) != .none {
                    try files.copyTree(
                        from: original + suffix,
                        to: folder.appendingPathComponent(leaf + suffix).path,
                        observer: observer,
                        chunkSize: chunkSize
                    )
                }
            } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
            afterCopy(attempt)
            let after = signatures(of: original, files: files)
            if after != before {
                // Written to while copying: the copy may hold half of a change. Try again.
                try? fm.removeItem(at: folder)
                if attempt >= 3 { throw WorkingCopyError.inUse }
                if retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay) }
                continue
            }

            let workingPath = folder.appendingPathComponent(leaf).path
            do {
                let database = try SQLiteDatabase(path: workingPath)
                let copy = SQLiteWorkingCopy(
                    originalPath: original, folder: folder, workingPath: workingPath,
                    database: database, files: files, renamer: renamer
                )
                copy.opened = before
                copy.changesBaseline = database.totalChanges
                return copy
            } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
        }
    }

    /// Remove working folders left by an earlier run that was closed with a database open.
    static func sweepLeftovers(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        for leftover in (try? fm.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? [] where leftover.hasPrefix(folderPrefix) {
            try? fm.removeItem(at: temporaryDirectory.appendingPathComponent(leftover))
        }
    }

    // MARK: - Checking the original

    /// True when the original database or its log differs from what was copied.
    func hasOriginalChanged() -> Bool {
        Self.signatures(of: originalPath, files: files) != opened
    }

    private static func signatures(of path: String, files: FileService) -> [String: FileSignature] {
        var result: [String: FileSignature] = [:]
        for suffix in watchedSuffixes {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path + suffix)
            result[suffix] = FileSignature(
                exists: attrs != nil,
                size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                modified: (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            )
        }
        return result
    }

    // MARK: - Sharing and saving

    /// The edited database as one self-contained file, for sharing a copy. The edits are folded into
    /// the main file first, so it needs no log beside it.
    func shareablePath() throws -> String {
        try database.checkpointAndTruncate()
        return workingPath
    }

    /// Replace the original with the edited copy, safely. See the type's comment for what is checked.
    ///
    /// - Parameter keepOriginal: handed the path of a snapshot of the original, one ordinary database
    ///   file with its log folded in, to keep; the snapshot is removed afterwards, so the closure must
    ///   copy it if it wants it. If it throws, nothing is saved.
    func saveToOriginal(keepOriginal: (String) throws -> Void) throws {
        guard !hasOriginalChanged() else { throw WorkingCopyError.originalChanged }
        let fm = FileManager.default
        let directory = (originalPath as NSString).deletingLastPathComponent
        let leaf = (originalPath as NSString).lastPathComponent
        let token = UUID().uuidString

        // 1. Keep a snapshot of the original: copy its files, fold the log into the main file so it
        //    stands alone, and hand that one file over.
        let safety = folder.appendingPathComponent("original-\(token)", isDirectory: true)
        do {
            try fm.createDirectory(at: safety, withIntermediateDirectories: true)
            for suffix in Self.copiedSuffixes where files.existingKind(at: originalPath + suffix) != .none {
                try files.copyTree(from: originalPath + suffix, to: safety.appendingPathComponent(leaf + suffix).path)
            }
            let snapshot = safety.appendingPathComponent(leaf).path
            let snapshotDatabase = try SQLiteDatabase(path: snapshot)
            try snapshotDatabase.checkpointAndTruncate()
            snapshotDatabase.close()
            for suffix in Self.sidecarSuffixes { try? fm.removeItem(atPath: snapshot + suffix) }
            try keepOriginal(snapshot)
        } catch {
            try? fm.removeItem(at: safety)
            throw WorkingCopyError.safetyCopyFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: safety)

        // 2. Make the copy self-contained, and closed so everything is on disk.
        do {
            try database.checkpointAndTruncate()
        } catch {
            throw WorkingCopyError.saveFailed(error.localizedDescription)
        }
        let editsBeforeClosing = carriedChanges + (database.totalChanges - changesBaseline)
        database.close()
        /// Open the copy again. If the save failed the edits are still in it and still unsaved.
        func reopen(saved: Bool) {
            guard let again = try? SQLiteDatabase(path: workingPath) else { return }
            database = again
            changesBaseline = again.totalChanges
            carriedChanges = saved ? 0 : editsBeforeClosing
        }

        // 3. Write next to the original under a temporary name.
        let temporary = (directory as NSString).appendingPathComponent(".escapeos-save-\(token)")
        do {
            let size = ((try? fm.attributesOfItem(atPath: workingPath))?[.size] as? NSNumber)?.int64Value ?? 0
            try SpaceCheck.require(size, at: directory, for: "save this database", files: files)
            try files.copyTree(from: workingPath, to: temporary)
        } catch {
            try? files.deleteItem(at: temporary)
            reopen(saved: false)
            throw WorkingCopyError.saveFailed(error.localizedDescription)
        }

        // 4. Set the original's log files aside, so they can be put back if the swap fails.
        var aside: [(moved: String, original: String)] = []
        func putBack() {
            for entry in aside.reversed() { _ = renamer(entry.moved, entry.original) }
        }
        for suffix in Self.sidecarSuffixes where files.existingKind(at: originalPath + suffix) != .none {
            let moved = (directory as NSString).appendingPathComponent(".escapeos-old-\(token)\(suffix)")
            guard renamer(originalPath + suffix, moved) else {
                putBack()
                try? files.deleteItem(at: temporary)
                reopen(saved: false)
                throw WorkingCopyError.saveFailed("Could not move the database's \(suffix) file aside.")
            }
            aside.append((moved, originalPath + suffix))
        }

        // 5. Swap, atomically.
        guard renamer(temporary, originalPath) else {
            putBack()
            try? files.deleteItem(at: temporary)
            reopen(saved: false)
            throw WorkingCopyError.saveFailed("The new file could not be put in place.")
        }

        // 6. The old log files describe the old main file: gone.
        for entry in aside { try? files.deleteItem(at: entry.moved) }

        reopen(saved: true)
        opened = Self.signatures(of: originalPath, files: files)
    }

    // MARK: - Finishing

    /// Close the copy and remove its folder. Unsaved edits are lost; the caller asks first.
    func discard() {
        database.close()
        try? FileManager.default.removeItem(at: folder)
    }
}
