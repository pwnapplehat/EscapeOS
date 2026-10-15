import SwiftUI

/// Observable wrapper around `FavoritesStore` so lists update when a favorite is added or removed.
final class FavoritesModel: ObservableObject {
    static let shared = FavoritesModel()

    @Published private(set) var items: [Favorite]
    private let store: FavoritesStore

    init(store: FavoritesStore = FavoritesStore()) {
        self.store = store
        self.items = store.all()
    }

    func isFavorite(app: InstalledApp, path: String) -> Bool {
        store.contains(bundleIdentifier: app.bundleIdentifier, path: path)
    }

    /// Returns true when the item is a favorite afterwards.
    @discardableResult
    func toggle(app: InstalledApp, item: FileItem) -> Bool {
        let favorite = Favorite(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            containerPath: app.containerPath,
            path: item.path,
            name: item.name,
            isDirectory: item.isDirectory,
            addedAt: Date()
        )
        let now = store.toggle(favorite)
        items = store.all()
        return now
    }

    func remove(_ favorite: Favorite) {
        store.remove(bundleIdentifier: favorite.bundleIdentifier, path: favorite.path)
        items = store.all()
    }
}

/// The Favorites section at the top of the Apps list.
struct FavoritesSection: View {
    @ObservedObject var viewModel: AppListViewModel
    @ObservedObject private var favorites = FavoritesModel.shared

    var body: some View {
        if !favorites.items.isEmpty {
            Section(header: Text("Favorites")) {
                ForEach(favorites.items) { favorite in
                    if let app = installedApp(for: favorite) {
                        NavigationLink(destination: FavoriteDestination(app: app, favorite: favorite)) {
                            row(for: favorite, note: nil)
                        }
                    } else {
                        row(for: favorite, note: "App not installed")
                            .foregroundColor(.secondary)
                    }
                }
                .onDelete { offsets in
                    let targets = offsets.compactMap { $0 < favorites.items.count ? favorites.items[$0] : nil }
                    targets.forEach { favorites.remove($0) }
                }
            }
        }
    }

    private func installedApp(for favorite: Favorite) -> InstalledApp? {
        viewModel.apps.first { $0.bundleIdentifier == favorite.bundleIdentifier }
    }

    private func row(for favorite: Favorite, note: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: favorite.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundColor(favorite.isDirectory ? .accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.name)
                    .font(.body)
                Text(note ?? favorite.appName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Opens a favorite at its current place, even if the app was reinstalled and its container moved.
struct FavoriteDestination: View {
    let app: InstalledApp
    let favorite: Favorite

    var body: some View {
        let path = FavoritesStore.rebased(path: favorite.path, from: favorite.containerPath, to: app.containerPath)
            ?? favorite.path
        if favorite.isDirectory {
            FileBrowserView(app: app, initialPath: path)
        } else {
            FileViewerView(
                app: app,
                item: FileItem(
                    name: favorite.name,
                    path: path,
                    kind: .regular,
                    size: 0,
                    modified: nil,
                    isReadable: true,
                    isWritable: true
                ),
                mode: .auto
            )
        }
    }
}
