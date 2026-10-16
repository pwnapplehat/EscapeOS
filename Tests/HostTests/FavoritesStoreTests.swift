import Foundation

private let containerA = "/private/var/mobile/Containers/Data/Application/AAAA"
private let containerB = "/private/var/mobile/Containers/Data/Application/BBBB"

private func fav(
    _ name: String, app: String = "com.example.app", container: String = containerA,
    path: String? = nil, folder: Bool = false, at seconds: TimeInterval = 0
) -> Favorite {
    Favorite(
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
    T.check(store.contains(bundleIdentifier: a.bundleIdentifier, containerPath: a.containerPath, path: a.path), "contains finds it")

    // identity ignores spelling
    let alias = "/var/mobile/Containers/Data/Application/AAAA/Documents/a.txt/"
    T.check(store.contains(bundleIdentifier: a.bundleIdentifier, containerPath: containerA, path: alias), "/var and a trailing slash are the same favorite")
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
    T.check(!store.contains(bundleIdentifier: t.bundleIdentifier, containerPath: t.containerPath, path: t.path), "and it is gone")

    // remove
    store.remove(bundleIdentifier: a.bundleIdentifier, containerPath: a.containerPath, path: a.path)
    T.check(!store.contains(bundleIdentifier: a.bundleIdentifier, containerPath: a.containerPath, path: a.path), "remove deletes it")
    T.equal(store.all().count, 2, "and only that one")

    // persistence across instances
    T.equal(FavoritesStore(defaults: defaults).all().count, 2, "a new store reads what was saved")

    // damaged data does not crash
    defaults.set(Data("not json".utf8), forKey: FavoritesStore.defaultsKey)
    T.equal(store.all().count, 0, "unreadable saved data reads as empty")
    T.check(store.add(fav("fresh.txt")), "and saving works again afterwards")

    // ---- an app that was reinstalled: same file, new container folder -----------------------
    do {
        let suite2 = "escapeos.host.favorites2.\(UUID().uuidString)"
        let d2 = UserDefaults(suiteName: suite2)!
        defer { d2.removePersistentDomain(forName: suite2) }
        let s = FavoritesStore(defaults: d2)
        let before = fav("notes.txt", container: containerA, at: 10)
        T.check(s.add(before), "a favorite is saved before the reinstall")

        // After the reinstall the same file is at a new path. It is still the same favorite.
        let newPath = containerB + "/Documents/notes.txt"
        T.check(s.contains(bundleIdentifier: before.bundleIdentifier, containerPath: containerB, path: newPath),
                "after a reinstall the item is still recognised as a favorite")
        T.check(!s.add(fav("notes.txt", container: containerB, at: 20)), "so it is not added a second time")
        T.equal(s.all().count, 1, "there is still exactly one")
        T.check(!s.toggle(fav("notes.txt", container: containerB, at: 30)), "toggling it off removes the original")
        T.equal(s.all().count, 0, "leaving none behind")

        // A different file in the new container is a different favorite.
        T.check(s.add(before), "re-added for the next check")
        T.check(!s.contains(bundleIdentifier: before.bundleIdentifier, containerPath: containerB, path: containerB + "/Documents/other.txt"),
                "a different file is not mistaken for it")
        // The container folder itself is its own favorite.
        T.check(s.add(fav("root", container: containerA, path: containerA, folder: true, at: 40)), "the container root can be a favorite")
        T.check(s.contains(bundleIdentifier: "com.example.app", containerPath: containerB, path: containerB), "and is recognised after a reinstall")
    }

    // key shape
    T.check(
        FavoritesStore.key(bundleIdentifier: "x", containerPath: containerA, path: containerA + "/Documents/a")
            != FavoritesStore.key(bundleIdentifier: "x", containerPath: "/", path: containerA + "/Documents/a"),
        "a path outside its container keeps its full path in the key"
    )

    // rebasing after a reinstall
    T.equal(
        FavoritesStore.rebased(path: containerA + "/Documents/deep/file.txt", from: containerA, to: containerB),
        containerB + "/Documents/deep/file.txt", "a path moves to the new container"
    )
    T.equal(
        FavoritesStore.rebased(path: "/var/mobile/Containers/Data/Application/AAAA/Library", from: containerA, to: containerB),
        containerB + "/Library", "the /var spelling rebases too"
    )
    T.equal(FavoritesStore.rebased(path: containerA, from: containerA, to: containerB), containerB, "the container itself rebases")
    T.check(
        FavoritesStore.rebased(path: "/private/var/mobile/Containers/Data/Application/ZZZZ/x", from: containerA, to: containerB) == nil,
        "a path outside the old container does not rebase"
    )
    T.check(FavoritesStore.rebased(path: containerA + "/x", from: "/", to: containerB) == nil, "an empty old container never rebases")
}
