import SwiftUI
import UIKit

/// View model for the app picker.
final class AppListViewModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var needsPairing = false
    @Published var icons: [String: UIImage] = [:]

    private let discovery = AppDiscovery()

    var hasPairingFile: Bool { discovery.hasPairingFile }

    func reload() {
        isLoading = true
        errorMessage = nil
        needsPairing = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let found = try self.discovery.fetchInstalledApps()
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.apps = found
                    self.errorMessage = nil
                    self.icons = [:]
                }
                self.loadIcons(for: found)
            } catch let e as AppDiscoveryError {
                DispatchQueue.main.async {
                    self.isLoading = false
                    if case .noPairingFile = e {
                        self.needsPairing = true
                    } else {
                        self.errorMessage = e.localizedDescription
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Fetch icons concurrently and publish each one as soon as it arrives.
    private func loadIcons(for apps: [InstalledApp]) {
        let ids = apps.map { $0.bundleIdentifier }
        guard !ids.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            DispatchQueue.concurrentPerform(iterations: ids.count) { index in
                let bundleId = ids[index]
                guard let icon = self.discovery.appIcon(for: bundleId) else { return }
                DispatchQueue.main.async {
                    self.icons[bundleId] = icon
                }
            }
        }
    }

    func importPairingFile(_ contents: String) throws {
        try discovery.importPairingFile(contents)
    }

    func resetPairing() {
        discovery.resetPairing()
        apps = []
        icons = [:]
        reload()
    }

    /// Load a single icon on demand (e.g. when opening app detail before batch fetch finishes).
    func ensureIcon(for bundleId: String) {
        guard icons[bundleId] == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let icon = self.discovery.appIcon(for: bundleId) else { return }
            DispatchQueue.main.async {
                self.icons[bundleId] = icon
            }
        }
    }
}

/// Scrollable list of installed user apps, with search and A–Z jump index.
struct AppListView: View {
    @ObservedObject var viewModel: AppListViewModel
    @State private var searchText = ""

    var body: some View {
        let visible = filteredApps
        ScrollViewReader { proxy in
            List {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    FavoritesSection(viewModel: viewModel)
                }
                if visible.isEmpty {
                    Text(emptyListMessage)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(sections(in: visible), id: \.letter) { section in
                        Section(header: Text(section.letter).id(section.letter)) {
                            ForEach(section.apps) { app in
                                NavigationLink(destination: AppDetailView(app: app, viewModel: viewModel)) {
                                    HStack(spacing: 12) {
                                        AppIconView(icon: viewModel.icons[app.bundleIdentifier])
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.name)
                                                .font(.body)
                                            Text(app.bundleIdentifier)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .contextMenu {
                                    Button {
                                        FileClipboard.copyText(
                                            app.bundleIdentifier,
                                            confirmation: "Copied Bundle ID"
                                        )
                                    } label: {
                                        Label("Copy Bundle ID", systemImage: "doc.on.doc")
                                    }
                                    Button {
                                        FileClipboard.copyText(app.name, confirmation: "Copied Name")
                                    } label: {
                                        Label("Copy Name", systemImage: "character.cursor.ibeam")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .trailing) {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   visible.count > 8 {
                    sectionIndex(letters: sections(in: visible).map(\.letter), proxy: proxy)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search apps")
    }

    private var emptyListMessage: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "No apps found."
        }
        return "No apps match “\(query)”."
    }

    private var filteredApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.apps }
        return viewModel.apps.filter { app in
            app.name.localizedCaseInsensitiveContains(query)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private func sections(in apps: [InstalledApp]) -> [(letter: String, apps: [InstalledApp])] {
        let grouped = Dictionary(grouping: apps) { app -> String in
            let folded = app.name.folding(options: .diacriticInsensitive, locale: .current)
            guard let ch = folded.uppercased().first, ch.isLetter else { return "#" }
            return String(ch)
        }
        let keys = grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return keys.map { letter in
            let rows = (grouped[letter] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return (letter, rows)
        }
    }

    private func sectionIndex(letters: [String], proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(minWidth: 14, minHeight: 12)
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 1)
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                jumpToLetter(
                                    at: value.location.y,
                                    height: geo.size.height,
                                    letters: letters,
                                    proxy: proxy
                                )
                            }
                    )
            }
        }
    }

    private func jumpToLetter(at y: CGFloat, height: CGFloat, letters: [String], proxy: ScrollViewProxy) {
        guard !letters.isEmpty, height > 0 else { return }
        let unit = height / CGFloat(letters.count)
        let index = Int((y / unit).rounded(.down))
        let clamped = min(max(index, 0), letters.count - 1)
        proxy.scrollTo(letters[clamped], anchor: .top)
    }
}
