import Foundation

private func fav(_ name: String, app: String = "com.example.app", path: String? = nil, folder: Bool = false, at seconds: TimeInterval = 0) -> Favorite {
    let container = "/private/var/mobile/Containers/Data/Application/AAAA"
    return Favorite(
        bundleIdentifier: app, appName: "Example", containerPath: container,
        path: path ?? container + "/Documents/" + name, name: name, isDirectory: folder,
        addedAt: Date(timeIntervalSince1970: seconds)
    )
}

func runFavoritesStoreTests() {
    T.section("FavoritesStore")
    let suite = "escapeos.host.favorites.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = FavoritesStore(defaults: defaults)

    T.equal(store.all().count, 0, "starts empty")

    let a = fav("a.txt", at: 100)
    T.check(store.add(a), "adding returns true")
    T.check(!store.add(a), "adding the same item again is ignored")
    T.equal(store.all().count, 1, "so there is still one")
    T.check(store.contains(bundleIdentifier: a.bundleIdentifier, path: a.path), "contains finds it")

    // identity ignores spelling
    let alias = "/var/mobile/Containers/Data/Application/AAAA/Documents/a.txt/"
    T.check(store.contains(bundleIdentifier: a.bundleIdentifier, path: alias), "/var and a trailing slash are the same favorite")
    T.check(!store.add(fav("a.txt", path: alias, at: 200)), "so it cannot be added twice under another spelling")

    // same path in another app is a different favorite
    T.check(store.add(fav("a.txt", app: "com.other.app", at: 300)), "the same path in another app is its own favorite")
    T.equal(store.all().count, 2, "two favorites now")

    // newest first
    T.equal(store.all().map(\.bundleIdentifier), ["com.other.app", "com.example.app"], "newest is listed first")

    // folders and files both work
    T.check(store.add(fav("Reports", folder: true, at: 400)), "a folder can be a favorite")
    T.check(store.all().first?.isDirectory == true, "and is stored as a folder")

    // toggle
    let t = fav("toggle.bin", at: 500)
    T.check(store.toggle(t), "toggle on adds")
    T.check(!store.toggle(t), "toggle off removes")
    T.check(!store.contains(bundleIdentifier: t.bundleIdentifier, path: t.path), "and it is gone")

    // remove
    store.remove(bundleIdentifier: a.bundleIdentifier, path: a.path)
    T.check(!store.contains(bundleIdentifier: a.bundleIdentifier, path: a.path), "remove deletes it")
    T.equal(store.all().count, 2, "and only that one")

    // persistence across instances
    T.equal(FavoritesStore(defaults: defaults).all().count, 2, "a new store reads what was saved")

    // damaged data does not crash
    defaults.set(Data("not json".utf8), forKey: FavoritesStore.defaultsKey)
    T.equal(store.all().count, 0, "unreadable saved data reads as empty")
    T.check(store.add(fav("fresh.txt")), "and saving works again afterwards")

    // rebasing after a reinstall
    let oldRoot = "/private/var/mobile/Containers/Data/Application/AAAA"
    let newRoot = "/private/var/mobile/Containers/Data/Application/BBBB"
    T.equal(
        FavoritesStore.rebased(path: oldRoot + "/Documents/deep/file.txt", from: oldRoot, to: newRoot),
        newRoot + "/Documents/deep/file.txt", "a path moves to the new container"
    )
    T.equal(
        FavoritesStore.rebased(path: "/var/mobile/Containers/Data/Application/AAAA/Library", from: oldRoot, to: newRoot),
        newRoot + "/Library", "the /var spelling rebases too"
    )
    T.equal(FavoritesStore.rebased(path: oldRoot, from: oldRoot, to: newRoot), newRoot, "the container itself rebases")
    T.check(
        FavoritesStore.rebased(path: "/private/var/mobile/Containers/Data/Application/ZZZZ/x", from: oldRoot, to: newRoot) == nil,
        "a path outside the old container does not rebase"
    )
    T.check(FavoritesStore.rebased(path: oldRoot + "/x", from: "/", to: newRoot) == nil, "an empty old container never rebases")
}
