import SwiftUI

/// Per-app actions: browse, backup, restore existing archives, container inventory.
struct AppDetailView: View {
    let app: InstalledApp
    @ObservedObject var viewModel: AppListViewModel

    @StateObject private var access = ContainerAccessModel()
    @StateObject private var backup = BackupViewModel()
    @StateObject private var appBackups = AppBackupsModel()
    @StateObject private var inventory = ContainerInventoryModel()
    @State private var activeRestore: RestoreSession?
    @State private var restoreAlert: IdentifiedAlert?
    @State private var confirmReset = false
    @State private var isResetting = false
    @State private var resetNotice: ReclaimNotice?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppIconView(icon: viewModel.icons[app.bundleIdentifier], size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.headline)
                        Text(app.bundleIdentifier).font(.caption).foregroundColor(.secondary)
                        if let version = app.version {
                            Text("Version \(version)").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .contextMenu {
                    Button {
                        FileClipboard.copyText(app.bundleIdentifier, confirmation: "Copied Bundle ID")
                    } label: {
                        Label("Copy Bundle ID", systemImage: "doc.on.doc")
                    }
                    Button {
                        FileClipboard.copyText(app.name, confirmation: "Copied Name")
                    } label: {
                        Label("Copy Name", systemImage: "character.cursor.ibeam")
                    }
                    if !app.containerPath.isEmpty {
                        Button {
                            FileClipboard.copyText(app.containerPath, confirmation: "Copied Path")
                        } label: {
                            Label("Copy Container Path", systemImage: "folder")
                        }
                    }
                }
            }

            Section {
                Button {
                    FileClipboard.copyText(app.bundleIdentifier, confirmation: "Copied Bundle ID")
                } label: {
                    Label("Copy Bundle ID", systemImage: "doc.on.doc")
                }
            }

            Section(header: Text("Access")) {
                switch access.state {
                case .unknown, .checking:
                    HStack {
                        ProgressView()
                        Text("Checking container access…").foregroundColor(.secondary)
                    }
                case .granted:
                    Label("Container accessible", systemImage: "checkmark.shield.fill")
                        .foregroundColor(.green)
                case .denied(let reason):
                    Label(reason, systemImage: "xmark.shield.fill")
                        .foregroundColor(.red)
                }
            }

