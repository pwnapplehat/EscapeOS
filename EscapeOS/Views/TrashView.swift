import SwiftUI

/// Loads the Trash and runs what is done to it (issue #9).
final class TrashViewModel: ObservableObject {
    @Published var records: [TrashRecord] = []
    @Published var totalBytes: Int64 = 0
    @Published var isLoading = false
    @Published var error: IdentifiedError?
    @Published var sharePayload: SharePayload?

    private let store = TrashStore.standard()
    private let escape = SandboxEscape()
    private let operations = OperationCenter.shared

    func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            // Settle anything an interrupted move left half-done before showing the list.
            self.store.recoverInterrupted()
            let found = self.store.records()
            let total = found.reduce(Int64(0)) { $0 + $1.bytes }
            DispatchQueue.main.async {
                self.records = found
                self.totalBytes = total
                self.isLoading = false
            }
        }
    }

    /// Put an item back where it came from, in the app's current data.
    func restore(_ record: TrashRecord, apps: [InstalledApp]) {
        guard let app = apps.first(where: { $0.bundleIdentifier == record.bundleIdentifier }) else {
            error = IdentifiedError(
                message: "“\(record.appName)” is not installed, or its data is not reachable from here, so “\(record.name)” cannot be put back. You can still keep a copy with Share / Save to Files."
            )
            return
        }
        let container = app.containerPath
        let store = self.store
        let result = Box<RestoredItem>()
        operations.submit("Restoring “\(record.name)”", kind: .heavy, scope: container, work: { context in
            context.meter.setTotals(bytes: record.bytes)
            try self.escape.withHandle(for: container) { _ in
                result.value = try store.restore(record, toContainer: container, observer: TransferObserver(job: context))
            }
            guard let restored = result.value else { return nil }
            if restored.renamed {
                return "Restored as “\((restored.path as NSString).lastPathComponent)”: the name was taken"
            }
            return "Restored “\(record.name)”"
        }, finish: { outcome in
            if case .failed(let failure) = outcome {
                self.error = IdentifiedError(message: failure.localizedDescription)
            }
            self.reload()
        })
    }

    func deletePermanently(_ record: TrashRecord) {
        let store = self.store
        operations.submit("Deleting “\(record.name)”", kind: .heavy, scope: nil, work: { _ in
            try store.deletePermanently(record)
            return nil
        }, finish: { outcome in
            if case .failed(let failure) = outcome {
                self.error = IdentifiedError(message: failure.localizedDescription)
            }
            self.reload()
        })
    }

    func empty() {
        let store = self.store
        operations.submit("Emptying the Trash", kind: .heavy, scope: nil, work: { _ in
            let removed = try store.empty()
            return removed == 0 ? nil : "Trash emptied"
        }, finish: { outcome in
            if case .failed(let failure) = outcome {
                self.error = IdentifiedError(message: failure.localizedDescription)
            }
            self.reload()
        })
    }

    /// Hand the item to the share sheet (a folder as a zip), without taking it out of the Trash.
    func share(_ record: TrashRecord) {
        let payload = store.payloadURL(for: record)
        let item = FileItem(
            name: record.name,
            path: payload.path,
            kind: record.isDirectory ? .directory : .regular,
            size: record.bytes,
            modified: nil,
            isReadable: true,
            isWritable: false
        )
        let box = Box<[URL]>()
        operations.submit("Preparing “\(record.name)”", kind: .heavy, scope: nil, work: { context in
            ShareStaging.sweepLeftovers()
            context.meter.setTotals(bytes: record.bytes)
            box.value = try ShareStaging.stage(
                entries: ShareStaging.plan(items: [item]),
                observer: TransferObserver(job: context)
            )
            return nil
        }, finish: { outcome in
            switch outcome {
            case .done:
                if let urls = box.value, !urls.isEmpty { self.sharePayload = SharePayload(urls: urls) }
            case .failed(let failure):
                self.error = IdentifiedError(message: failure.localizedDescription)
            case .cancelled:
                break
            }
        })
    }
}

