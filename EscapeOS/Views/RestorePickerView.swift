import SwiftUI

/// Choose which files and folders of a backup to restore (issue #7).
///
/// The backup's folders are shown as a tree. Ticking a folder ticks everything in it; a folder that is
/// only partly ticked says so. Nothing is ticked at first, so nothing is restored by accident.
struct RestorePickerView: View {
    let record: BackupRecord
    /// Called with what was chosen, and how many files and bytes that is.
    let onChoose: (BackupSelection, Int, Int64) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RestorePickerModel()

    var body: some View {
        NavigationView {
            Group {
                if model.isLoading {
                    ProgressView("Reading the backup…")
                } else if let message = model.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.red)
                        Text(message)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding()
                } else if let current = model.selection {
                    List(current.tree.roots, children: \.children) { node in
                        PickerRow(node: node, state: current.state(of: node)) {
                            var updated = current
                            updated.toggle(node)
                            model.selection = updated
                        }
                    }
                    .listStyle(.plain)
                    .safeAreaInset(edge: .bottom) {
                        bottomBar(current)
                    }
                }
            }
            .navigationTitle("Choose What to Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let selection = model.selection {
                        Button(selection.isEverything ? "Clear" : "Select All") {
                            var updated = selection
                            if selection.isEverything { updated.clear() } else { updated.selectAll() }
                            model.selection = updated
                        }
                    }
                }
            }
            .onAppear { model.load(record) }
        }
    }

    private func bottomBar(_ selection: ManifestSelection) -> some View {
        VStack(spacing: 8) {
            Divider()
            Text(selection.isEmpty
                 ? "Tick the files and folders to restore."
                 : "\(selection.selectedFileCount == 1 ? "1 file" : "\(selection.selectedFileCount) files") · \(ProgressFormat.bytes(selection.selectedBytes)) selected")
                .font(.footnote)
                .foregroundColor(.secondary)
            Button {
                if let chosen = selection.backupSelection {
                    dismiss()
                    onChoose(chosen, selection.selectedFileCount, selection.selectedBytes)
                }
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selection.isEmpty)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }
}

private struct PickerRow: View {
    let node: ManifestNode
    let state: CheckState
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(state == .none ? .secondary : .accentColor)
                    .imageScale(.large)
                Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                    .foregroundColor(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(node.isDirectory
                         ? "\(node.fileCount == 1 ? "1 file" : "\(node.fileCount) files") · \(ProgressFormat.bytes(node.bytes))"
                         : ProgressFormat.bytes(node.bytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.name)
        .accessibilityValue(state == .all ? "Ticked" : (state == .some ? "Partly ticked" : "Not ticked"))
        .accessibilityAddTraits(.isButton)
    }

    private var icon: String {
        switch state {
        case .all: return "checkmark.circle.fill"
        case .some: return "minus.circle.fill"
        case .none: return "circle"
        }
    }
}

final class RestorePickerModel: ObservableObject {
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var selection: ManifestSelection?

    private let service = RestoreService()

    func load(_ record: BackupRecord) {
        guard selection == nil else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let manifest = try self.service.loadManifest(for: record)
                let tree = ManifestTree(manifest: manifest)
                DispatchQueue.main.async {
                    self.selection = ManifestSelection(tree: tree)
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
}
