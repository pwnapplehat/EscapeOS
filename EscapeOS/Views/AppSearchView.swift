import SwiftUI

/// Searches every file and folder name under one app's container, not just the folder on screen.
struct AppSearchView: View {
    let app: InstalledApp
    let onSelect: (SearchHit) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AppSearchModel
    @State private var query = ""

    init(app: InstalledApp, onSelect: @escaping (SearchHit) -> Void) {
        self.app = app
        self.onSelect = onSelect
        _model = StateObject(wrappedValue: AppSearchModel(app: app))
    }

    var body: some View {
        NavigationView {
            List {
                if model.isSearching {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Searching… \(model.scanned) items checked")
                            .foregroundColor(.secondary)
                    }
                }
                ForEach(model.hits) { hit in
                    Button {
                        model.cancel()
                        onSelect(hit)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: hit.item.isDirectory ? "folder.fill" : "doc")
                                .foregroundColor(hit.item.isDirectory ? .accentColor : .secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.item.name)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(Self.location(of: hit))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let note = model.footnote {
                    Text(note)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search \(app.name)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "File or folder name"
            )
            .onSubmit(of: .search) { model.search(query: query) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { model.cancel() }
    }

    /// The folder a hit sits in, relative to the app, or "App folder" for the top level.
    static func location(of hit: SearchHit) -> String {
        let parent = (hit.relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "App folder" : parent
    }
}

/// Runs the search off the main thread and drops results from a search that was replaced or
/// cancelled, so a slow search never overwrites a newer one.
final class AppSearchModel: ObservableObject {
    @Published var hits: [SearchHit] = []
    @Published var isSearching = false
    @Published var scanned = 0
    @Published var footnote: String?

    private let app: InstalledApp
    private let escape = SandboxEscape()
    private let files = FileService()
    private let lock = NSLock()
    private var generation = 0

    init(app: InstalledApp) {
        self.app = app
    }

    private func bumpGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == value
    }

    func cancel() {
        _ = bumpGeneration()
        isSearching = false
    }

    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let mine = bumpGeneration()
        hits = []
        scanned = 0
        footnote = nil
        guard !ContainerSearch.terms(from: trimmed).isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outcome = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    ContainerSearch.search(
                        root: self.app.containerPath,
                        query: trimmed,
                        files: self.files,
                        progress: { count in
                            DispatchQueue.main.async {
                                if self.isCurrent(mine) { self.scanned = count }
                            }
                        },
                        isCancelled: { !self.isCurrent(mine) }
                    )
                }
                DispatchQueue.main.async {
                    guard self.isCurrent(mine) else { return }
                    self.isSearching = false
                    self.scanned = outcome.scanned
                    self.hits = outcome.hits
                    if outcome.truncated {
                        self.footnote = "Showing the first \(outcome.hits.count) matches. Use more of the name to narrow it down."
                    } else if outcome.hits.isEmpty {
                        self.footnote = "No file or folder here has “\(trimmed)” in its name."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.isCurrent(mine) else { return }
                    self.isSearching = false
                    self.footnote = error.localizedDescription
                }
            }
        }
    }
}
