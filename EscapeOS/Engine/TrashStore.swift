import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One deleted item waiting in the Trash.
struct TrashRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        /// Being moved in. Not shown, and cleaned up or promoted by `recoverInterrupted()`.
        case moving
        case ready
    }

    /// Also the name of the folder it lives in.
    var id: String
    /// The name it had.
    var name: String
    /// What it is called inside its folder (the name with anything unsafe replaced).
    var storedName: String
    var isDirectory: Bool
    /// Bytes of file content, so the Trash can say how much room it takes.
    var bytes: Int64
    /// Files, folders and links counted when it was moved in, to tell a complete copy from a partial one.
    var entryCount: Int
    var deletedAt: Date
    var bundleIdentifier: String
    var appName: String
    /// Where it was, from the app's container: `Documents/notes/a.txt`. Never starts with `/`.
    var relativePath: String
    /// Where it was on this device when deleted. For display only: a container path changes when
    /// the app is reinstalled, so restore uses `relativePath` against the current container.
    var originalPath: String
    var reason: String?
    var state: State

    /// The folder it was in, for the "from" line.
    var parentRelativePath: String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

/// The app a trashed item came from.
struct TrashSource: Equatable {
    let bundleIdentifier: String
    let appName: String
    let containerPath: String
}

struct RestoredItem: Equatable {
    /// Where the item is now.
    let path: String
    /// True when the original name was taken, so it came back under a new one. Restore never
    /// replaces anything that is there.
    let renamed: Bool
}

enum TrashError: Error, LocalizedError, Equatable {
    case outsideContainer(String)
    case missing(String)
    case notRestorable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .outsideContainer(let name): return "“\(name)” is not inside this app's data, so it cannot be moved to the Trash."
        case .missing(let name): return "“\(name)” is no longer there."
        case .notRestorable(let message): return message
        case .failed(let message): return message
        }
    }
}

/// Whether deleting moves items to the Trash. On unless the person turns it off.
enum TrashPreference {
    static let key = "UseTrash"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func setEnabled(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}

/// A Trash for items deleted from other apps' data (issue #9).
///
/// A trash holds copies of other apps' data inside EscapeOS's own storage, so it is meant to be
/// seen and to stay small: it lives in `Documents/Trash` (visible in Files), reports its size, and
/// is emptied with one tap.
///
/// Layout: `<root>/<id>/<name>` is the item itself and `<root>/<id>/.escapeos-trash.json` says
/// where it came from. The record is written first, marked `moving`, and rewritten `ready` once the
/// item is in place, so a crash at any point leaves something `recoverInterrupted()` can judge
/// instead of an unlabelled pile of someone's files.
final class TrashStore {
    static let recordFileName = ".escapeos-trash.json"
    /// Shown on an item that was being moved in when EscapeOS stopped and does not match what was recorded.
    static let interruptedReason = "EscapeOS was closed while this was being moved to the Trash. It may be incomplete."

    let root: URL
    private let files: FileService
    private let now: () -> Date
    private let renamer: (String, String) -> Bool
    private let fm = FileManager.default

    /// - Parameter renamer: how an item is moved when a rename is possible; replaceable so the
    ///   copy-and-delete fallback (used when the Trash is on another volume) can be tested.
    init(
        root: URL,
        files: FileService = FileService(),
        now: @escaping () -> Date = Date.init,
        renamer: @escaping (String, String) -> Bool = { rename($0, $1) == 0 }
    ) {
        self.root = root
        self.files = files
        self.now = now
        self.renamer = renamer
    }

    /// `Documents/Trash`.
    static func standard() -> TrashStore {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return TrashStore(root: documents.appendingPathComponent("Trash", isDirectory: true))
    }

    // MARK: - Moving in