            if access.isGranted {
                Section(header: Text("Container")) {
                    if inventory.isLoading && inventory.roots.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Counting files…").foregroundColor(.secondary)
                        }
                    } else if inventory.roots.isEmpty {
                        Text("No Documents, Library, or tmp visible.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(inventory.roots) { root in
                            HStack {
                                Text(root.name)
                                Spacer()
                                Text(root.summary)
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }

            if !app.groups.isEmpty {
                Section(
                    header: Text("App Groups"),
                    footer: Text("These are this app's group folders. Reset App Data does not touch them. A group with no folder path cannot be opened.")
                ) {
                    ForEach(app.groups) { group in
                        if let browsed = app.browsing(group) {
                            NavigationLink(destination: FileBrowserView(app: browsed, rootTitle: group.identifier)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.identifier)
                                        .lineLimit(1)
                                    Text("Browse")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.identifier)
                                    .lineLimit(1)
                                Text("No folder path in the install record.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Section(footer: Text("Saves Documents, Library, and tmp into Files → On My iPhone → EscapeOS → Backups. Keychain is never included. Close \(app.name) first for a consistent snapshot.")) {
                NavigationLink(destination: FileBrowserView(app: app)) {
                    Label("Browse Files", systemImage: "folder.fill")
                }
                .disabled(!access.isGranted)

                NavigationLink(destination: ReclaimAppView(app: app, viewModel: viewModel)) {
                    Label("Reclaim Space", systemImage: "internaldrive")
                }
                .disabled(!access.isGranted)

                Button {
                    backup.start(app: app) {
                        appBackups.reload(bundleIdentifier: app.bundleIdentifier)
                    }
                } label: {
                    Label("Backup Data", systemImage: "externaldrive.fill.badge.plus")
                }
                .disabled(!access.isGranted || backup.isBusy)

                backupStatus
            }

            Section(footer: Text("Wipes Documents, Library, and tmp for this app. Close \(app.name) first. Logins and saves in those folders are gone. Keychain and App Groups are not touched.")) {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Reset App Data", systemImage: "trash.fill")
                        .foregroundColor(.red)
                }
                .disabled(!access.isGranted || isResetting)
            }

            Section(
                header: Text(appBackups.records.isEmpty ? "Backups" : "Backups (\(appBackups.records.count))"),
                footer: Text("Restore writes into this app's current container. Close the app first.")
            ) {
                if appBackups.isLoading && appBackups.records.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading backups…").foregroundColor(.secondary)
                    }
                } else if appBackups.records.isEmpty {
                    Text("No backups for \(app.name) yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appBackups.records) { record in
                        AppBackupRow(record: record) {
                            beginRestore(record)
                        }
                    }
                }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            access.check(app: app)
            viewModel.ensureIcon(for: app.bundleIdentifier)
            appBackups.reload(bundleIdentifier: app.bundleIdentifier)
        }
        .onChange(of: access.isGranted) { granted in
            if granted {
                inventory.load(app: app)
            }
        }
        .sheet(item: $activeRestore) { session in
            RestoreView(session: session, appList: viewModel)
        }
        .alert(item: $restoreAlert) { error in
            Alert(title: Text("Could Not Start Restore"), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .alert("Reset all app data?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset App Data", role: .destructive) {
                resetAppData()
            }
        } message: {
            Text(resetConfirmMessage)
        }
        .alert(item: $resetNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .overlay {
            if isResetting {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.15)
                        Text("Resetting…")
                            .font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var resetConfirmMessage: String {
        var text = "Close \(app.name) first. This empties Documents, Library, and tmp. You will need to sign in and set the app up again. Keychain is not deleted."
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            text += " This is EscapeOS — the pairing file in Documents will be deleted too."
        }
        return text
    }

    private func resetAppData() {
        isResetting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let skipped = try ReclaimService().resetAppData(app: app)
                DispatchQueue.main.async {
                    self.isResetting = false
                    self.inventory.load(app: app)
                    var message = "Documents, Library, and tmp are empty."
                    if skipped > 0 {
                        message = "Cleared what we could. Skipped \(skipped) items that could not be deleted."
                    }
                    self.resetNotice = ReclaimNotice(
                        title: "App Data Reset",
                        message: message
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.isResetting = false
                    self.resetNotice = ReclaimNotice(title: "Reset Failed", message: error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private var backupStatus: some View {
        switch backup.state {
        case .idle:
            EmptyView()
        case .running(let files, let bytes, let current):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView()
                Text("\(files) files · \(formatBytes(bytes))")
                    .font(.subheadline)
                Text(current)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Cancel", role: .destructive) {
                    backup.cancel()
                }
            }
            .padding(.vertical, 4)
        case .done(let result):
            VStack(alignment: .leading, spacing: 4) {
                Label("Backup complete", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("\(result.fileCount) files · \(formatBytes(result.totalBytes))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Saved to EscapeOS → Backups")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Backup failed", systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Try Again") {
                    backup.start(app: app) {
                        appBackups.reload(bundleIdentifier: app.bundleIdentifier)
                    }
                }
            }
        }
    }

    private func beginRestore(_ record: BackupRecord) {
        let eligibility = RestoreService().eligibility(for: record, installedApps: [app])
        switch eligibility {
        case .ready:
            activeRestore = RestoreSession(record: record, eligibility: eligibility)
        case .appNotInstalled(_, let name):
            restoreAlert = IdentifiedAlert(message: "\(name) is not installed.")
        case .invalidArchive(let message):
            restoreAlert = IdentifiedAlert(message: message)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

private struct AppBackupRow: View {
    let record: BackupRecord
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.displaySubtitle)
                .font(.subheadline)
            if let modified = record.modified {
                Text(BackupPaths.displayStamp.string(from: modified))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button(action: onRestore) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                    Text("Restore")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}

final class AppBackupsModel: ObservableObject {
    @Published var records: [BackupRecord] = []
    @Published var isLoading = false

    private let catalog = BackupCatalog()

    func reload(bundleIdentifier: String) {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = (try? self.catalog.loadRecords(forBundleIdentifier: bundleIdentifier)) ?? []
            DispatchQueue.main.async {
                self.records = found
                self.isLoading = false
            }
        }
    }
}

struct ContainerRootStat: Identifiable {
    var id: String { name }
    let name: String
    let files: Int
    let directories: Int
    let bytes: Int64
    let available: Bool

    var summary: String {
        guard available else { return "Not found" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(files) files · \(f.string(fromByteCount: bytes))"
    }
}

final class ContainerInventoryModel: ObservableObject {
    @Published var roots: [ContainerRootStat] = []
    @Published var isLoading = false

    private let escape = SandboxEscape()
    private let files = FileService()

    func load(app: InstalledApp) {
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            var stats: [ContainerRootStat] = []
            do {
                try self.escape.withHandle(for: app.containerPath) { _ in
                    for name in BackupService.backupRoots {
                        let path = (app.containerPath as NSString).appendingPathComponent(name)
                        if !self.files.isDirectory(at: path) {
                            stats.append(ContainerRootStat(name: name, files: 0, directories: 0, bytes: 0, available: false))
                            continue
                        }
                        let counted = try self.files.countTree(at: path)
                        stats.append(ContainerRootStat(
                            name: name,
                            files: counted.files,
                            directories: counted.directories,
                            bytes: counted.bytes,
                            available: true
                        ))
                    }
                }
            } catch {
                stats = []
            }
            DispatchQueue.main.async {
                self.roots = stats
                self.isLoading = false
            }
        }
    }
}

/// Tracks whether we can currently consume a sandbox extension for the app's container.
final class ContainerAccessModel: ObservableObject {
    enum State {
        case unknown
        case checking
        case granted
        case denied(String)
    }

    @Published var state: State = .unknown
    var isGranted: Bool { if case .granted = state { return true } ; return false }

    private let escape = SandboxEscape()
    private let files = FileService()

    func check(app: InstalledApp) {
        state = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.escape.withHandle(for: app.containerPath) { _ in
                    if !self.files.isDirectory(at: app.containerPath) {
                        throw FileServiceError.notDirectory(app.containerPath)
                    }
                }
                DispatchQueue.main.async { self.state = .granted }
            } catch let e as SandboxEscapeError {
                DispatchQueue.main.async { self.state = .denied(e.localizedDescription) }
            } catch {
                DispatchQueue.main.async { self.state = .denied(error.localizedDescription) }
            }
        }
    }
}
