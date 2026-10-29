import Foundation

/// One thing handed to the share sheet.
struct ShareEntry: Equatable {
    let sourcePath: String
    let isDirectory: Bool
    /// Name it has in the staging folder, and so in whatever the share sheet saves or sends.
    let stagedName: String
}

/// Prepares several selected files and folders for one share sheet (issue #12).
///
/// Share / Save to Files used to take one item. Now every selected item is staged in one
/// folder and the sheet is given all of them, so "Save to Files" saves each under its own name
/// and a message or AirDrop carries them together. A folder cannot be shared as a folder, so it
/// is zipped; a file is copied as it is.
enum ShareStaging {
    static let folderPrefix = "escapeos-share-"

    /// Names for the staged copies: the file's own name, a folder's name plus `.zip`, with
    /// characters a file name cannot hold replaced, and a number added when two would be alike.
    ///
    /// Alike means the same ignoring case: the volume is case-insensitive, so `Report.pdf` and
    /// `report.pdf` would silently overwrite each other. A folder `a` and a file `a.zip` would
    /// collide too, once the folder is zipped.
    static func plan(items: [FileItem]) -> [ShareEntry] {
        var taken = Set<String>()
        var entries: [ShareEntry] = []
        for item in items {
            let wanted = safeName(item.isDirectory ? "\(item.name).zip" : item.name)
            let name = uniqueName(wanted, taken: &taken)
            entries.append(ShareEntry(sourcePath: item.path, isDirectory: item.isDirectory, stagedName: name))
        }
        return entries
    }

    /// Characters a file name cannot hold become `_` or `-`, and an empty name gets a stand-in.
    static func safeName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "item" }
        return cleaned
    }

    private static func uniqueName(_ wanted: String, taken: inout Set<String>) -> String {
        if taken.insert(wanted.lowercased()).inserted { return wanted }
        let ns = wanted as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if taken.insert(candidate.lowercased()).inserted { return candidate }
            index += 1
        }
    }

    /// Remove staging folders left by earlier shares. Each share makes a fresh one, and a share
    /// sheet is modal, so none can still be in use when a new share starts.
    static func sweepLeftovers(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        for leftover in (try? fm.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? [] where leftover.hasPrefix(folderPrefix) {
            try? fm.removeItem(at: temporaryDirectory.appendingPathComponent(leftover))
        }
    }

    /// Copy or zip every entry into a new staging folder and return where each landed, in order.
    ///
    /// Staged in a folder of its own under the temporary directory, never in EscapeOS's Documents:
    /// an earlier version wrote the share file straight into Documents, so sharing a file called
    /// `Backups` or `pairingFile.plist` replaced EscapeOS's own data.
    ///
    /// On any failure, including a cancel, the staging folder is removed.
    static func stage(
        entries: [ShareEntry],
        files: FileService = FileService(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes
    ) throws -> [URL] {
        let fm = FileManager.default
        let folder = temporaryDirectory.appendingPathComponent("\(folderPrefix)\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        do {
            for entry in entries {
                try observer.checkCancelled()
                let destination = folder.appendingPathComponent(entry.stagedName)
                if entry.isDirectory {
                    let zip = ZipWriter()
                    try zip.begin(at: destination)
                    do {
                        let top = FileItem(
                            name: (entry.sourcePath as NSString).lastPathComponent,
                            path: entry.sourcePath,
                            kind: .directory,
                            size: 0,
                            modified: nil,
                            isReadable: true,
                            isWritable: true
                        )
                        try zip.addItems([top], files: files, skipPath: destination.path, observer: observer, chunkSize: chunkSize)
                        try zip.finish()
                    } catch {
                        zip.abandon()
                        throw error
                    }
                } else {
                    observer.detail(entry.stagedName)
                    try files.copyTree(from: entry.sourcePath, to: destination.path, observer: observer, chunkSize: chunkSize)
                }
                urls.append(destination)
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return urls
    }
}
