import Foundation

/// A dropped item, copied into EscapeOS's own temporary space and waiting to be placed.
struct StagedImport: Equatable {
    /// The name it will land under (the dropped name, with anything a file name cannot hold replaced).
    let name: String
    /// Where the staged copy is now.
    let path: String
    let isDirectory: Bool
    /// Bytes of file content in it.
    let bytes: Int64
}

/// Takes files and folders dropped onto a folder and lands them there (issue #10).
///
/// Import from Files reads each picked file into memory and cannot take a folder. A drop can carry
/// whole folders and big files, so each dropped item is copied, by streaming, into a staging folder
/// the moment it arrives (the temporary link the drop gives us does not last), then placed with the
/// same Replace / Keep Both / Cancel rules as Paste, and the same free-space check as every other
/// copy.
enum ImportStaging {
    static let folderPrefix = "escapeos-drop-"

    /// A new, empty staging folder for one drop.
    static func makeFolder(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = temporaryDirectory.appendingPathComponent("\(folderPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Remove staging folders left by drops that were never finished (the app was closed first).
    /// Called at launch, before any drop can be in progress.
    static func sweepLeftovers(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        for leftover in (try? fm.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? [] where leftover.hasPrefix(folderPrefix) {
            try? fm.removeItem(at: temporaryDirectory.appendingPathComponent(leftover))
        }
    }

    static func discard(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Copy one dropped file or folder into the staging folder.
    ///
    /// Each item gets a subfolder of its own, so two dropped items with one name do not collide.
    /// Refuses up front, with the usual message, when there is not room for the copy.
    static func stage(
        source: URL,
        into folder: URL,
        files: FileService = FileService(),
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes
    ) throws -> StagedImport {
        let name = ShareStaging.safeName(source.lastPathComponent)
        try SpaceCheck.require(
            files.treeBytes(at: source.path),
            at: folder.path,
            for: "import this",
            files: files
        )
        let slot = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let destination = slot.appendingPathComponent(name)
        let isDirectory = files.isDirectory(at: source.path) && !files.isSymlink(at: source.path)
        do {
            observer.detail(name)
            let copied = try files.copyTree(from: source.path, to: destination.path, observer: observer, chunkSize: chunkSize)
            return StagedImport(name: name, path: destination.path, isDirectory: isDirectory, bytes: copied)
        } catch {
            try? FileManager.default.removeItem(at: slot)
            throw error
        }
    }

    /// The staged items as the browser's `FileItem`s, so Paste's conflict planner can check them
    /// against the destination folder.
    static func fileItems(for staged: [StagedImport]) -> [FileItem] {
        staged.map {
            FileItem(
                name: $0.name,
                path: $0.path,
                kind: $0.isDirectory ? .directory : .regular,
                size: $0.bytes,
                modified: nil,
                isReadable: true,
                isWritable: true
            )
        }
    }

    /// What dropping these into `destinationFolder` would collide with.
    static func plan(staged: [StagedImport], into destinationFolder: String, files: FileService = FileService()) -> PastePlan {
        PasteConflictPlanner.plan(items: fileItems(for: staged), into: destinationFolder, moving: false, files: files)
    }

    /// Place the staged items in `destinationFolder` under `policy`, moving them out of staging.
    ///
    /// - Returns: where each item landed. Nothing lands for `.cancel`.
    @discardableResult
    static func land(
        _ staged: [StagedImport],
        into destinationFolder: String,
        policy: ImportNamePolicy,
        files: FileService = FileService(),
        observer: TransferObserver = .none
    ) throws -> [String] {
        guard policy != .cancel else { return [] }
        var landed: [String] = []
        for item in staged {
            try observer.checkCancelled()
            observer.detail(item.name)
            if let path = try files.land(
                source: item.path,
                sourceIsDirectory: item.isDirectory,
                named: item.name,
                into: destinationFolder,
                policy: policy,
                move: true,
                observer: observer
            ) {
                landed.append(path)
            }
        }
        return landed
    }
}