/// What is in the Trash, with its size, and what can be done to it.
struct TrashView: View {
    /// The apps installed on this device, to find where each item belongs.
    let apps: [InstalledApp]

    @StateObject private var vm = TrashViewModel()
    @State private var confirmEmpty = false
    @State private var pendingDelete: TrashRecord?

    var body: some View {
        List {
            if vm.records.isEmpty && !vm.isLoading {
                Section {
                    Text("The Trash is empty.")
                        .foregroundColor(.secondary)
                }
            } else {
                Section(header: Text(summary)) {
                    ForEach(vm.records) { record in
                        TrashRow(record: record, restorable: canRestore(record))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = record
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    vm.restore(record, apps: apps)
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    vm.restore(record, apps: apps)
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button {
                                    vm.share(record)
                                } label: {
                                    Label(record.isDirectory ? "Share Zip" : "Share / Save to Files", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    pendingDelete = record
                                } label: {
                                    Label("Delete Permanently", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            Section(footer: Text("Items stay on this device, and take up their space, until you delete them here or empty the Trash. You can also see them in Files, On My iPhone, EscapeOS, Trash. Restoring puts an item back where it was; if that name is taken it comes back as “name 2”, and nothing is ever overwritten.")) {
                EmptyView()
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Empty") { confirmEmpty = true }
                    .disabled(vm.records.isEmpty)
            }
        }
        .onAppear { vm.reload() }
        .refreshable { vm.reload() }
        .alert("Empty the Trash?", isPresented: $confirmEmpty) {
            Button("Cancel", role: .cancel) {}
            Button("Empty Trash", role: .destructive) { vm.empty() }
        } message: {
            Text("Everything in the Trash is deleted for good (\(vm.records.count == 1 ? "1 item" : "\(vm.records.count) items"), \(ProgressFormat.bytes(vm.totalBytes))). This can’t be undone.")
        }
        .alert(item: $pendingDelete) { record in
            Alert(
                title: Text("Delete “\(record.name)” for good?"),
                message: Text("It is removed from the Trash and cannot be restored."),
                primaryButton: .destructive(Text("Delete")) { vm.deletePermanently(record) },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $vm.error) { failure in
            Alert(title: Text("Trash"), message: Text(failure.message), dismissButton: .default(Text("OK")))
        }
        .sheet(item: $vm.sharePayload) { payload in
            ActivityShareView(urls: payload.urls)
        }
    }

    private var summary: String {
        let count = vm.records.count
        return "\(count == 1 ? "1 item" : "\(count) items") · \(ProgressFormat.bytes(vm.totalBytes))"
    }

    private func canRestore(_ record: TrashRecord) -> Bool {
        apps.contains { $0.bundleIdentifier == record.bundleIdentifier }
    }
}

private struct TrashRow: View {
    let record: TrashRecord
    let restorable: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: FileContentKind.classify(name: record.name, isDirectory: record.isDirectory).symbolName)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("From \(record.appName) · \(record.parentRelativePath)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Deleted \(Self.relative.localizedString(for: record.deletedAt, relativeTo: Date())) · \(ProgressFormat.bytes(record.bytes))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if record.reason == TrashStore.interruptedReason {
                    Label("May be incomplete: EscapeOS was closed while this was moving.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if !restorable {
                    Label("\(record.appName) is not installed", systemImage: "app.badge.checkmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

/// The Trash's size, for the Settings row.
final class TrashSummaryModel: ObservableObject {
    @Published var text = ""

    func reload() {
        DispatchQueue.global(qos: .utility).async {
            let records = TrashStore.standard().records()
            let bytes = records.reduce(Int64(0)) { $0 + $1.bytes }
            let summary = records.isEmpty
                ? "Empty"
                : "\(records.count == 1 ? "1 item" : "\(records.count) items") · \(ProgressFormat.bytes(bytes))"
            DispatchQueue.main.async { self.text = summary }
        }
    }
}
