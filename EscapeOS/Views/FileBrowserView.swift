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
    @State private var showImporter = false
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var pendingDelete: [FileItem] = []
    @AppStorage(DeleteConfirmation.preferenceKey) private var confirmFileDeletes = true
    @State private var archivePassword = ""
    @State private var showImportCollision = false
    @State private var showPasteCollision = false
    @State private var showAppSearch = false
    @State private var jumpFolder: String?
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
                        .disabled(vm.isPasting)
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
                            .disabled(vm.isPasting)
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
                            showImporter = true
                        } label: {
                            Label("Import from Files", systemImage: "square.and.arrow.down")
                        }
                        .disabled(vm.isBusy || vm.pendingImport != nil)
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
            ActivityShareView(url: payload.url)
        }
        .alert(item: $vm.exportError) { err in
            Alert(title: Text("Could not share file"), message: Text(err.message), dismissButton: .default(Text("OK")))
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
            Button("Delete", role: .destructive) {
                vm.delete(items: pendingDelete)
                selected.subtract(pendingDelete.map(\.path))
                pendingDelete = []
            }
            if deletePrompt.offersDontAskAgain {
                Button("Delete, Don’t Ask Again", role: .destructive) {
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
        .sheet(item: $propertiesItem) { item in
            FilePropertiesView(app: app, item: item)
        }
        .sheet(isPresented: $showAppSearch) {
            AppSearchView(app: app) { hit in
                openSearchHit(hit)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item, .data, .content, .archive, .image, .text, .sourceCode, .propertyList],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                vm.importFiles(from: urls)
            case .failure(let error):
                vm.operationError = IdentifiedError(message: error.localizedDescription)
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
        DeleteConfirmation.prompt(for: pendingDelete)
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
                    .contextMenu { itemMenu(for: item) }
                } else if FileContentKind.classify(name: item.name, isDirectory: false) == .archive {
                    Button {
                        vm.unzip(item: item)
                    } label: {
                        FileRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(vm.isZipping)
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
                selectionAction("Paste", "doc.on.clipboard", enabled: !clipboard.isEmpty && !vm.isPasting) {
                    vm.paste()
                }
                Menu {
                    Button {
                        vm.zip(items: selectedItems)
                    } label: {
                        Label(selectedItems.count == 1 ? "Compress" : "Compress to Zip", systemImage: "doc.zipper")
                    }
                    .disabled(selectedItems.isEmpty || vm.isZipping)
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
                        if !item.isDirectory {
                            Button {
                                vm.export(item: item)
                            } label: {
                                Label("Share / Save to Files", systemImage: "square.and.arrow.up")
                            }
                            .disabled(vm.isExporting || vm.isZipping)
                        } else {
                            Button {
                                vm.export(item: item)
                            } label: {
                                Label("Share Zip", systemImage: "square.and.arrow.up")
                            }
                            .disabled(vm.isExporting || vm.isZipping)
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
                    .disabled(vm.isZipping)
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
                vm.export(item: item)
            } label: {
                Label(
                    item.isDirectory ? "Share Zip" : "Share / Save to Files",
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(vm.isExporting || vm.isZipping)
            Button {
                vm.zip(items: [item])
            } label: {
                Label("Compress", systemImage: "doc.zipper")
            }
            .disabled(vm.isZipping)
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

/// A paste that is waiting for the person to choose Replace, Keep Both or Cancel.
struct PendingPasteChoice: Identifiable {
    let id = UUID()
    let clip: FileClipboard.Payload
    let destDir: String
    let destContainer: String
    let plan: PastePlan
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

/// View model driving the file browser.
final class FileBrowserViewModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var currentPath: String = "/"
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sharePayload: SharePayload?
    @Published var isExporting = false
    @Published var isZipping = false
    @Published var isPasting = false
    @Published var busyTitle = "Working…"
    @Published var exportError: IdentifiedError?
    @Published var operationError: IdentifiedError?
    @Published var unzipPasswordItem: FileItem?
    @Published var unzipPasswordMessage = "This archive is password-protected. Enter the password to extract it."
    @Published var pendingImport: PendingImportPrompt?
    @Published var pendingPaste: PendingPasteChoice?

    var isBusy: Bool { isZipping || isExporting || isPasting }

    let app: InstalledApp
    private let escape = SandboxEscape()
    private let files = FileService()

    init(app: InstalledApp, initialPath: String? = nil) {
        self.app = app
        if let initialPath = initialPath {
            self.currentPath = initialPath
        } else {
            self.currentPath = app.containerPath
        }
    }

    var displayTitle: String {
        let last = (currentPath as NSString).lastPathComponent
        return last.isEmpty ? app.name : last
    }

    var pendingPasteTitle: String {
        guard let choice = pendingPaste else { return "Replace existing file?" }
        return PasteConflictPlanner.title(for: choice.plan)
    }

    var pendingImportTitle: String {
        guard let pending = pendingImport else { return "Replace existing file?" }
        return Self.importCollisionTitle(for: pending)
    }

    static func importCollisionTitle(for pending: PendingImportPrompt) -> String {
        let files = pending.collidingFileNames
        if files.count == 1 && pending.collidingFolderNames.isEmpty {
            return "Replace “\(files[0])”?"
        }
        if !files.isEmpty {
            return files.count == 1 ? "Replace existing file?" : "Replace \(files.count) files?"
        }
        return "Name already used"
    }

    static func importCollisionMessage(for pending: PendingImportPrompt) -> String {
        var parts: [String] = []
        if pending.collidingFileNames.count == 1 {
            parts.append(
                "A file with this name is already in this folder. Replace keeps the same location and name."
            )
        } else if pending.collidingFileNames.count > 1 {
            let listed = quotedList(pending.collidingFileNames)
            parts.append(
                "\(listed) already exist in this folder. Replace keeps each original location and name."
            )
        }
        if pending.collidingFolderNames.count == 1 {
            parts.append(
                "A folder named “\(pending.collidingFolderNames[0])” is already here. EscapeOS will not replace a folder with a file — Keep Both saves the import under a new name."
            )
        } else if pending.collidingFolderNames.count > 1 {
            let listed = quotedList(pending.collidingFolderNames)
            parts.append(
                "Folders named \(listed) are already here. Those imports are saved under new names; a folder is never replaced with a file."
            )
        }
        return parts.joined(separator: " ")
    }

    private static func quotedList(_ names: [String]) -> String {
        let shown = names.prefix(4)
        let quoted = shown.map { "“\($0)”" }.joined(separator: ", ")
        if names.count <= 4 { return quoted }
        return "\(quoted), and \(names.count - 4) more"
    }

    func open(_ path: String) {
        isLoading = true
        errorMessage = nil
        currentPath = path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let listed = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    try self.files.list(directory: path)
                }
                DispatchQueue.main.async {
                    self.items = listed
                    self.isLoading = false
                }
            } catch let e as SandboxEscapeError {
                DispatchQueue.main.async {
                    self.errorMessage = e.localizedDescription
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func create(name: String, kind: CreateKind) {
        guard let safe = FileNameRules.sanitize(name) else {
            operationError = IdentifiedError(message: "Enter a file name without slashes.")
            return
        }
        let dest = (currentPath as NSString).appendingPathComponent(safe)
        mutate {
            if kind == .folder {
                try self.files.createDirectory(at: dest)
            } else {
                try self.files.createEmptyFile(at: dest)
            }
        }
    }

    func rename(item: FileItem, to newName: String) {
        guard let safe = FileNameRules.sanitize(newName) else {
            operationError = IdentifiedError(message: "Enter a file name without slashes.")
            return
        }
        mutate {
            try self.files.renameItem(at: item.path, to: safe)
        }
    }

    func delete(item: FileItem) {
        delete(items: [item])
    }

    func delete(items: [FileItem]) {
        guard !items.isEmpty else { return }
        mutate {
            for item in items {
                try self.files.deleteItem(at: item.path)
            }
        }
    }

    func paste() {
        guard let clip = FileClipboard.shared.payload, !clip.items.isEmpty else { return }
        guard !isPasting, pendingPaste == nil else { return }
        isPasting = true
        busyTitle = "Pasting…"
        let destDir = currentPath
        let destContainer = app.containerPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for item in clip.items where Self.wouldNest(source: item.path, inside: destDir) {
                    throw FileServiceError.operationFailed("Can't paste a folder into itself.")
                }
                // Ask before a pasted name lands on one that exists, the way Import from Files does.
                let plan = try self.escape.withHandle(for: destContainer) { _ in
                    PasteConflictPlanner.plan(
                        items: clip.items,
                        into: destDir,
                        moving: clip.mode == .cut,
                        files: self.files
                    )
                }
                if plan.hasConflicts {
                    DispatchQueue.main.async {
                        self.isPasting = false
                        self.pendingPaste = PendingPasteChoice(
                            clip: clip,
                            destDir: destDir,
                            destContainer: destContainer,
                            plan: plan
                        )
                    }
                    return
                }
                self.runPaste(clip, into: destDir, destContainer: destContainer, policy: .keepBoth)
            } catch {
                DispatchQueue.main.async {
                    self.isPasting = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func cancelPendingPaste() {
        pendingPaste = nil
    }

    func finishPendingPaste(_ choice: PendingPasteChoice, policy: ImportNamePolicy) {
        guard policy != .cancel else {
            pendingPaste = nil
            return
        }
        // Button actions can fire twice; the captured choice is still valid the second time.
        guard !isPasting else { return }
        pendingPaste = nil
        isPasting = true
        busyTitle = "Pasting…"
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPaste(choice.clip, into: choice.destDir, destContainer: choice.destContainer, policy: policy)
        }
    }

    /// Runs on the calling background queue; reports back on the main queue.
    private func runPaste(
        _ clip: FileClipboard.Payload,
        into destDir: String,
        destContainer: String,
        policy: ImportNamePolicy
    ) {
        do {
            try paste(clip, into: destDir, destContainer: destContainer, policy: policy)
            DispatchQueue.main.async {
                self.isPasting = false
                if clip.mode == .cut {
                    FileClipboard.shared.clear()
                }
                self.open(self.currentPath)
            }
        } catch {
            DispatchQueue.main.async {
                self.isPasting = false
                self.operationError = IdentifiedError(message: error.localizedDescription)
            }
        }
    }

    private func paste(
        _ clip: FileClipboard.Payload,
        into destDir: String,
        destContainer: String,
        policy: ImportNamePolicy
    ) throws {
        for item in clip.items {
            if Self.wouldNest(source: item.path, inside: destDir) {
                throw FileServiceError.operationFailed("Can't paste a folder into itself.")
            }
        }
        if clip.containerPath == destContainer {
            try escape.withHandle(for: destContainer) { _ in
                if clip.mode == .copy {
                    try SpaceCheck.require(
                        self.files.totalBytes(of: clip.items),
                        at: destDir,
                        for: "paste these items",
                        files: self.files
                    )
                }
                try self.transferSameContainer(clip, destDir: destDir, policy: policy)
            }
            return
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapeos-clip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var stagedBytes: Int64 = 0
        try escape.withHandle(for: clip.containerPath) { _ in
            stagedBytes = self.files.totalBytes(of: clip.items)
            try SpaceCheck.require(stagedBytes, at: staging.path, for: "paste these items", files: self.files)
            for item in clip.items {
                try self.files.copyItem(
                    at: item.path,
                    to: staging.appendingPathComponent(item.name).path
                )
            }
        }
        try escape.withHandle(for: destContainer) { _ in
            // The staged copy already occupies space, so the landing copy needs the same again.
            try SpaceCheck.require(stagedBytes, at: destDir, for: "paste these items", files: self.files)
            for item in clip.items {
                try self.files.land(
                    source: staging.appendingPathComponent(item.name).path,
                    sourceIsDirectory: item.isDirectory,
                    named: item.name,
                    into: destDir,
                    policy: policy,
                    move: false
                )
            }
        }
        if clip.mode == .cut {
            try escape.withHandle(for: clip.containerPath) { _ in
                for item in clip.items {
                    try self.files.deleteItem(at: item.path)
                }
            }
        }
    }

    private func transferSameContainer(
        _ clip: FileClipboard.Payload,
        destDir: String,
        policy: ImportNamePolicy
    ) throws {
        let destNorm = (destDir as NSString).standardizingPath
        for item in clip.items {
            let parent = ((item.path as NSString).deletingLastPathComponent as NSString).standardizingPath
            if clip.mode == .cut && parent == destNorm {
                continue
            }
            try files.land(
                source: item.path,
                sourceIsDirectory: item.isDirectory,
                named: item.name,
                into: destDir,
                policy: policy,
                move: clip.mode == .cut
            )
        }
    }

    private static func wouldNest(source: String, inside destDir: String) -> Bool {
        let src = (source as NSString).standardizingPath
        let dest = (destDir as NSString).standardizingPath
        return dest == src || dest.hasPrefix(src + "/")
    }

    func duplicate(item: FileItem) {
        duplicate(items: [item])
    }

    func duplicate(items: [FileItem]) {
        guard !items.isEmpty else { return }
        mutate {
            if let first = items.first {
                try SpaceCheck.require(
                    self.files.totalBytes(of: items),
                    at: (first.path as NSString).deletingLastPathComponent,
                    for: "duplicate these items",
                    files: self.files
                )
            }
            for item in items {
                let parent = (item.path as NSString).deletingLastPathComponent
                let ns = item.name as NSString
                let ext = ns.pathExtension
                let base = ns.deletingPathExtension
                let preferred = ext.isEmpty ? "\(item.name) copy" : "\(base) copy.\(ext)"
                let dest = self.files.uniqueDestination(in: parent, preferredName: preferred)
                try self.files.copyItem(at: item.path, to: dest)
            }
        }
    }

    func importFiles(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isBusy, pendingImport == nil else { return }
        isZipping = true
        busyTitle = urls.count == 1 ? "Importing…" : "Importing \(urls.count) items…"
        let destDir = currentPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payloads = try Self.readImportPayloads(from: urls)
                let outcome: PendingImportPrompt? = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    try Self.assertPath(destDir, under: self.app.containerPath)
                    let plan = Self.collisionPlan(for: payloads, in: destDir, files: self.files)
                    if plan.collidingFileNames.isEmpty && plan.collidingFolderNames.isEmpty {
                        try self.writeImportPayloads(payloads, into: destDir, policy: .keepBoth)
                        return nil
                    }
                    return PendingImportPrompt(
                        destDir: destDir,
                        payloads: payloads,
                        collidingFileNames: plan.collidingFileNames,
                        collidingFolderNames: plan.collidingFolderNames
                    )
                }
                DispatchQueue.main.async {
                    self.isZipping = false
                    if let outcome = outcome {
                        self.pendingImport = outcome
                    } else {
                        self.open(self.currentPath)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func cancelPendingImport() {
        pendingImport = nil
    }

    func finishPendingImport(_ pending: PendingImportPrompt, policy: ImportNamePolicy) {
        guard policy != .cancel else {
            pendingImport = nil
            return
        }
        // Button actions can fire twice; the captured prompt is still valid the second time.
        guard !isBusy else { return }
        pendingImport = nil
        isZipping = true
        busyTitle = pending.payloads.count == 1 ? "Importing…" : "Importing \(pending.payloads.count) items…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.escape.withHandle(for: self.app.containerPath) { _ in
                    try Self.assertPath(pending.destDir, under: self.app.containerPath)
                    try self.writeImportPayloads(
                        pending.payloads,
                        into: pending.destDir,
                        policy: policy
                    )
                }
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.open(self.currentPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    private static func readImportPayloads(from urls: [URL]) throws -> [ImportPayload] {
        var payloads: [ImportPayload] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                throw FileServiceError.operationFailed(
                    "“\(url.lastPathComponent)” is a folder. Import from Files picks files, not folders."
                )
            }
            let data = try Data(contentsOf: url)
            payloads.append(ImportPayload(name: url.lastPathComponent, data: data))
        }
        return payloads
    }

    private static func assertPath(_ path: String, under root: String) throws {
        guard PathContainment.isInside(path, root: root) else {
            throw FileServiceError.operationFailed("That folder is outside this app's data.")
        }
    }

    private static func collisionPlan(
        for payloads: [ImportPayload],
        in destDir: String,
        files: FileService
    ) -> (collidingFileNames: [String], collidingFolderNames: [String]) {
        var filesSeen = Set<String>()
        var foldersSeen = Set<String>()
        var collidingFiles: [String] = []
        var collidingFolders: [String] = []
        for payload in payloads {
            let dest = files.preferredDestination(in: destDir, preferredName: payload.name)
            let name = (dest as NSString).lastPathComponent
            switch files.existingKind(at: dest) {
            case .none:
                continue
            case .file:
                if filesSeen.insert(name).inserted {
                    collidingFiles.append(name)
                }
            case .directory:
                if foldersSeen.insert(name).inserted {
                    collidingFolders.append(name)
                }
            }
        }
        return (collidingFiles, collidingFolders)
    }

    private func writeImportPayloads(
        _ payloads: [ImportPayload],
        into destDir: String,
        policy: ImportNamePolicy
    ) throws {
        try SpaceCheck.require(
            payloads.reduce(into: Int64(0)) { $0 += Int64($1.data.count) },
            at: destDir,
            for: payloads.count == 1 ? "import this file" : "import these files",
            files: files
        )
        for payload in payloads {
            let dest: String
            switch policy {
            case .cancel:
                return
            case .keepBoth:
                dest = files.uniqueDestination(in: destDir, preferredName: payload.name)
            case .replace:
                let preferred = files.preferredDestination(in: destDir, preferredName: payload.name)
                switch files.existingKind(at: preferred) {
                case .directory:
                    dest = files.uniqueDestination(in: destDir, preferredName: payload.name)
                case .none, .file:
                    dest = preferred
                }
            }
            try Self.assertPath(dest, under: destDir)
            try files.writeFile(data: payload.data, to: dest)
        }
    }

    func export(item: FileItem) {
        isExporting = true
        busyTitle = "Preparing…"
        exportError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dest = try Self.shareStagingURL(named: Self.shareName(for: item))
                try self.escape.withHandle(for: self.app.containerPath) { _ in
                    try SpaceCheck.require(
                        self.files.totalBytes(of: [item]),
                        at: dest.deletingLastPathComponent().path,
                        for: "prepare this for sharing",
                        files: self.files
                    )
                    if item.isDirectory {
                        let zip = ZipWriter()
                        try zip.begin(at: dest)
                        do {
                            try zip.addItems([item], files: self.files, skipPath: dest.path)
                            try zip.finish()
                        } catch {
                            try? zip.finish()
                            throw error
                        }
                    } else {
                        let data = try self.files.readFile(at: item.path)
                        try data.write(to: dest, options: .atomic)
                    }
                }
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.sharePayload = SharePayload(url: dest)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.exportError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func zip(items: [FileItem]) {
        guard !items.isEmpty, !isZipping else { return }
        isZipping = true
        busyTitle = items.count == 1 ? "Compressing…" : "Compressing \(items.count) items…"
        operationError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destPath: String = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    // Raw size is the worst case (already-compressed data barely shrinks); checking it
                    // up front beats failing after a long wait.
                    try SpaceCheck.require(
                        self.files.totalBytes(of: items),
                        at: self.currentPath,
                        for: items.count == 1 ? "compress this item" : "compress these items",
                        files: self.files
                    )
                    let dest = self.files.uniqueDestination(
                        in: self.currentPath,
                        preferredName: Self.zipName(for: items)
                    )
                    let zip = ZipWriter()
                    try zip.begin(at: URL(fileURLWithPath: dest))
                    do {
                        try zip.addItems(items, files: self.files, skipPath: dest)
                        try zip.finish()
                    } catch {
                        try? zip.finish()
                        try? FileManager.default.removeItem(atPath: dest)
                        throw error
                    }
                    return dest
                }
                DispatchQueue.main.async {
                    self.isZipping = false
                    let name = (destPath as NSString).lastPathComponent
                    CopyFeedback.shared.show("Created “\(name)”")
                    self.open(self.currentPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func clearUnzipPasswordPrompt() {
        unzipPasswordItem = nil
        unzipPasswordMessage = "This archive is password-protected. Enter the password to extract it."
    }

    func unzip(item: FileItem, password: String? = nil) {
        guard !isZipping else { return }
        isZipping = true
        busyTitle = "Extracting…"
        operationError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destName: String = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    let bytes = try self.files.readFile(at: item.path)
                    if ArchiveExtractor.archiveNeedsPassword(bytes, name: item.name),
                       password == nil || password?.isEmpty == true {
                        throw ZipReaderError.passwordRequired
                    }
                    let preferred = ArchiveExtractor.folderName(from: item.name)
                    let dest = self.files.uniqueDestination(
                        in: self.currentPath,
                        preferredName: preferred.isEmpty ? "Archive" : preferred
                    )
                    do {
                        try ArchiveExtractor.extract(
                            data: bytes,
                            originalName: item.name,
                            into: dest,
                            files: self.files,
                            password: password
                        )
                    } catch {
                        try? FileManager.default.removeItem(atPath: dest)
                        throw error
                    }
                    return (dest as NSString).lastPathComponent
                }
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.clearUnzipPasswordPrompt()
                    CopyFeedback.shared.show("Extracted to “\(destName)”")
                    self.open(self.currentPath)
                }
            } catch ZipReaderError.passwordRequired {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.unzipPasswordMessage = "This archive is password-protected. Enter the password to extract it."
                    self.unzipPasswordItem = item
                }
            } catch ZipReaderError.wrongPassword {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.unzipPasswordMessage = "Wrong password. Try again."
                    self.unzipPasswordItem = item
                }
            } catch {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    private static func zipName(for items: [FileItem]) -> String {
        if items.count == 1 {
            let name = items[0].name
            let ns = name as NSString
            if ns.pathExtension.lowercased() == "zip" {
                return "\(ns.deletingPathExtension) archive.zip"
            }
            return "\(name).zip"
        }
        return "Archive.zip"
    }

    private static func shareName(for item: FileItem) -> String {
        if item.isDirectory {
            return "\(item.name).zip"
        }
        return item.name
    }

    /// Stage a share file in EscapeOS Documents under the original name (no `shared_` prefix).
    private static func shareStagingURL(named name: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        let dest = docs.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        return dest
    }

    private func mutate(_ body: @escaping () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.escape.withHandle(for: self.app.containerPath) { _ in
                    try body()
                }
                DispatchQueue.main.async {
                    self.open(self.currentPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct IdentifiedError: Identifiable {
    let id = UUID()
    let message: String
}

/// Bytes picked from Files, still named as the source file.
struct ImportPayload {
    let name: String
    let data: Data
}

/// Import waiting on Replace / Keep Both / Cancel because names already exist.
struct PendingImportPrompt: Identifiable {
    let id = UUID()
    let destDir: String
    let payloads: [ImportPayload]
    let collidingFileNames: [String]
    let collidingFolderNames: [String]
}

struct ActivityShareView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