    /// Move an item from an app's data into the Trash.
    ///
    /// The item moves by rename when it can (instant, no extra space). Otherwise it is copied and
    /// the original removed only after the copy is complete, so a failure or a cancel leaves it
    /// where it was.
    @discardableResult
    func moveToTrash(
        path: String,
        name: String,
        isDirectory: Bool,
        from app: TrashSource,
        reason: String? = nil,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes
    ) throws -> TrashRecord {
        guard let relative = Self.relativePath(of: path, in: app.containerPath) else {
            throw TrashError.outsideContainer(name)
        }
        guard files.existingKind(at: path) != .none || files.isSymlink(at: path) else {
            throw TrashError.missing(name)
        }
        let inventory = self.inventory(of: path)
        let id = UUID().uuidString
        let folder = root.appendingPathComponent(id, isDirectory: true)
        let stored = ShareStaging.safeName((name as NSString).lastPathComponent)
        var record = TrashRecord(
            id: id,
            name: name,
            storedName: stored,
            isDirectory: isDirectory,
            bytes: inventory.bytes,
            entryCount: inventory.entries,
            deletedAt: now(),
            bundleIdentifier: app.bundleIdentifier,
            appName: app.appName,
            relativePath: relative,
            originalPath: path,
            reason: reason,
            state: .moving
        )

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(record, in: folder)
            try transfer(from: path, to: folder.appendingPathComponent(stored).path, bytes: inventory.bytes, observer: observer, chunkSize: chunkSize)
            record.state = .ready
            try write(record, in: folder)
        } catch {
            // The item is still where it was, or (if only the final rewrite failed) in the folder
            // with a complete payload that recovery will promote. Only throw the folder away when
            // the item did not move.
            if files.existingKind(at: path) != .none || files.isSymlink(at: path) {
                try? fm.removeItem(at: folder)
            }
            throw error
        }
        return record
    }

