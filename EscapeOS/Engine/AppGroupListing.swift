import Foundation

/// One App Group belonging to an installed app.
struct AppGroupContainer: Hashable, Identifiable {
    let identifier: String
    /// Absolute folder when the install record included one. Nil means the identifier is known
    /// and the folder is not.
    let path: String?
    var id: String { identifier }
    var canBrowse: Bool { path?.hasPrefix("/") == true }
}

/// Reads App Group identifiers and folders out of an installation_proxy app record.
enum AppGroupListing {
    /// Group id to folder, then any group id that has no folder yet.
    static func containers(in info: [String: Any]) -> [AppGroupContainer] {
        var paths: [String: String] = [:]
        if let groups = info["GroupContainers"] as? [String: Any] {
            for (key, value) in groups {
                guard key.hasPrefix("group."), let path = folderPath(from: value) else { continue }
                paths[key] = path
            }
        }
        var identifiers = Set(paths.keys)
        if let entitlements = info["Entitlements"] as? [String: Any],
           let listed = entitlements["com.apple.security.application-groups"] as? [String] {
            for identifier in listed where identifier.hasPrefix("group.") {
                identifiers.insert(identifier)
            }
        }
        return identifiers.sorted().map { AppGroupContainer(identifier: $0, path: paths[$0]) }
    }

    /// Keys whose names mention groups, so a device log can show the real field when none parsed.
    static func groupKeyNames(in info: [String: Any]) -> [String] {
        info.keys.filter { $0.range(of: "group", options: .caseInsensitive) != nil }.sorted()
    }

    private static func folderPath(from value: Any) -> String? {
        if let path = value as? String, path.hasPrefix("/") {
            return path
        }
        if let record = value as? [String: Any] {
            for key in ["Path", "path", "Container"] {
                if let path = record[key] as? String, path.hasPrefix("/") {
                    return path
                }
            }
        }
        return nil
    }
}
