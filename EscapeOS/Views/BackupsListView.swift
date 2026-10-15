import SwiftUI

/// Lists backup archives and drives restore confirmation + progress.
struct BackupsListView: View {
    @ObservedObject var appList: AppListViewModel
    @StateObject private var vm = BackupsListViewModel()
    @State private var pendingBackupDelete: [BackupRecord] = []
    @State private var sharePayload: SharePayload?

    var body: some View {
        Group {
            if vm.isLoading && vm.records.isEmpty {
                ProgressView("Loading backups…")
            } else if let error = vm.errorMessage, vm.records.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { vm.reload() }
                        .buttonStyle(.bordered)
                }
                .padding()
            } else if vm.records.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Backups Yet")
                        .font(.headline)
                    Text("Export a backup from any app under Apps → Backup Data. Archives are saved to Files → On My iPhone → EscapeOS → Backups.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            } else {
                List {
                    ForEach(vm.records) { record in
                        BackupRow(
                            record: record,
                            icon: appList.icons[record.metadata.bundleIdentifier],
                            eligibility: vm.eligibility(for: record, apps: appList.apps),
                            onRestore: {
                                vm.beginRestore(record: record, apps: appList.apps)
                            },
                            onShare: {
                                sharePayload = SharePayload(url: record.archiveURL)
                            }
                        )
                    }
                    .onDelete { offsets in
                        // Deleting an archive cannot be undone, so it asks first.
                        pendingBackupDelete = offsets.compactMap { $0 < vm.records.count ? vm.records[$0] : nil }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Backups")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    vm.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
            }
        }
        .onAppear {
            vm.reload()
        }
        .sheet(item: $vm.activeRestore) { session in
            RestoreView(session: session, appList: appList)
        }
        .alert(item: $vm.alertError) { error in
            Alert(title: Text("Could Not Start Restore"), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .alert(backupDeleteTitle, isPresented: Binding(
            get: { !pendingBackupDelete.isEmpty },
            set: { if !$0 { pendingBackupDelete = [] } }
        )) {
            Button("Cancel", role: .cancel) { pendingBackupDelete = [] }
            Button("Delete", role: .destructive) {
                vm.delete(records: pendingBackupDelete)
                pendingBackupDelete = []
            }
        } message: {
            Text("The backup archive is permanently deleted from this device. This can’t be undone. Use Share / Save to Files first if you want to keep a copy.")
        }
        .sheet(item: $sharePayload) { payload in
            ActivityShareView(url: payload.url)
        }
    }

    private var backupDeleteTitle: String {
        if pendingBackupDelete.count == 1, let only = pendingBackupDelete.first {
            return "Delete the backup of “\(only.displayTitle)”?"
        }
        return pendingBackupDelete.isEmpty ? "Delete backup?" : "Delete \(pendingBackupDelete.count) backups?"
    }
}

private struct BackupRow: View {
    let record: BackupRecord
    let icon: UIImage?
    let eligibility: RestoreEligibility
    let onRestore: () -> Void
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AppIconView(icon: icon, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displayTitle)
                        .font(.headline)
                    Text(record.metadata.bundleIdentifier)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(record.displaySubtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let modified = record.modified {
                        Text(BackupPaths.displayStamp.string(from: modified))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            switch eligibility {
            case .ready:
                Button(action: onRestore) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                        Text("Restore to Device")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            case .appNotInstalled(_, let appName):
                Label("\(appName) is not installed", systemImage: "app.badge.checkmark.fill")
                    .font(.footnote)
                    .foregroundColor(.orange)
            case .invalidArchive(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            Button(action: onShare) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share / Save to Files")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.vertical, 6)
    }
}

/// Shared app icon rendering with placeholder while icons load.
struct AppIconView: View {
    let icon: UIImage?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let icon = icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: "app.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(size * 0.22)
    }
}

/// Confirmation + progress sheet for restoring a backup.
struct RestoreView: View {
    let session: RestoreSession
    @ObservedObject var appList: AppListViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = RestoreViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                switch vm.state {
                case .confirm:
                    confirmContent
                case .running(let current, let done, let total):
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("\(done) of \(total) files")
                        Text(current)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Cancel", role: .destructive) {
                            vm.cancel()
                        }
                    }
                    .padding()
                case .done(let result):
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("Restore Complete")
                            .font(.headline)
                        Text("\(result.filesRestored) files restored to \(result.targetApp.name)")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.red)
                        Text("Restore Failed")
                            .font(.headline)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Close") { dismiss() }
                    }
                    .padding()
                case .cancelled:
                    VStack(spacing: 12) {
                        Text("Restore Cancelled")
                            .font(.headline)
                        Button("Close") { dismiss() }
                    }
                    .padding()
                }
                Spacer()
            }
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if case .confirm = vm.state {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .onAppear {
                vm.prepare(session: session)
            }
        }
    }

    @ViewBuilder
    private var confirmContent: some View {
        if case .ready(let app, let metadata, let warnings) = session.eligibility {
            VStack(spacing: 16) {
                AppIconView(icon: appList.icons[app.bundleIdentifier], size: 64)
                    .padding(.top, 24)

                Text("Restore to \(app.name)?")
                    .font(.title3).bold()

                VStack(alignment: .leading, spacing: 8) {
                    detailRow("App", app.name)
                    detailRow("Bundle ID", app.bundleIdentifier)
                    detailRow("Files", "\(metadata.fileCount)")
                    detailRow("Data", formatBytes(metadata.totalBytes))
                    detailRow("Backup", session.record.archiveFileName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                    Text("Existing files in Documents, Library, and tmp will be overwritten. Keychain data is never restored.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                Button {
                    vm.start(session: session)
                } label: {
                    Text("Restore Backup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
            }
        } else {
            Text("This backup cannot be restored.")
                .foregroundColor(.secondary)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.leading)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

struct RestoreSession: Identifiable {
    let id = UUID()
    let record: BackupRecord
    let eligibility: RestoreEligibility
}

struct IdentifiedAlert: Identifiable {
    let id = UUID()
    let message: String
}

final class BackupsListViewModel: ObservableObject {
    @Published var records: [BackupRecord] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var activeRestore: RestoreSession?
    @Published var alertError: IdentifiedAlert?

    private let catalog = BackupCatalog()
    private let restoreService = RestoreService()

    func reload() {
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let found = try self.catalog.loadRecords()
                DispatchQueue.main.async {
                    self.records = found
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

    func eligibility(for record: BackupRecord, apps: [InstalledApp]) -> RestoreEligibility {
        restoreService.eligibility(for: record, installedApps: apps)
    }

    func beginRestore(record: BackupRecord, apps: [InstalledApp]) {
        let eligibility = restoreService.eligibility(for: record, installedApps: apps)
        switch eligibility {
        case .ready:
            activeRestore = RestoreSession(record: record, eligibility: eligibility)
        case .appNotInstalled(_, let appName):
            alertError = IdentifiedAlert(message: "\(appName) is not installed. Install the app before restoring this backup.")
        case .invalidArchive(let message):
            alertError = IdentifiedAlert(message: message)
        }
    }

    func delete(records targets: [BackupRecord]) {
        let ids = Set(targets.map(\.id))
        for record in targets {
            try? catalog.delete(record: record)
        }
        records.removeAll { ids.contains($0.id) }
    }
}

final class RestoreViewModel: ObservableObject {
    enum State {
        case confirm
        case running(current: String, done: Int, total: Int)
        case done(RestoreResult)
        case failed(String)
        case cancelled
    }

    @Published var state: State = .confirm
    private let service = RestoreService()
    private var cancelled = false

    func prepare(session: RestoreSession) {
        cancelled = false
        state = .confirm
    }

    func start(session: RestoreSession) {
        guard case .ready(let app, _, _) = session.eligibility else { return }
        cancelled = false
        state = .running(current: "Starting…", done: 0, total: session.record.metadata.fileCount)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.service.restore(
                    record: session.record,
                    to: app,
                    progress: { done, total, current in
                        DispatchQueue.main.async {
                            self.state = .running(current: current, done: done, total: total)
                        }
                    },
                    isCancelled: { self.cancelled }
                )
                DispatchQueue.main.async {
                    self.state = .done(result)
                }
            } catch let error as BackupError {
                DispatchQueue.main.async {
                    if case .cancelled = error {
                        self.state = .cancelled
                    } else {
                        self.state = .failed(error.localizedDescription)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        cancelled = true
    }
}