    /// Keep a copy of a file that is not being deleted, as an item that restores to `relativePath`
    /// in the app. Used to put away the original database before an edit is saved over it, so the
    /// edit can be undone. The source is left exactly where it is.
    @discardableResult
    func keepCopy(
        of sourcePath: String,
        name: String,
        restoringTo relativePath: String,
        from app: TrashSource,
        reason: String,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes
    ) throws -> TrashRecord {
        guard Self.isSafeRelative(relativePath) else { throw TrashError.outsideContainer(name) }
        guard files.existingKind(at: sourcePath) != .none || files.isSymlink(at: sourcePath) else {
            throw TrashError.missing(name)
        }
        let inventory = self.inventory(of: sourcePath)
        let id = UUID().uuidString
        let folder = root.appendingPathComponent(id, isDirectory: true)
        let stored = ShareStaging.safeName((name as NSString).lastPathComponent)
        var record = TrashRecord(
            id: id,
            name: name,
            storedName: stored,
            isDirectory: files.isDirectory(at: sourcePath) && !files.isSymlink(at: sourcePath),
            bytes: inventory.bytes,
            entryCount: inventory.entries,
            deletedAt: now(),
            bundleIdentifier: app.bundleIdentifier,
            appName: app.appName,
            relativePath: relativePath,
            originalPath: (app.containerPath as NSString).appendingPathComponent(relativePath),
            reason: reason,
            state: .moving
        )
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(record, in: folder)
            try SpaceCheck.require(inventory.bytes, at: root.path, for: "keep a copy of this", files: files)
            try files.copyTree(from: sourcePath, to: folder.appendingPathComponent(stored).path, observer: observer, chunkSize: chunkSize)
            record.state = .ready
            try write(record, in: folder)
        } catch {
            // A copy: the source is untouched whatever happened, so a half-made entry is just removed.
            try? fm.removeItem(at: folder)
            throw error
        }
        return record
    }

    // MARK: - Listing

    /// Items that are ready to restore, newest first. Entries whose payload has gone are skipped.
    func records() -> [TrashRecord] {
        var found: [TrashRecord] = []
        for entry in folders() {
            guard let record = readRecord(in: entry), record.state == .ready,
                  files.existingKind(at: entry.appendingPathComponent(record.storedName).path) != .none
                    || files.isSymlink(at: entry.appendingPathComponent(record.storedName).path)
            else { continue }
            found.append(record)
        }
        return found.sorted { $0.deletedAt > $1.deletedAt }
    }

    func records(forBundleIdentifier bundleIdentifier: String) -> [TrashRecord] {
        records().filter { $0.bundleIdentifier == bundleIdentifier }
    }

    /// What the Trash holds, in bytes of file content.
    func totalBytes() -> Int64 {
        records().reduce(0) { $0 + $1.bytes }
    }

    /// Where the item itself is, for sharing or previewing it from the Trash.
    func payloadURL(for record: TrashRecord) -> URL {
        root.appendingPathComponent(record.id, isDirectory: true).appendingPathComponent(record.storedName)
    }

    // MARK: - Restoring

    /// Put an item back where it came from, in the app's current container.
    ///
    /// Never replaces anything: if the name is taken the item comes back as `name 2`, and the
    /// result says so. Folders that no longer exist on the way are recreated.
    func restore(
        _ record: TrashRecord,
        toContainer containerPath: String,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes
    ) throws -> RestoredItem {
        guard record.state == .ready else { throw TrashError.notRestorable("“\(record.name)” is not ready to restore.") }
        let folder = root.appendingPathComponent(record.id, isDirectory: true)
        let payload = folder.appendingPathComponent(record.storedName).path
        guard files.existingKind(at: payload) != .none || files.isSymlink(at: payload) else {
            throw TrashError.missing(record.name)
        }
        guard Self.isSafeRelative(record.relativePath) else {
            throw TrashError.notRestorable("“\(record.name)” has a location that cannot be restored safely.")
        }
        let wanted = (containerPath as NSString).appendingPathComponent(record.relativePath)
        guard PathContainment.isInside(wanted, root: containerPath) else {
            throw TrashError.outsideContainer(record.name)
        }
        let parent = (wanted as NSString).deletingLastPathComponent
        do {
            try files.createDirectory(at: parent)
        } catch {
            throw TrashError.failed("Could not recreate the folder “\((parent as NSString).lastPathComponent)”: \(error.localizedDescription)")
        }

        let leaf = (wanted as NSString).lastPathComponent
        var destination = wanted
        var renamed = false
        if files.existingKind(at: wanted) != .none || files.isSymlink(at: wanted) {
            destination = files.uniqueDestination(in: parent, preferredName: leaf)
            renamed = true
        }
        try transfer(from: payload, to: destination, bytes: record.bytes, observer: observer, chunkSize: chunkSize)
        // The item is back; the Trash entry is now an empty shell. If it cannot be removed it is
        // skipped by `records()` (its payload is gone) and swept by recovery.
        try? fm.removeItem(at: folder)
        return RestoredItem(path: destination, renamed: renamed)
    }

    // MARK: - Removing

    func deletePermanently(_ record: TrashRecord) throws {
        let folder = root.appendingPathComponent(record.id, isDirectory: true)
        do {
            try fm.removeItem(at: folder)
        } catch {
            throw TrashError.failed("Could not delete “\(record.name)”: \(error.localizedDescription)")
        }
    }

    /// Remove everything in the Trash, including anything unrecognised. Returns how many items
    /// were removed. Carries on past one that will not delete, and says how many were left.
    @discardableResult
    func empty() throws -> Int {
        var removed = 0
        var left = 0
        for entry in folders() {
            let counts = readRecord(in: entry)?.state == .ready
            do {
                try fm.removeItem(at: entry)
                if counts { removed += 1 }
            } catch {
                left += 1
            }
        }
        if left > 0 {
            throw TrashError.failed("\(left) \(left == 1 ? "item" : "items") could not be deleted and \(left == 1 ? "is" : "are") still in the Trash.")
        }
        return removed
    }

    // MARK: - Recovery

    /// Settle anything a crash or a kill left half-done. Safe to run at any time, and cheap.
    ///
    /// - A `moving` entry whose payload matches what was recorded is complete: it is promoted to ready.
    /// - A `moving` entry with no payload has nothing in it to keep, so it is removed.
    /// - A `moving` entry whose payload does not match what was recorded is kept, as ready and marked
    ///   as possibly incomplete. It may be a partial copy of an item that is still in place, but it
    ///   may equally be the only copy left (the original was deleted after a complete copy, and the
    ///   count differs because sockets and pipes are not copied). Deleting it on a guess could lose
    ///   someone's data; keeping it costs a little space and an item they can delete themselves.
    /// - A ready entry whose payload is gone, and an empty folder, are removed.
    func recoverInterrupted() {
        for entry in folders() {
            guard var record = readRecord(in: entry) else {
                if ((try? fm.contentsOfDirectory(atPath: entry.path))?.isEmpty ?? false) {
                    try? fm.removeItem(at: entry)
                }
                continue
            }
            let payload = entry.appendingPathComponent(record.storedName).path
            let present = files.existingKind(at: payload) != .none || files.isSymlink(at: payload)
            switch record.state {
            case .ready:
                if !present { try? fm.removeItem(at: entry) }
            case .moving:
                guard present else {
                    try? fm.removeItem(at: entry)
                    continue
                }
                let have = inventory(of: payload)
                if !(have.bytes == record.bytes && have.entries == record.entryCount) {
                    record.reason = Self.interruptedReason
                }
                record.state = .ready
                try? write(record, in: entry)
            }
        }
    }

    // MARK: - Internals

    /// `Documents/a/b.txt` for `/containers/X/Documents/a/b.txt` in `/containers/X`, or nil when the
    /// path is not inside the container (or is the container itself).
    static func relativePath(of path: String, in container: String) -> String? {
        let base = PathContainment.components(of: container)
        let target = PathContainment.components(of: path)
        guard !base.isEmpty, target.count > base.count, Array(target.prefix(base.count)) == base else { return nil }
        return target.dropFirst(base.count).joined(separator: "/")
    }

    /// No leading slash, no `..`, not empty.
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    /// Move by rename if that works; otherwise make sure there is room, then copy and delete.
    private func transfer(
        from source: String,
        to destination: String,
        bytes: Int64,
        observer: TransferObserver,
        chunkSize: Int
    ) throws {
        try observer.checkCancelled()
        if renamer(source, destination) { return }
        try SpaceCheck.require(bytes, at: (destination as NSString).deletingLastPathComponent, for: "move this to the Trash", files: files)
        try files.moveTree(from: source, to: destination, observer: observer, chunkSize: chunkSize, rename: { _, _ in false })
    }

    private func folders() -> [URL] {
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [URL] = []
        for name in names where !name.hasPrefix(".") {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if files.isDirectory(at: url.path) { result.append(url) }
        }
        return result
    }

    private func readRecord(in folder: URL) -> TrashRecord? {
        guard let data = fm.contents(atPath: folder.appendingPathComponent(Self.recordFileName).path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(TrashRecord.self, from: data), record.id == folder.lastPathComponent else {
            return nil
        }
        return record
    }

    private func write(_ record: TrashRecord, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(record)
        try data.write(to: folder.appendingPathComponent(Self.recordFileName), options: .atomic)
    }

    /// Bytes of file content and number of entries (the item itself counts as one).
    private func inventory(of path: String) -> (bytes: Int64, entries: Int) {
        var entries = 1
        if files.isDirectory(at: path), !files.isSymlink(at: path), let walker = fm.enumerator(atPath: path) {
            while walker.nextObject() != nil { entries += 1 }
        }
        return (files.isSymlink(at: path) ? 0 : files.treeBytes(at: path), entries)
    }
}
