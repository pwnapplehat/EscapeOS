import SwiftUI

struct ReclaimAppRank: Identifiable {
    var id: String { app.bundleIdentifier }
    let app: InstalledApp
    let safeBytes: Int64
    let safeFiles: Int
    let failed: Bool

    var subtitle: String {
        if failed { return "Could not open container" }
        if safeBytes == 0 { return "Nothing safe to reclaim" }
        return "\(ReclaimService.formatBytes(safeBytes)) safe"
    }
}

/// Ranked reclaim across installed apps. Batch only uses Safe buckets.
struct ReclaimTabView: View {
    @ObservedObject var appList: AppListViewModel
    @StateObject private var vm = ReclaimTabViewModel()
    @State private var selecting = false

    var body: some View {
        Group {
            if appList.needsPairing {
                Text("Import a pairing file on the Apps tab first.")
                    .foregroundColor(.secondary)
                    .padding()
            } else if appList.apps.isEmpty && !appList.isLoading {
                Text("No apps to scan.")
                    .foregroundColor(.secondary)
                    .padding()
            } else if vm.rows.isEmpty && !vm.isScanning {
                scanPrompt
            } else {
                rankedList
            }
        }
        .navigationTitle("Reclaim")
        .onAppear {
            vm.refreshRanksFromCache()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if selecting {
                    Button("Cancel") {
                        selecting = false
                        vm.selected.removeAll()
                    }
                    .disabled(vm.isScanning || vm.isBusy)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Button(selecting ? "Select All" : "Select") {
                        if selecting {
                            vm.selected = Set(vm.rows.filter { !$0.failed && $0.safeBytes > 0 }.map(\.id))
                        } else {
                            selecting = true
                        }
                    }
                    .disabled(vm.isScanning || vm.isBusy || vm.rows.isEmpty)
                    Button {
                        selecting = false
                        vm.scan(apps: appList.apps)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isScanning || vm.isBusy || vm.rows.isEmpty || appList.apps.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                batchBar
            }
        }
        .overlay {
            if vm.isScanning || vm.isBusy {
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
            }
        }
        .alert("Reclaim Safe space?", isPresented: $vm.confirmBatch) {
            Button("Cancel", role: .cancel) {}
            Button("Reclaim", role: .destructive) {
                vm.runBatch(apps: appList.apps)
            }
        } message: {
            Text(vm.batchMessage)
        }
        .alert(item: $vm.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var scanPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Measure cache and temp files in each app. Nothing is deleted until you reclaim.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                selecting = false
                vm.scan(apps: appList.apps)
            } label: {
                Text("Scan Now")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appList.apps.isEmpty || vm.isScanning)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rankedList: some View {
        List {
            if !vm.progressText.isEmpty && vm.isScanning {
                Text(vm.progressText)
                    .foregroundColor(.secondary)
            }
            ForEach(vm.rows) { row in
                if selecting {
                    Button {
                        if vm.selected.contains(row.id) {
                            vm.selected.remove(row.id)
                        } else if !row.failed && row.safeBytes > 0 {
                            vm.selected.insert(row.id)
                        }
                    } label: {
                        rankRow(row, selected: vm.selected.contains(row.id))
                    }
                    .disabled(row.failed || row.safeBytes == 0)
                } else {
                    NavigationLink(destination: ReclaimAppView(app: row.app, viewModel: appList)) {
                        rankRow(row, selected: false)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func rankRow(_ row: ReclaimAppRank, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
            }
            AppIconView(icon: appList.icons[row.app.bundleIdentifier], size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.app.name)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var batchBar: some View {
        let bytes = vm.selectedSafeBytes
        return HStack {
            Text("\(vm.selected.count) selected · \(ReclaimService.formatBytes(bytes))")
                .font(.subheadline)
            Spacer()
            Button("Reclaim Safe") {
                vm.confirmBatch = true
            }
            .disabled(vm.selected.isEmpty || bytes == 0)
        }
        .padding()
        .background(.bar)
    }
}

final class ReclaimTabViewModel: ObservableObject {
    @Published var rows: [ReclaimAppRank] = []
    @Published var selected: Set<String> = []
    @Published var isScanning = false
    @Published var isBusy = false
    @Published var busyTitle = "Scanning…"
    @Published var progressText = ""
    @Published var confirmBatch = false
    @Published var alert: ReclaimNotice?

    private let service = ReclaimService()
    private var scanToken = 0

    var selectedSafeBytes: Int64 {
        rows.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.safeBytes }
    }

    var batchMessage: String {
        let n = selected.count
        let files = rows.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.safeFiles }
        return "Close those apps first. This reclaims Safe caches and temp files only (\(files) files, \(ReclaimService.formatBytes(selectedSafeBytes))) from \(n) app\(n == 1 ? "" : "s"). Session data is not included."
    }

    func refreshRanksFromCache() {
        guard !rows.isEmpty else { return }
        rows = rows.map { row in
            guard let buckets = ReclaimScanCache.shared.buckets(for: row.app.bundleIdentifier) else { return row }
            let safe = buckets.filter { $0.category.risk == .safe }
            return ReclaimAppRank(
                app: row.app,
                safeBytes: safe.reduce(0) { $0 + $1.bytes },
                safeFiles: safe.reduce(0) { $0 + $1.files },
                failed: row.failed
            )
        }.sorted { lhs, rhs in
            if lhs.failed != rhs.failed { return !lhs.failed && rhs.failed }
            if lhs.safeBytes != rhs.safeBytes { return lhs.safeBytes > rhs.safeBytes }
            return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
        }
    }

    func scan(apps: [InstalledApp]) {
        scanToken += 1
        let token = scanToken
        isScanning = true
        busyTitle = "Scanning…"
        progressText = ""
        selected.removeAll()
        DispatchQueue.global(qos: .utility).async {
            let lock = NSLock()
            var ranks: [ReclaimAppRank] = []
            let total = apps.count
            var completedCount = 0
            // Two apps at a time: faster than one-by-one, without opening every
            // container handle at once (too many at once can make the escape fail).
            let gate = DispatchSemaphore(value: 2)
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "escapeos.reclaim.scan", qos: .utility, attributes: .concurrent)
            for app in apps {
                if token != self.scanToken { break }
                gate.wait()
                group.enter()
                queue.async {
                    defer {
                        gate.signal()
                        group.leave()
                    }
                    if token != self.scanToken { return }
                    let rank: ReclaimAppRank
                    if app.containerPath.isEmpty {
                        rank = ReclaimAppRank(app: app, safeBytes: 0, safeFiles: 0, failed: true)
                    } else {
                        do {
                            let buckets = try self.service.scan(app: app, risks: [.safe])
                            ReclaimScanCache.shared.merge(buckets, for: app.bundleIdentifier)
                            let safe = buckets.filter { $0.category.risk == .safe }
                            rank = ReclaimAppRank(
                                app: app,
                                safeBytes: safe.reduce(0) { $0 + $1.bytes },
                                safeFiles: safe.reduce(0) { $0 + $1.files },
                                failed: false
                            )
                        } catch {
                            rank = ReclaimAppRank(app: app, safeBytes: 0, safeFiles: 0, failed: true)
                        }
                    }
                    lock.lock()
                    ranks.append(rank)
                    completedCount += 1
                    let done = completedCount
                    lock.unlock()
                    DispatchQueue.main.async {
                        guard token == self.scanToken else { return }
                        self.busyTitle = "Scanning \(done) / \(total)"
                        self.progressText = "Scanning \(done) / \(total)"
                    }
                }
            }
            group.wait()
            ranks.sort { lhs, rhs in
                if lhs.failed != rhs.failed { return !lhs.failed && rhs.failed }
                if lhs.safeBytes != rhs.safeBytes { return lhs.safeBytes > rhs.safeBytes }
                return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                guard token == self.scanToken else { return }
                self.rows = ranks
                self.isScanning = false
                self.progressText = ""
            }
        }
    }

    func runBatch(apps: [InstalledApp]) {
        let ids = selected
        let targets = rows.filter { ids.contains($0.id) && !$0.failed && $0.safeBytes > 0 }.map(\.app)
        guard !targets.isEmpty else { return }
        isBusy = true
        busyTitle = "Reclaiming…"
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            var files = 0
            var skipped = 0
            var failures = 0
            for (index, app) in targets.enumerated() {
                DispatchQueue.main.async {
                    self.busyTitle = "Reclaiming \(index + 1) / \(targets.count)"
                }
                do {
                    let result = try self.service.reclaim(
                        app: app,
                        categories: ReclaimService.safeCategories
                    )
                    freed += result.bytesFreed
                    files += result.filesRemoved
                    skipped += result.skipped
                } catch {
                    failures += 1
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                var message = "Freed \(ReclaimService.formatBytes(freed)) (\(files) files) from \(targets.count) apps."
                if skipped > 0 {
                    message += " Skipped \(skipped) items that could not be deleted."
                }
                if failures > 0 {
                    message += " \(failures) failed."
                }
                self.alert = ReclaimNotice(title: "Reclaimed", message: message)
                self.scan(apps: apps)
            }
        }
    }
}
