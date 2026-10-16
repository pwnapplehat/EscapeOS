import Foundation

/// A file or folder inside an app's container that the person wants one tap away.
struct Favorite: Codable, Hashable, Identifiable {
    let bundleIdentifier: String
    let appName: String
    /// The container the path was saved under. An app's container folder changes when it is
    /// reinstalled, so the path is re-based onto the current container when it is opened.
    let containerPath: String
    let path: String
    let name: String
    let isDirectory: Bool
    let addedAt: Date

    var id: String {
        FavoritesStore.key(bundleIdentifier: bundleIdentifier, containerPath: containerPath, path: path)
    }
}

/// Saved favorites. Kept in UserDefaults as one small JSON value; there is nothing to sync
/// and nothing here ever leaves the device.
///
/// Issue #3: asked for a Favorites place so a deeply nested file or folder does not need
/// opening app → folder → folder → file every time.
struct FavoritesStore {
    static let defaultsKey = "EscapeOS.Favorites.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Identity of a favorite: the app plus where the item sits *inside its container*.
    ///
    /// Built from path components, so `/var/x` and `/private/var/x`, or a stray trailing slash,
    /// are one favorite. Taken relative to the container so it survives a reinstall: the app's
    /// container folder changes then, but the same file is still the same favorite. A path that is
    /// not inside the given container is keyed by its full path.
    static func key(bundleIdentifier: String, containerPath: String, path: String) -> String {
        let container = PathContainment.components(of: containerPath)
        let parts = PathContainment.components(of: path)
        let inside = !container.isEmpty && parts.count >= container.count && Array(parts.prefix(container.count)) == container
        let relative = inside ? Array(parts.dropFirst(container.count)) : parts
        return bundleIdentifier + "|" + (inside ? "~/" : "/") + relative.joined(separator: "/")
    }

    /// Newest first: what was saved last is usually what is wanted next.
    func all() -> [Favorite] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else { return [] }
        return decoded.sorted { $0.addedAt > $1.addedAt }
    }

    func contains(bundleIdentifier: String, containerPath: String, path: String) -> Bool {
        let key = Self.key(bundleIdentifier: bundleIdentifier, containerPath: containerPath, path: path)
        return all().contains { $0.id == key }
    }

    /// Adds a favorite. A second add of the same item is ignored.
    @discardableResult
    func add(_ favorite: Favorite) -> Bool {
        var current = all()
        guard !current.contains(where: { $0.id == favorite.id }) else { return false }
        current.append(favorite)
        save(current)
        return true
    }

    func remove(bundleIdentifier: String, containerPath: String, path: String) {
        let key = Self.key(bundleIdentifier: bundleIdentifier, containerPath: containerPath, path: path)
        save(all().filter { $0.id != key })
    }

    /// Returns true when the item is a favorite afterwards.
    @discardableResult
    func toggle(_ favorite: Favorite) -> Bool {
        if contains(bundleIdentifier: favorite.bundleIdentifier, containerPath: favorite.containerPath, path: favorite.path) {
            remove(bundleIdentifier: favorite.bundleIdentifier, containerPath: favorite.containerPath, path: favorite.path)
            return false
        }
        add(favorite)
        return true
    }

    private func save(_ favorites: [Favorite]) {
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Reinstalled apps

    /// Where `path` (saved under `oldContainer`) lives now that the app's container is
    /// `newContainer`. Nil when the path was not inside `oldContainer` to begin with.
    static func rebased(path: String, from oldContainer: String, to newContainer: String) -> String? {
        let old = PathContainment.components(of: oldContainer)
        let target = PathContainment.components(of: path)
        guard !old.isEmpty, target.count >= old.count, Array(target.prefix(old.count)) == old else { return nil }
        let tail = target.dropFirst(old.count)
        return tail.reduce(newContainer) { ($0 as NSString).appendingPathComponent($1) }
    }
}
