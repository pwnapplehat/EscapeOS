import Foundation

/// How a file should be opened by default.
enum FileOpenMode: String, Hashable {
    case auto
    case preview
    case text
    case hex
    case image
    case pdf
    case media
}

/// Classifies a file by extension for icons and default open behavior.
enum FileContentKind: String {
    case directory
    case image
    case pdf
    case audio
    case video
    case text
    case plist
    case json
    case xml
    case archive
    case database
    case binary

    var symbolName: String {
        switch self {
        case .directory: return "folder.fill"
        case .image: return "photo"
        case .pdf: return "doc.richtext.fill"
        case .audio: return "waveform"
        case .video: return "film.fill"
        case .text: return "doc.plaintext.fill"
        case .plist: return "list.bullet.rectangle"
        case .json: return "curlybraces"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .archive: return "doc.zipper"
        case .database: return "cylinder.split.1x2"
        case .binary: return "doc.fill"
        }
    }

    static func classify(name: String, isDirectory: Bool) -> FileContentKind {
        if isDirectory { return .directory }
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if plistExtensions.contains(ext) { return .plist }
        if jsonExtensions.contains(ext) { return .json }
        if xmlExtensions.contains(ext) { return .xml }
        if archiveExtensions.contains(ext) { return .archive }
        if databaseExtensions.contains(ext) { return .database }
        if textExtensions.contains(ext) { return .text }
        return .binary
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "ico", "svg"
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "amr"
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "3gp", "3gpp"
    ]
    static let plistExtensions: Set<String> = [
        "plist", "entitlements", "mobileprovision", "mobileconfig", "strings"
    ]
    static let jsonExtensions: Set<String> = ["json", "jsonl"]
    static let xmlExtensions: Set<String> = ["xml", "html", "htm", "xhtml", "svg"]
    static let archiveExtensions: Set<String> = [
        "zip", "ipa", "apk", "jar", "deb", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
        "7z", "rar", "xz", "txz", "lz4", "lzma"
    ]
    static let databaseExtensions: Set<String> = [
        "db", "sqlite", "sqlite3", "realm", "wal", "shm"
    ]
    static let textExtensions: Set<String> = [
        "txt", "text", "log", "md", "markdown", "csv", "tsv", "yml", "yaml",
        "ini", "conf", "cfg", "env", "toml", "rtf",
        "c", "h", "m", "mm", "cpp", "cc", "hpp", "swift", "js", "ts", "jsx", "tsx",
        "py", "rb", "php", "java", "kt", "go", "rs", "sh", "bash", "zsh", "lua",
        "css", "scss", "less", "sql", "pbxproj", "xcconfig", "gitignore",
        "dockerfile", "makefile", "mk", "plist", "strings", "entitlements",
        "json", "xml", "html", "htm", "svg"
    ]
}

enum FileNameRules {
    static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("/") && !trimmed.contains("\\") && trimmed != "." && trimmed != ".." else {
            return nil
        }
        return trimmed
    }
}

/// Decides whether a path lies inside a folder by comparing path components only.
///
/// `NSString.standardizingPath` is not safe for this. It drops a leading `/private` only when
/// the result exists on disk, so a folder that exists is normalized to `/var/...` while a file
/// that is about to be created keeps `/private/var/...`, and `hasPrefix` then rejects a path
/// that is plainly inside the folder. App containers are reported as `/private/var/mobile/...`,
/// which is how adding a new file and "Keep Both" failed with "outside this app's data".
/// Nothing here touches the file system, so the answer cannot depend on what exists.
enum PathContainment {
    /// `/private/var`, `/private/tmp` and `/private/etc` are the same folders as `/var`, `/tmp`
    /// and `/etc`; the leading `private` is dropped for those by name.
    private static let privateAliases: Set<String> = ["var", "tmp", "etc"]

    static func components(of path: String) -> [String] {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(String(part))
            }
        }
        if parts.count > 1, parts[0] == "private", privateAliases.contains(parts[1]) {
            parts.removeFirst()
        }
        return parts
    }

    /// True when `path` is `root` itself or somewhere beneath it.
    static func isInside(_ path: String, root: String) -> Bool {
        let base = components(of: root)
        guard !base.isEmpty else { return false }
        let target = components(of: path)
        return target.count >= base.count && Array(target.prefix(base.count)) == base
    }
}

/// Resolves an archive member name under `destDir`. Rejects `..` and paths that escape the folder.
enum ArchiveEntryPath {
    static func resolve(_ entryName: String, under destDir: String) throws -> (path: String, isDirectory: Bool) {
        let root = (destDir as NSString).standardizingPath
        let normalized = entryName.replacingOccurrences(of: "\\", with: "/")
        let isDirectory = normalized.hasSuffix("/")
        let parts = normalized.split(separator: "/").map(String.init)
        if parts.contains("..") {
            throw FileServiceError.operationFailed("Unsafe path in archive: \(entryName)")
        }
        let dest = parts.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
        let destStd = (dest as NSString).standardizingPath
        guard destStd == root || destStd.hasPrefix(root + "/") else {
            throw FileServiceError.operationFailed("Unsafe path in archive: \(entryName)")
        }
        return (destStd, isDirectory)
    }
}
