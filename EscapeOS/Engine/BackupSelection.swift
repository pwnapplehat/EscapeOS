import Foundation

/// Metadata embedded in every backup archive as `backup.json`.
///
/// `isPartial` and `scope` were added with selective backup (issue #7). They are optional, so every
/// archive made before then still decodes, as a full backup; and an older EscapeOS reading a partial
/// one ignores them and restores just what the archive holds, which is the right thing.
struct BackupMetadata: Codable, Hashable {
    let bundleIdentifier: String
    let appName: String
    let containerPath: String
    let createdAt: String
    let fileCount: Int
    let totalBytes: Int64
    let manifestSHA256: String
    let escapeOSVersion: String
    /// True when only chosen files and folders were backed up.
    var isPartial: Bool? = nil
    /// What was chosen, from the container: `Documents/notes`, `Library/Preferences/a.plist`.
    var scope: [String]? = nil

    var isPartialBackup: Bool { isPartial == true }
}

enum BackupSelectionError: Error, LocalizedError, Equatable {
    case empty
    case outside(String)
    case unsupportedLocation(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Choose at least one file or folder to back up."
        case .outside(let name):
            return "“\(name)” is not inside this app's data."
        case .unsupportedLocation(let name):
            return "“\(name)” is outside Documents, Library and tmp, which are the only places a backup covers."
        }
    }
}

/// Which files and folders of an app's data a backup or a restore covers (issue #7).
///
/// A path is relative to the container (`Documents/notes/a.txt`). Choosing a folder covers
/// everything under it. Only `Documents`, `Library` and `tmp` can be chosen, the same places a full
/// backup covers.
struct BackupSelection: Equatable {
    /// The places a backup covers; the first path component of anything chosen.
    static let allowedRoots = ["Documents", "Library", "tmp"]

    /// Normalised, without duplicates, with anything already covered by a chosen folder left out,
    /// in a stable order.
    let paths: [String]

    /// Nil when nothing valid is left, or when any path is not valid.
    init?(paths raw: [String]) {
        var cleaned = Set<String>()
        for path in raw {
            guard let normal = Self.normalize(path) else { return nil }
            cleaned.insert(normal)
        }
        guard !cleaned.isEmpty else { return nil }
        let sorted = cleaned.sorted()
        var kept: [String] = []
        for path in sorted {
            if kept.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            kept.append(path)
        }
        self.paths = kept
        self.covered = Set(kept)
    }

    private let covered: Set<String>

    /// The chosen items as container-relative paths, or an error naming the first one that
    /// cannot be backed up.
    static func from(items: [FileItem], containerPath: String) throws -> BackupSelection {
        guard !items.isEmpty else { throw BackupSelectionError.empty }
        var relative: [String] = []
        for item in items {
            guard let path = TrashStore.relativePath(of: item.path, in: containerPath) else {
                throw BackupSelectionError.outside(item.name)
            }
            guard normalize(path) != nil else { throw BackupSelectionError.unsupportedLocation(item.name) }
            relative.append(path)
        }
        guard let selection = BackupSelection(paths: relative) else { throw BackupSelectionError.empty }
        return selection
    }

    /// `a/b` for `a//b/`, or nil for an empty path, `.` / `..`, an absolute path, or one that does
    /// not start in an allowed root.
    static func normalize(_ path: String) -> String? {
        guard !path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, allowedRoots.contains(first) else { return nil }
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// True when `manifestPath` is a chosen file, or inside a chosen folder.
    func covers(_ manifestPath: String) -> Bool {
        if covered.contains(manifestPath) { return true }
        // Walk up the path, so a deep file costs its depth, not the size of the selection.
        var path = manifestPath
        while let slash = path.lastIndex(of: "/") {
            path = String(path[path.startIndex..<slash])
            if covered.contains(path) { return true }
        }
        return false
    }

    func filter(_ manifest: [BackupManifestEntry]) -> [BackupManifestEntry] {
        manifest.filter { covers($0.path) }
    }
}

/// Words for a backup in the Backups list.
enum BackupDescription {
    static func subtitle(for metadata: BackupMetadata) -> String {
        var parts: [String] = []
        if metadata.isPartialBackup {
            parts.append("Partial")
            if let scope = metadata.scope, !scope.isEmpty {
                parts.append(scope.count == 1 ? "1 item" : "\(scope.count) items")
            }
        }
        parts.append(metadata.fileCount == 1 ? "1 file" : "\(metadata.fileCount) files")
        parts.append(bytes(metadata.totalBytes))
        return parts.joined(separator: " · ")
    }

