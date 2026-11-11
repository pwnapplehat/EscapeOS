import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Filza-style file browser for a single app container.
struct FileBrowserView: View {
    let app: InstalledApp

    @StateObject private var vm: FileBrowserViewModel
    @ObservedObject private var clipboard = FileClipboard.shared
    @State private var createKind: CreateKind?
    @State private var createName = ""
    @State private var renameItem: FileItem?
    @State private var renameName = ""
    @State private var searchText = ""
    @State private var openRequest: OpenRequest?
    @State private var propertiesItem: FileItem?
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var pendingDelete: [FileItem] = []
    @AppStorage(DeleteConfirmation.preferenceKey) private var confirmFileDeletes = true
    @State private var archivePassword = ""
    @State private var showImportCollision = false
    @State private var showPasteCollision = false
    @State private var showDropCollision = false
    @State private var showAppSearch = false
    @State private var showTrash = false
    @State private var jumpFolder: String?
    @State private var pendingSearchHit: SearchHit?
    /// The folder row (or `vm.currentPath` for the whole list) a drag is hovering over.
    @State private var dropTarget: String?
    @ObservedObject private var favorites = FavoritesModel.shared

    init(app: InstalledApp) {
        self.app = app
        _vm = StateObject(wrappedValue: FileBrowserViewModel(app: app))
    }

