import Foundation

/// A single entry in a directory listing.
struct FileItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case directory
        case regular
        case symlink
        case other
    }

    let id = UUID()
    let name: String
    let path: String
    let kind: Kind
    let size: Int64
    let modified: Date?
    let isReadable: Bool
    let isWritable: Bool

    var isDirectory: Bool { kind == .directory }
}

/// Occupant of a path, if any. Replacing a file is not the same as replacing a folder.
enum ExistingItemKind {
    case none
    case file
    case directory
}

/// How to land an imported name when that name is already in the folder.
enum ImportNamePolicy {
    /// Overwrite a same-named file. A same-named folder is kept as a copy.
    case replace
    /// Land beside the existing name (`foo 2.txt`).
    case keepBoth
    /// Write nothing.
    case cancel
}

/// Errors surfaced by file operations.
enum FileServiceError: Error, LocalizedError {
    case pathNotFound(String)
    case permissionDenied(String)
    case notDirectory(String)
    case notRegularFile(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let p): return "Path not found: \(p)"
        case .permissionDenied(let p): return "Permission denied: \(p)"
        case .notDirectory(let p): return "Not a directory: \(p)"
        case .notRegularFile(let p): return "Not a regular file: \(p)"
        case .operationFailed(let m): return "Operation failed: \(m)"
        }
    }
}

/// Performs filesystem operations against a path for which a sandbox
/// extension has already been consumed via `SandboxEscape`.
final class FileService {

    private let fm = FileManager.default

    // MARK: - Metadata

    func exists(at path: String) -> Bool {
        fm.fileExists(atPath: path)
    }

    func isDirectory(at path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// What already occupies `path`, if anything. A file and a folder are not interchangeable.
    /// Uses `attributesOfItem` so a symlink is classified as a file (the link), not its target.
    func existingKind(at path: String) -> ExistingItemKind {
        guard let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
            return fm.fileExists(atPath: path) ? .file : .none
        }
        if type == FileAttributeType.typeDirectory {
            return .directory
        }
        return .file
    }

    func attributes(at path: String) throws -> [FileAttributeKey: Any] {
        do {
            return try fm.attributesOfItem(atPath: path)
        } catch {
            throw mapError(error, path: path)
        }
    }

    // MARK: - Listing