    /// What a partial backup covers, by name: `notes, a.plist and 2 more`. Nil for a full backup.
    static func scopeSummary(for metadata: BackupMetadata) -> String? {
        guard metadata.isPartialBackup, let scope = metadata.scope, !scope.isEmpty else { return nil }
        let names = scope.map { ($0 as NSString).lastPathComponent }
        let shown = Array(names.prefix(3))
        if names.count <= 3 {
            if shown.count == 1 { return shown[0] }
            return shown.dropLast().joined(separator: ", ") + " and " + (shown.last ?? "")
        }
        return shown.joined(separator: ", ") + " and \(names.count - 3) more"
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}

// MARK: - Choosing what to restore

/// A file or folder in a backup, for the picker.
struct ManifestNode: Identifiable, Equatable {
    /// The full path within the backup, which is also what a selection holds.
    let id: String
    let name: String
    let isDirectory: Bool
    var bytes: Int64
    var fileCount: Int
    /// Nil for a file, so a SwiftUI `List(_, children:)` shows no disclosure for it.
    var children: [ManifestNode]?
    /// The files under this node, as a range of `ManifestTree.filePaths`. A file's is one long.
    let fileRange: Range<Int>
}

/// A backup's manifest as a tree of folders and files.
struct ManifestTree {
    let roots: [ManifestNode]
    /// Every file, in the order the tree shows them, so each folder covers a contiguous range.
    let filePaths: [String]
    let fileBytes: [Int64]

    init(manifest: [BackupManifestEntry]) {
        final class Builder {
            let name: String
            let path: String
            var size: Int64 = 0
            var isFile = false
            var children: [String: Builder] = [:]
            init(name: String, path: String) { self.name = name; self.path = path }
        }
        let top = Builder(name: "", path: "")
        for entry in manifest {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            var node = top
            var path = ""
            for part in parts {
                path = path.isEmpty ? part : path + "/" + part
                if let existing = node.children[part] {
                    node = existing
                } else {
                    let made = Builder(name: part, path: path)
                    node.children[part] = made
                    node = made
                }
            }
            node.isFile = true
            node.size = Int64(entry.size)
        }

        var paths: [String] = []
        var sizes: [Int64] = []
        func convert(_ builder: Builder) -> ManifestNode {
            if builder.isFile && builder.children.isEmpty {
                let index = paths.count
                paths.append(builder.path)
                sizes.append(builder.size)
                return ManifestNode(
                    id: builder.path, name: builder.name, isDirectory: false,
                    bytes: builder.size, fileCount: 1, children: nil, fileRange: index..<(index + 1)
                )
            }
            let start = paths.count
            let ordered = builder.children.values.sorted { lhs, rhs in
                let lhsFolder = !(lhs.isFile && lhs.children.isEmpty)
                let rhsFolder = !(rhs.isFile && rhs.children.isEmpty)
                if lhsFolder != rhsFolder { return lhsFolder }
                return lhs.name.lowercased() == rhs.name.lowercased() ? lhs.name < rhs.name : lhs.name.lowercased() < rhs.name.lowercased()
            }
            let kids = ordered.map(convert)
            return ManifestNode(
                id: builder.path, name: builder.name, isDirectory: true,
                bytes: kids.reduce(0) { $0 + $1.bytes }, fileCount: kids.reduce(0) { $0 + $1.fileCount },
                children: kids, fileRange: start..<paths.count
            )
        }
        let rootNodes = convert(top).children ?? []
        self.roots = rootNodes
        self.filePaths = paths
        self.fileBytes = sizes
    }
}

enum CheckState: Equatable {
    case none
    case some
    case all
}

/// Which files of a backup are ticked in the picker. A folder is ticked when every file under it is.
struct ManifestSelection {
    let tree: ManifestTree
    private(set) var selected: Set<Int> = []

    init(tree: ManifestTree, selectAll: Bool = false) {
        self.tree = tree
        if selectAll { selected = Set(0..<tree.filePaths.count) }
    }

    func state(of node: ManifestNode) -> CheckState {
        guard !node.fileRange.isEmpty else { return .none }
        var count = 0
        for index in node.fileRange where selected.contains(index) { count += 1 }
        if count == 0 { return .none }
        return count == node.fileRange.count ? .all : .some
    }

    /// Tick everything under the node, unless it is already fully ticked, which unticks it.
    mutating func toggle(_ node: ManifestNode) {
        if state(of: node) == .all {
            for index in node.fileRange { selected.remove(index) }
        } else {
            for index in node.fileRange { selected.insert(index) }
        }
    }

    mutating func selectAll() { selected = Set(0..<tree.filePaths.count) }
    mutating func clear() { selected.removeAll() }

    var selectedFileCount: Int { selected.count }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + tree.fileBytes[$1] } }
    var isEmpty: Bool { selected.isEmpty }
    var isEverything: Bool { selected.count == tree.filePaths.count && !tree.filePaths.isEmpty }

    /// The ticked files as a restore selection, or nil when none are ticked.
    var backupSelection: BackupSelection? {
        guard !selected.isEmpty else { return nil }
        return BackupSelection(paths: selected.sorted().map { tree.filePaths[$0] })
    }
}