    init(app: InstalledApp, initialPath: String) {
        self.app = app
        _vm = StateObject(wrappedValue: FileBrowserViewModel(app: app, initialPath: initialPath))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.items.isEmpty {
                ProgressView("Opening container…")
            } else if let error = vm.errorMessage, vm.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Retry") { vm.open(vm.currentPath) }
                }
            } else {
                fileList
            }
        }
        .navigationTitle(selecting ? selectionTitle : vm.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter this folder")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if selecting {
                    Button(allVisibleSelected ? "Deselect All" : "Select All") {
                        if allVisibleSelected {
                            selected.removeAll()
                        } else {
                            selected.formUnion(visibleItems.map(\.path))
                        }
                    }
                    .disabled(visibleItems.isEmpty)
                    Button("Done") { exitSelection() }
                } else {
                    if !clipboard.isEmpty {
                        Button {
                            vm.paste()
                        } label: {
                            Image(systemName: clipboard.payload?.mode == .cut ? "scissors" : "doc.on.clipboard")
                        }
                        .disabled(vm.isBusy)
                        .accessibilityLabel(clipboard.pasteTitle)
                    }
                    Button("Select") { enterSelection() }
                    Menu {
                        if !clipboard.isEmpty {
                            Button {
                                vm.paste()
                            } label: {
                                Label(clipboard.pasteTitle, systemImage: "doc.on.clipboard")
                            }
                            .disabled(vm.isBusy)
                            Button("Clear Clipboard", role: .destructive) {
                                clipboard.clear()
                            }
                        }
                        Button {
                            createName = "New File.txt"
                            createKind = .file
                        } label: {
                            Label("New File", systemImage: "doc.badge.plus")
                        }
                        Button {
                            createName = "New Folder"
                            createKind = .folder
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        Button {
                            FilePickerPresenter.present(
                                contentTypes: [.item, .data, .content, .archive, .image, .text, .sourceCode, .propertyList],
                                allowsMultiple: true
                            ) { urls in
                                FilePickerPresenter.noteReceived(urls)
                                vm.importFiles(from: urls)
                            }
                        } label: {
                            Label("Import from Files", systemImage: "square.and.arrow.down")
                        }
                        .disabled(vm.isBusy || vm.pendingImport != nil)
                        Button {
                            showTrash = true
                        } label: {
                            Label("Trash", systemImage: "trash")
                        }
                        Button {
                            showAppSearch = true
                        } label: {
                            Label("Search Whole App", systemImage: "magnifyingglass")
                        }
                        Button {
                            favorites.toggle(app: app, item: currentFolderItem)
                        } label: {
                            if favorites.isFavorite(app: app, path: vm.currentPath) {
                                Label("Remove Folder from Favorites", systemImage: "star.slash")
                            } else {
                                Label("Add Folder to Favorites", systemImage: "star")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                selectionBar
            }
        }
        .overlay {
            if vm.isBusy {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.15)
                        Text(vm.busyTitle)
                            .font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(vm.busyTitle)
            }
        }
        .onAppear { vm.open(vm.currentPath) }
        .background(
            ZStack {
                NavigationLink(
                    destination: Group {
                        if let request = openRequest {
                            FileViewerView(app: app, item: request.item, mode: request.mode)
                        }
                    },
                    isActive: Binding(
                        get: { openRequest != nil },
                        set: { if !$0 { openRequest = nil } }
                    )
                ) { EmptyView() }
                .hidden()
                NavigationLink(
                    destination: Group {
                        if let folder = jumpFolder {
                            FileBrowserView(app: app, initialPath: folder)
                        }
                    },
                    isActive: Binding(
                        get: { jumpFolder != nil },
                        set: { if !$0 { jumpFolder = nil } }
                    )
                ) { EmptyView() }
                .hidden()
            }
        )
        .sheet(item: $vm.sharePayload) { payload in
            ActivityShareView(urls: payload.urls)
        }
        .sheet(isPresented: $showTrash, onDismiss: { vm.open(vm.currentPath) }) {
            NavigationView {
                TrashView(apps: [app], appsAreComplete: false)
            }
        }
        .alert(item: $vm.exportError) { err in
            Alert(title: Text("Could not prepare files to share"), message: Text(err.message), dismissButton: .default(Text("OK")))
        }
        .alert(item: $vm.operationError) { err in
            Alert(title: Text("File Operation Failed"), message: Text(err.message), dismissButton: .default(Text("OK")))
        }
        .alert("Archive Password", isPresented: Binding(
            get: { vm.unzipPasswordItem != nil },
            set: { if !$0 { vm.clearUnzipPasswordPrompt() } }
        )) {
            SecureField("Password", text: $archivePassword)
                .disableAutocorrection(true)
                .autocapitalization(.none)
            Button("Cancel", role: .cancel) {
                archivePassword = ""
                vm.clearUnzipPasswordPrompt()
            }
            Button("Extract") {
                if let item = vm.unzipPasswordItem {
                    vm.unzip(item: item, password: archivePassword)
                }
                archivePassword = ""
            }
        } message: {
            Text(vm.unzipPasswordMessage)
        }
        .alert("New \(createKind == .folder ? "Folder" : "File")", isPresented: Binding(
            get: { createKind != nil },
            set: { if !$0 { createKind = nil } }
        )) {
            TextField("Name", text: $createName)
                .disableAutocorrection(true)
                .autocapitalization(.none)
            Button("Cancel", role: .cancel) { createKind = nil }
            Button("Create") {
                if let kind = createKind {
                    vm.create(name: createName, kind: kind)
                }
                createKind = nil
            }
        }
        .alert("Rename", isPresented: Binding(
            get: { renameItem != nil },
            set: { if !$0 { renameItem = nil } }
        )) {
            TextField("New name", text: $renameName)
                .disableAutocorrection(true)
                .autocapitalization(.none)
            Button("Cancel", role: .cancel) { renameItem = nil }
            Button("Rename") {
                if let item = renameItem {
                    vm.rename(item: item, to: renameName)
                }
                renameItem = nil
            }
        }
        .alert(deletePrompt.title, isPresented: Binding(
            get: { !pendingDelete.isEmpty },
            set: { if !$0 { pendingDelete = [] } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = [] }
            Button(deletePrompt.confirmLabel, role: .destructive) {
                vm.delete(items: pendingDelete)
                selected.subtract(pendingDelete.map(\.path))
                pendingDelete = []
            }
            if deletePrompt.offersDontAskAgain {
                Button(deletePrompt.dontAskLabel, role: .destructive) {
                    confirmFileDeletes = false
                    vm.delete(items: pendingDelete)
                    selected.subtract(pendingDelete.map(\.path))
                    pendingDelete = []
                }
            }
        } message: {
            Text(deletePrompt.message)
        }
        .alert(
            vm.pendingImportTitle,
            isPresented: $showImportCollision,
            presenting: vm.pendingImport
        ) { prompt in
            Button("Cancel", role: .cancel) {
                vm.cancelPendingImport()
            }
            Button("Keep Both") {
                vm.finishPendingImport(prompt, policy: .keepBoth)
            }
            if !prompt.collidingFileNames.isEmpty {
                Button("Replace") {
                    vm.finishPendingImport(prompt, policy: .replace)
                }
            }
        } message: { prompt in
            Text(FileBrowserViewModel.importCollisionMessage(for: prompt))
        }
        .onChange(of: vm.pendingImport?.id) { _ in
            showImportCollision = vm.pendingImport != nil
        }
        .alert(
            vm.pendingPasteTitle,
            isPresented: $showPasteCollision,
            presenting: vm.pendingPaste
        ) { choice in
            Button("Cancel", role: .cancel) {
                vm.cancelPendingPaste()
            }
            Button("Keep Both") {
                vm.finishPendingPaste(choice, policy: .keepBoth)
            }
            if choice.plan.canReplace {
                Button("Replace", role: .destructive) {
                    vm.finishPendingPaste(choice, policy: .replace)
                }
            }
        } message: { choice in
            Text(PasteConflictPlanner.message(for: choice.plan))
        }
        .onChange(of: vm.pendingPaste?.id) { _ in
            showPasteCollision = vm.pendingPaste != nil
        }
        .alert(
            vm.pendingDropTitle,
            isPresented: $showDropCollision,
            presenting: vm.pendingDrop
        ) { choice in
            Button("Cancel", role: .cancel) {
                vm.cancelPendingDrop()
            }
            Button("Keep Both") {
                vm.finishPendingDrop(choice, policy: .keepBoth)
            }
            if choice.plan.canReplace {
                Button("Replace", role: .destructive) {
                    vm.finishPendingDrop(choice, policy: .replace)
                }
            }
        } message: { choice in
            Text(PasteConflictPlanner.message(for: choice.plan))
        }
        .onChange(of: vm.pendingDrop?.id) { _ in
            showDropCollision = vm.pendingDrop != nil
        }
        .sheet(item: $propertiesItem) { item in
            FilePropertiesView(app: app, item: item)
        }
        .sheet(isPresented: $showAppSearch, onDismiss: {
            // Navigate only once the sheet has finished leaving; pushing while it is still on screen
            // can be ignored.
            if let hit = pendingSearchHit {
                pendingSearchHit = nil
                openSearchHit(hit)
            }
        }) {
            AppSearchView(app: app) { hit in
                pendingSearchHit = hit
            }
        }
    }

    private var visibleItems: [FileItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return vm.items }
        return vm.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var selectedItems: [FileItem] {
        visibleItems.filter { selected.contains($0.path) }
    }

    /// The folder on screen, as an item, so it can be saved as a favorite.
    private var currentFolderItem: FileItem {
        FileItem(
            name: vm.displayTitle,
            path: vm.currentPath,
            kind: .directory,
            size: 0,
            modified: nil,
            isReadable: true,
            isWritable: true
        )
    }

    /// A search result opens the folder, or the file in the viewer.
    private func openSearchHit(_ hit: SearchHit) {
        if hit.item.isDirectory {
            jumpFolder = hit.item.path
        } else {
            openRequest = OpenRequest(item: hit.item, mode: .auto)
        }
    }

    private var allVisibleSelected: Bool {
        !visibleItems.isEmpty && visibleItems.allSatisfy { selected.contains($0.path) }
    }

    private var selectionTitle: String {
        let n = selectedItems.count
        if n == 0 { return "Select Items" }
        return n == 1 ? "1 Selected" : "\(n) Selected"
    }

    private var deletePrompt: DeletePrompt {
        DeleteConfirmation.prompt(for: pendingDelete, usesTrash: TrashPreference.isEnabled())
    }

    private var fileList: some View {
        List {
            ForEach(visibleItems) { item in
                if selecting {
                    Button {
                        toggleSelection(item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(item.path) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selected.contains(item.path) ? .accentColor : .secondary)
                                .imageScale(.large)
                            FileRow(item: item)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selected.contains(item.path) ? Color.accentColor.opacity(0.12) : nil)
                } else if item.isDirectory {
                    NavigationLink(destination: FileBrowserView(app: app, initialPath: item.path)) {
                        FileRow(item: item)
                    }
                    .contentShape(Rectangle())
                    .listRowBackground(dropTarget == item.path ? Color.accentColor.opacity(0.18) : nil)
                    .onDrop(
                        of: [UTType.item],
                        isTargeted: Binding(
                            get: { dropTarget == item.path },
                            set: { dropTarget = $0 ? item.path : (dropTarget == item.path ? nil : dropTarget) }
                        )
                    ) { providers in
                        vm.importDropped(providers, into: item.path)
                        return true
                    }
                    .contextMenu { itemMenu(for: item) }
                } else if FileContentKind.classify(name: item.name, isDirectory: false) == .archive {
                    Button {
                        vm.unzip(item: item)
                    } label: {
                        FileRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .contextMenu { itemMenu(for: item) }
                } else {
                    NavigationLink(destination: FileViewerView(app: app, item: item, mode: .auto)) {
                        FileRow(item: item)
                    }
                    .contentShape(Rectangle())
                    .contextMenu { itemMenu(for: item) }
                }
            }
            .onDelete(perform: deleteAtOffsets)
        }
        .environment(\.editMode, .constant(.inactive))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 3)
                .padding(4)
                .opacity(dropTarget == vm.currentPath ? 1 : 0)
                .allowsHitTesting(false)
        )
        .onDrop(
            of: [UTType.item],
            isTargeted: Binding(
                get: { dropTarget == vm.currentPath },
                set: { dropTarget = $0 ? vm.currentPath : (dropTarget == vm.currentPath ? nil : dropTarget) }
            )
        ) { providers in
            vm.importDropped(providers)
            return true
        }
        .refreshable {
            vm.open(vm.currentPath)
        }
        .onChange(of: vm.items.map(\.path)) { paths in
            selected.formIntersection(Set(paths))
        }
    }

    private func deleteAtOffsets(_ offsets: IndexSet) {
        guard !selecting else { return }
        let snapshot = visibleItems
        requestDelete(offsets.compactMap { $0 < snapshot.count ? snapshot[$0] : nil })
    }

    /// Folders always confirm. Files confirm too, unless the person chose "Don’t Ask Again"
    /// (Settings turns it back on).
    private func requestDelete(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        if DeleteConfirmation.needsPrompt(for: items, confirmFileDeletes: confirmFileDeletes) {
            pendingDelete = items
            return
        }
        vm.delete(items: items)
        selected.subtract(items.map(\.path))
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                selectionAction("Copy", "doc.on.doc", enabled: !selectedItems.isEmpty) {
                    FileClipboard.shared.copy(selectedItems, containerPath: app.containerPath)
                }
                selectionAction("Cut", "scissors", enabled: !selectedItems.isEmpty) {
                    FileClipboard.shared.cut(selectedItems, containerPath: app.containerPath)
                }
                selectionAction("Paste", "doc.on.clipboard", enabled: !clipboard.isEmpty && !vm.isBusy) {
                    vm.paste()
                }
                Menu {
                    Button {
                        vm.zip(items: selectedItems)
                    } label: {
                        Label(selectedItems.count == 1 ? "Compress" : "Compress to Zip", systemImage: "doc.zipper")
                    }
                    .disabled(selectedItems.isEmpty)
                    Button {
                        vm.share(items: selectedItems)
                    } label: {
                        Label(
                            selectedItems.count == 1 && selectedItems.first?.isDirectory == false
                                ? "Share / Save to Files"
                                : "Share / Save to Files (folders as zips)",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(selectedItems.isEmpty)
                    Button {
                        vm.backUp(items: selectedItems)
                    } label: {
                        Label("Back Up Selection", systemImage: "externaldrive.badge.plus")
                    }
                    .disabled(selectedItems.isEmpty)
                    Button {
                        vm.duplicate(items: selectedItems)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .disabled(selectedItems.isEmpty)
                    Button {
                        FileClipboard.copyText(
                            selectedItems.map(\.path).joined(separator: "\n"),
                            confirmation: selectedItems.count == 1 ? "Copied Path" : "Copied Paths"
                        )
                    } label: {
                        Label(selectedItems.count == 1 ? "Copy Path" : "Copy Paths", systemImage: "list.clipboard")
                    }
                    .disabled(selectedItems.isEmpty)
                    if selectedItems.count == 1, let item = selectedItems.first {
                        Button {
                            renameName = item.name
                            renameItem = item
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            propertiesItem = item
                        } label: {
                            Label("Properties", systemImage: "info.circle")
                        }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                        Text("More")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .disabled(selectedItems.isEmpty)
                selectionAction("Delete", "trash", enabled: !selectedItems.isEmpty, destructive: true) {
                    requestDelete(selectedItems)
                }
            }
            .padding(.horizontal, 4)
        }
        .background(.bar)
    }

    private func selectionAction(
        _ title: String,
        _ systemImage: String,
        enabled: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundColor(destructive && enabled ? .red : nil)
        }
        .disabled(!enabled)
    }

    private func enterSelection(preselect item: FileItem? = nil) {
        selecting = true
        selected = Set(item.map { [$0.path] } ?? [])
    }

    private func exitSelection() {
        selecting = false
        selected.removeAll()
    }

    private func toggleSelection(_ item: FileItem) {
        if selected.contains(item.path) {
            selected.remove(item.path)
        } else {
            selected.insert(item.path)
        }
    }

    @ViewBuilder
    private func itemMenu(for item: FileItem) -> some View {
        Group {
            if !item.isDirectory {
                if FileContentKind.classify(name: item.name, isDirectory: false) == .archive {
                    Button {
                        vm.unzip(item: item)
                    } label: {
                        Label("Extract", systemImage: "archivebox")
                    }
                    Button {
                        openRequest = OpenRequest(item: item, mode: .hex)
                    } label: {
                        Label("Open as Hex", systemImage: "number")
                    }
                } else {
                    Button {
                        openRequest = OpenRequest(item: item, mode: .auto)
                    } label: {
                        Label("Open", systemImage: "eye")
                    }
                    if FileContentKind.opensAsDatabase(name: item.name) {
                        Button {
                            openRequest = OpenRequest(item: item, mode: .database)
                        } label: {
                            Label("Open as Database", systemImage: "cylinder.split.1x2")
                        }
                    }
                    Button {
                        openRequest = OpenRequest(item: item, mode: .preview)
                    } label: {
                        Label("Preview", systemImage: "doc.viewfinder")
                    }
                    Button {
                        openRequest = OpenRequest(item: item, mode: .text)
                    } label: {
                        Label("Open as Text", systemImage: "doc.plaintext")
                    }
                    Button {
                        openRequest = OpenRequest(item: item, mode: .hex)
                    } label: {
                        Label("Open as Hex", systemImage: "number")
                    }
                }
            }
            Button {
                vm.share(items: [item])
            } label: {
                Label(
                    item.isDirectory ? "Share Zip" : "Share / Save to Files",
                    systemImage: "square.and.arrow.up"
                )
            }
            Button {
                vm.zip(items: [item])
            } label: {
                Label("Compress", systemImage: "doc.zipper")
            }
            Button {
                vm.backUp(items: [item])
            } label: {
                Label("Back Up", systemImage: "externaldrive.badge.plus")
            }
        }
        Group {
            Button {
                enterSelection(preselect: item)
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            Button {
                FileClipboard.shared.copy([item], containerPath: app.containerPath)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                FileClipboard.shared.cut([item], containerPath: app.containerPath)
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            Button {
                FileClipboard.copyText(item.path, confirmation: "Copied Path")
            } label: {
                Label("Copy Path", systemImage: "list.clipboard")
            }
            Button {
                vm.duplicate(item: item)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                propertiesItem = item
            } label: {
                Label("Properties", systemImage: "info.circle")
            }
            Button {
                renameName = item.name
                renameItem = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                favorites.toggle(app: app, item: item)
            } label: {
                if favorites.isFavorite(app: app, path: item.path) {
                    Label("Remove from Favorites", systemImage: "star.slash")
                } else {
                    Label("Add to Favorites", systemImage: "star")
                }
            }
            Button(role: .destructive) {
                requestDelete([item])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

enum CreateKind {
    case file
    case folder
}

private struct OpenRequest: Identifiable {
    let id = UUID()
    let item: FileItem
    let mode: FileOpenMode
}

struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbolName)
                .foregroundColor(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body)
                HStack(spacing: 8) {
                    if !item.isDirectory {
                        Text(formatBytes(item.size))
                    }
                    if let modified = item.modified {
                        Text(Self.stamp.string(from: modified))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var kind: FileContentKind {
        FileContentKind.classify(name: item.name, isDirectory: item.isDirectory)
    }

    private var iconColor: Color {
        switch kind {
        case .directory: return .accentColor
        case .image: return .green
        case .pdf: return .red
        case .audio, .video: return .purple
        case .text, .json, .xml, .plist: return .orange
        default: return .secondary
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