    func list(directory path: String) throws -> [FileItem] {
        guard isDirectory(at: path) else {
            throw FileServiceError.notDirectory(path)
        }

        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: path)
        } catch {
            throw mapError(error, path: path)
        }

        var items: [FileItem] = []
        for name in names {
            let full = (path as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: full) else {
                continue
            }
            let type = attrs[.type] as? FileAttributeType
            let kind: FileItem.Kind
            if type == FileAttributeType.typeDirectory {
                kind = .directory
            } else if type == FileAttributeType.typeRegular {
                kind = .regular
            } else if type == FileAttributeType.typeSymbolicLink {
                kind = .symlink
            } else {
                kind = .other
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs[.modificationDate] as? Date
            let readable = fm.isReadableFile(atPath: full)
            let writable = fm.isWritableFile(atPath: full)
            items.append(FileItem(
                name: name,
                path: full,
                kind: kind,
                size: size,
                modified: modified,
                isReadable: readable,
                isWritable: writable
            ))
        }
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Read

    func readFile(at path: String, maxBytes: Int? = nil) throws -> Data {
        guard !isDirectory(at: path) else {
            throw FileServiceError.notRegularFile(path)
        }
        guard let stream = InputStream(fileAtPath: path) else {
            throw FileServiceError.pathNotFound(path)
        }
        stream.open()
        defer { stream.close() }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        var total = 0
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 { throw stream.streamError ?? FileServiceError.operationFailed("read error") }
            if read == 0 { break }
            data.append(buffer, count: read)
            total += read
            if let max = maxBytes, total >= max { break }
        }
        return data
    }

    // MARK: - Write / Mutations

    func writeFile(data: Data, to path: String) throws {
        do {
            let parent = (path as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: parent) {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            // attributesOfItem does not follow a symlink. fileExists(isDirectory:) does,
            // which would let an atomic write land on a target outside `parent`.
            if let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType {
                if type == FileAttributeType.typeDirectory {
                    throw FileServiceError.operationFailed("A folder already exists at \(path)")
                }
                if type == FileAttributeType.typeSymbolicLink {
                    try fm.removeItem(atPath: path)
                }
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch let e as FileServiceError {
            throw e
        } catch {
            throw mapError(error, path: path)
        }
    }

    /// Create an empty regular file. Fails if the path already exists.
    func createEmptyFile(at path: String) throws {
        if fm.fileExists(atPath: path) {
            throw FileServiceError.operationFailed("A file named that already exists.")
        }
        let parent = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            try createDirectory(at: parent)
        }
        guard fm.createFile(atPath: path, contents: Data()) else {
            throw FileServiceError.operationFailed("Could not create file at \(path)")
        }
    }

    func createDirectory(at path: String) throws {
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw mapError(error, path: path)
        }
    }

    func copyItem(at src: String, to dst: String) throws {
        do {
            try fm.copyItem(atPath: src, toPath: dst)
        } catch {
            throw mapError(error, path: src)
        }
    }

    func moveItem(at src: String, to dst: String) throws {
        do {
            try fm.moveItem(atPath: src, toPath: dst)
        } catch {
            throw mapError(error, path: src)
        }
    }

    func renameItem(at path: String, to newName: String) throws {
        let dst = (path as NSString).deletingLastPathComponent.appending("/\(newName)")
        try moveItem(at: path, to: dst)
    }

    func deleteItem(at path: String) throws {
        do {
            try fm.removeItem(atPath: path)
        } catch {
            throw mapError(error, path: path)
        }
    }

    /// Empty a folder, skipping files that refuse to delete (common under Caches).
    /// Recurses so one locked file does not keep the rest. Never follows a path
    /// that standardizes outside `path`.
    @discardableResult
    func emptyDirectoryContentsBestEffort(at path: String) -> Int {
        emptyDirectoryContentsBestEffort(at: path, stayingUnder: (path as NSString).standardizingPath)
    }

    private func emptyDirectoryContentsBestEffort(at path: String, stayingUnder root: String) -> Int {
        let std = (path as NSString).standardizingPath
        guard std == root || std.hasPrefix(root + "/") else { return 1 }
        guard isDirectory(at: path) else { return 0 }
        let children: [FileItem]
        do {
            children = try list(directory: path)
        } catch {
            return 1
        }
        var skipped = 0
        for child in children {
            let childStd = (child.path as NSString).standardizingPath
            guard childStd == root || childStd.hasPrefix(root + "/") else {
                skipped += 1
                continue
            }
            do {
                try deleteItem(at: child.path)
            } catch {
                if child.kind == .directory {
                    skipped += emptyDirectoryContentsBestEffort(at: child.path, stayingUnder: root)
                    do {
                        try deleteItem(at: child.path)
                    } catch {
                        skipped += 1
                    }
                } else {
                    skipped += 1
                }
            }
        }
        return skipped
    }

    /// Sanitized path in `directory` for `preferredName`, even if that path already exists.
    /// Uses only the last path component so `/abs` or `../x` cannot leave `directory`.
    func preferredDestination(in directory: String, preferredName: String) -> String {
        let leaf = (preferredName as NSString).lastPathComponent
        let name = FileNameRules.sanitize(leaf) ?? "extracted"
        return (directory as NSString).appendingPathComponent(name)
    }

    /// Next unused path in `directory` for `preferredName` (`foo.txt` → `foo 2.txt`).
    /// First choice is `preferredDestination`; numbering matches that same leaf.
    func uniqueDestination(in directory: String, preferredName: String) -> String {
        let preferred = preferredDestination(in: directory, preferredName: preferredName)
        if !exists(at: preferred) {
            return preferred
        }
        let ns = (preferred as NSString).lastPathComponent as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = (directory as NSString).appendingPathComponent(name)
            if !exists(at: candidate) {
                return candidate
            }
            index += 1
        }
    }

    /// Recursive inventory of a directory. Stops after `maxNodes` entries.
    func countTree(at path: String, maxNodes: Int = 20000) throws -> (files: Int, directories: Int, bytes: Int64) {
        var files = 0
        var directories = 0
        var bytes: Int64 = 0
        var nodes = 0

        func walk(_ current: String) throws {
            if nodes >= maxNodes { return }
            let entries = try list(directory: current)
            for entry in entries {
                nodes += 1
                if nodes > maxNodes { return }
                if entry.isDirectory {
                    directories += 1
                    do {
                        try walk(entry.path)
                    } catch {
                        // Locked cache folders must not zero the whole parent size.
                    }
                } else {
                    files += 1
                    bytes += entry.size
                }
            }
        }

        try walk(path)
        return (files, directories, bytes)
    }

    // MARK: - Helpers

    private func mapError(_ error: Error, path: String) -> FileServiceError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied(path)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .pathNotFound(path)
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) {
            return .permissionDenied(path)
        }
        return .operationFailed(ns.localizedDescription)
    }
}
