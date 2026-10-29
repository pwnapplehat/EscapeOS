import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A paste that is waiting for the person to choose Replace, Keep Both or Cancel.
struct PendingPasteChoice: Identifiable {
    let id = UUID()
    let clip: FileClipboard.Payload
    let destDir: String
    let destContainer: String
    let plan: PastePlan
}

/// A drop that is waiting for the same choice (issue #10). The dropped items are already copied into
/// a staging folder, which is removed whichever way it ends.
struct PendingDropChoice: Identifiable {
    let id = UUID()
    let staging: URL
    let staged: [StagedImport]
    let destDir: String
    let plan: PastePlan
    let failures: [String]
}

/// View model driving the file browser.
///
/// Everything that changes files runs as a job on `OperationCenter`: one at a time, in order, with
/// progress and a Cancel (issue #11). The screen is never blocked by a long operation; only the short
/// preparation of a picker import or a drop shows a spinner.
final class FileBrowserViewModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var currentPath: String = "/"
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sharePayload: SharePayload?
    /// A short preparation that has to finish before a job can be queued (reading picked files,
    /// receiving a drop, planning a paste).
    @Published var isPreparing = false
    @Published var busyTitle = "Working…"
    @Published var exportError: IdentifiedError?
    @Published var operationError: IdentifiedError?
    @Published var unzipPasswordItem: FileItem?
    @Published var unzipPasswordMessage = "This archive is password-protected. Enter the password to extract it."
    @Published var pendingImport: PendingImportPrompt?
    @Published var pendingPaste: PendingPasteChoice?
    @Published var pendingDrop: PendingDropChoice?

    var isBusy: Bool { isPreparing }

    let app: InstalledApp
    private let escape = SandboxEscape()
    private let files = FileService()
    private let operations = OperationCenter.shared
    private let trash = TrashStore.standard()

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

    var pendingDropTitle: String {
        guard let choice = pendingDrop else { return "Replace existing file?" }
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

    // MARK: - Listing

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

    // MARK: - Running jobs

    /// Queue a job against this app's data. The list is reloaded when it ends, however it ends,
    /// since a cancelled or failed job can still have changed something.
    ///
    /// - Parameter handleFailure: return true to say the failure was dealt with (a password prompt,
    ///   say); otherwise it is shown as an error.
    private func run(
        _ title: String,
        kind: JobKind = .heavy,
        handleFailure: ((Error) -> Bool)? = nil,
        _ work: @escaping (JobContext) throws -> String?
    ) {
        let container = app.containerPath
        operations.submit(title, kind: kind, scope: container, work: { context in
            try self.escape.withHandle(for: container) { _ in try work(context) }
        }, finish: { result in
            if case .failed(let error) = result, handleFailure?(error) != true {
                self.operationError = IdentifiedError(message: error.localizedDescription)
            }
            self.open(self.currentPath)
        })
    }

    private var trashSource: TrashSource {
        TrashSource(bundleIdentifier: app.bundleIdentifier, appName: app.name, containerPath: app.containerPath)
    }

    // MARK: - Create, rename, delete

    func create(name: String, kind: CreateKind) {
        guard let safe = FileNameRules.sanitize(name) else {
            operationError = IdentifiedError(message: "Enter a file name without slashes.")
            return
        }
        let dest = (currentPath as NSString).appendingPathComponent(safe)
        run("Creating “\(safe)”", kind: .quick) { _ in
            if kind == .folder {
                try self.files.createDirectory(at: dest)
            } else {
                try self.files.createEmptyFile(at: dest)
            }
            return nil
        }
    }

    func rename(item: FileItem, to newName: String) {
        guard let safe = FileNameRules.sanitize(newName) else {
            operationError = IdentifiedError(message: "Enter a file name without slashes.")
            return
        }
        run("Renaming “\(item.name)”", kind: .quick) { _ in
            try self.files.renameItem(at: item.path, to: safe)
            return nil
        }
    }

    func delete(item: FileItem) {
        delete(items: [item])
    }

    /// Moves the items to the Trash (issue #9), or removes them for good when the Trash is turned off.
    func delete(items: [FileItem]) {
        guard !items.isEmpty else { return }
        let useTrash = TrashPreference.isEnabled()
        let source = trashSource
        let store = trash
        let title = useTrash
            ? (items.count == 1 ? "Moving “\(items[0].name)” to the Trash" : "Moving \(items.count) items to the Trash")
            : (items.count == 1 ? "Deleting “\(items[0].name)”" : "Deleting \(items.count) items")
        run(title) { context in
            context.meter.setTotals(items: items.count)
            let observer = TransferObserver(job: context)
            for item in items {
                try context.checkCancelled()
                context.meter.setDetail(item.name)
                if useTrash {
                    try store.moveToTrash(
                        path: item.path,
                        name: item.name,
                        isDirectory: item.isDirectory,
                        from: source,
                        reason: "Deleted in EscapeOS",
                        observer: observer
                    )
                } else {
                    try self.files.deleteItem(at: item.path)
                }
                context.meter.completeItem()
            }
            guard useTrash else { return nil }
            return items.count == 1 ? "Moved “\(items[0].name)” to the Trash" : "Moved \(items.count) items to the Trash"
        }
    }

    // MARK: - Paste

    func paste() {
        guard let clip = FileClipboard.shared.payload, !clip.items.isEmpty else { return }
        guard !isPreparing, pendingPaste == nil else { return }
        isPreparing = true
        busyTitle = "Checking…"
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
                DispatchQueue.main.async {
                    self.isPreparing = false
                    if plan.hasConflicts {
                        self.pendingPaste = PendingPasteChoice(
                            clip: clip,
                            destDir: destDir,
                            destContainer: destContainer,
                            plan: plan
                        )
                    } else {
                        self.startPaste(clip, into: destDir, destContainer: destContainer, policy: .keepBoth)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isPreparing = false
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
        guard pendingPaste != nil else { return }
        pendingPaste = nil
        startPaste(choice.clip, into: choice.destDir, destContainer: choice.destContainer, policy: policy)
    }

    private func startPaste(
        _ clip: FileClipboard.Payload,
        into destDir: String,
        destContainer: String,
        policy: ImportNamePolicy
    ) {
        let verb = clip.mode == .cut ? "Moving" : "Copying"
        let title = clip.items.count == 1 ? "\(verb) “\(clip.items[0].name)”" : "\(verb) \(clip.items.count) items"
        operations.submit(title, kind: .heavy, scope: destContainer, work: { context in
            try self.paste(clip, into: destDir, destContainer: destContainer, policy: policy, context: context)
            return nil
        }, finish: { result in
            switch result {
            case .done:
                if clip.mode == .cut { FileClipboard.shared.clear() }
            case .failed(let error):
                self.operationError = IdentifiedError(message: error.localizedDescription)
            case .cancelled:
                break
            }
            self.open(self.currentPath)
        })
    }

    /// Runs on the queue's worker thread.
    private func paste(
        _ clip: FileClipboard.Payload,
        into destDir: String,
        destContainer: String,
        policy: ImportNamePolicy,
        context: JobContext
    ) throws {
        for item in clip.items {
            if Self.wouldNest(source: item.path, inside: destDir) {
                throw FileServiceError.operationFailed("Can't paste a folder into itself.")
            }
        }
        let observer = TransferObserver(job: context)
        if clip.containerPath == destContainer {
            try escape.withHandle(for: destContainer) { _ in
                if clip.mode == .copy {
                    let bytes = self.files.totalBytes(of: clip.items)
                    try SpaceCheck.require(bytes, at: destDir, for: "paste these items", files: self.files)
                    context.meter.setTotals(bytes: bytes)
                } else {
                    // A move is a rename: instant, so count items, not bytes.
                    context.meter.setTotals(items: clip.items.count)
                }
                try self.transferSameContainer(clip, destDir: destDir, policy: policy, context: context, observer: observer)
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
            // The item is read out of one app, then written into the other: twice the bytes.
            context.meter.setTotals(bytes: stagedBytes * 2)
            for item in clip.items {
                try context.checkCancelled()
                try self.files.copyTree(
                    from: item.path,
                    to: staging.appendingPathComponent(item.name).path,
                    observer: observer
                )
            }
        }
        try escape.withHandle(for: destContainer) { _ in
            // The staged copy already occupies space, so the landing copy needs the same again.
            try SpaceCheck.require(stagedBytes, at: destDir, for: "paste these items", files: self.files)
            for item in clip.items {
                try context.checkCancelled()
                try self.files.land(
                    source: staging.appendingPathComponent(item.name).path,
                    sourceIsDirectory: item.isDirectory,
                    named: item.name,
                    into: destDir,
                    policy: policy,
                    move: false,
                    observer: observer
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
        policy: ImportNamePolicy,
        context: JobContext,
        observer: TransferObserver
    ) throws {
        for item in clip.items {
            try context.checkCancelled()
            if clip.mode == .cut {
                // Moving into the folder it is already in does nothing. An item that is gone from
                // its old place was moved by an earlier, interrupted paste: skip it so pasting
                // again carries on with the rest instead of failing on the first one.
                if PasteConflictPlanner.isInSameFolder(item.path, as: destDir) { continue }
                if files.existingKind(at: item.path) == .none { continue }
            }
            context.meter.setDetail(item.name)
            try files.land(
                source: item.path,
                sourceIsDirectory: item.isDirectory,
                named: item.name,
                into: destDir,
                policy: policy,
                move: clip.mode == .cut,
                observer: observer
            )
            context.meter.completeItem()
        }
    }

    private static func wouldNest(source: String, inside destDir: String) -> Bool {
        let src = (source as NSString).standardizingPath
        let dest = (destDir as NSString).standardizingPath
        return dest == src || dest.hasPrefix(src + "/")
    }

    // MARK: - Duplicate

    func duplicate(item: FileItem) {
        duplicate(items: [item])
    }

    func duplicate(items: [FileItem]) {
        guard !items.isEmpty else { return }
        run(items.count == 1 ? "Duplicating “\(items[0].name)”" : "Duplicating \(items.count) items") { context in
            let total = self.files.totalBytes(of: items)
            if let first = items.first {
                try SpaceCheck.require(
                    total,
                    at: (first.path as NSString).deletingLastPathComponent,
                    for: "duplicate these items",
                    files: self.files
                )
            }
            context.meter.setTotals(bytes: total)
            let observer = TransferObserver(job: context)
            for item in items {
                try context.checkCancelled()
                let parent = (item.path as NSString).deletingLastPathComponent
                let ns = item.name as NSString
                let ext = ns.pathExtension
                let base = ns.deletingPathExtension
                let preferred = ext.isEmpty ? "\(item.name) copy" : "\(base) copy.\(ext)"
                let dest = self.files.uniqueDestination(in: parent, preferredName: preferred)
                try self.files.copyTree(from: item.path, to: dest, observer: observer)
            }
            return nil
        }
    }

    // MARK: - Import from Files

    func importFiles(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isPreparing, pendingImport == nil else { return }
        isPreparing = true
        busyTitle = urls.count == 1 ? "Reading…" : "Reading \(urls.count) items…"
        let destDir = currentPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payloads = try Self.readImportPayloads(from: urls)
                let outcome: PendingImportPrompt? = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    try Self.assertPath(destDir, under: self.app.containerPath)
                    let plan = Self.collisionPlan(for: payloads, in: destDir, files: self.files)
                    if plan.collidingFileNames.isEmpty && plan.collidingFolderNames.isEmpty {
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
                    self.isPreparing = false
                    if let outcome = outcome {
                        self.pendingImport = outcome
                    } else {
                        self.startImport(payloads, into: destDir, policy: .keepBoth)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isPreparing = false
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
        guard pendingImport != nil else { return }
        pendingImport = nil
        startImport(pending.payloads, into: pending.destDir, policy: policy)
    }

    private func startImport(_ payloads: [ImportPayload], into destDir: String, policy: ImportNamePolicy) {
        run(payloads.count == 1 ? "Importing “\(payloads[0].name)”" : "Importing \(payloads.count) items") { context in
            try Self.assertPath(destDir, under: self.app.containerPath)
            try self.writeImportPayloads(payloads, into: destDir, policy: policy, context: context)
            return nil
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
                    "“\(url.lastPathComponent)” is a folder. Import from Files picks files, not folders; to bring in a folder, drag it onto a folder here."
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
        policy: ImportNamePolicy,
        context: JobContext
    ) throws {
        let total = payloads.reduce(into: Int64(0)) { $0 += Int64($1.data.count) }
        try SpaceCheck.require(
            total,
            at: destDir,
            for: payloads.count == 1 ? "import this file" : "import these files",
            files: files
        )
        context.meter.setTotals(bytes: total)
        for payload in payloads {
            try context.checkCancelled()
            context.meter.setDetail(payload.name)
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
            context.meter.add(bytes: Int64(payload.data.count))
        }
    }

    // MARK: - Dropped from the Files app (issue #10)

    /// Receive items dropped onto this folder (or onto one of the folders in it).
    ///
    /// Each item is copied into a staging folder as soon as it arrives, because the temporary link a
    /// drop provides does not last. Folders come across whole. Then the same Replace / Keep Both /
    /// Cancel question as Paste, and the same free-space check as every other copy.
    func importDropped(_ providers: [NSItemProvider], into folder: String? = nil) {
        guard !providers.isEmpty, !isPreparing, pendingDrop == nil else { return }
        isPreparing = true
        busyTitle = providers.count == 1 ? "Receiving…" : "Receiving \(providers.count) items…"
        let destDir = folder ?? currentPath
        DispatchQueue.global(qos: .userInitiated).async {
            let staging: URL
            do {
                staging = try ImportStaging.makeFolder()
            } catch {
                DispatchQueue.main.async {
                    self.isPreparing = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
                return
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var slots = [StagedImport?](repeating: nil, count: providers.count)
            var failures: [String] = []
            for (index, provider) in providers.enumerated() {
                group.enter()
                self.receive(provider, into: staging) { result in
                    lock.lock()
                    switch result {
                    case .success(let item): slots[index] = item
                    case .failure(let message): failures.append(message)
                    }
                    lock.unlock()
                    group.leave()
                }
            }
            group.wait()
            let staged = slots.compactMap { $0 }
            guard !staged.isEmpty else {
                ImportStaging.discard(staging)
                DispatchQueue.main.async {
                    self.isPreparing = false
                    self.operationError = IdentifiedError(
                        message: failures.first ?? "Nothing could be received from the drop."
                    )
                }
                return
            }
            do {
                let plan: PastePlan = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    try Self.assertPath(destDir, under: self.app.containerPath)
                    return ImportStaging.plan(staged: staged, into: destDir, files: self.files)
                }
                DispatchQueue.main.async {
                    self.isPreparing = false
                    if plan.hasConflicts {
                        self.pendingDrop = PendingDropChoice(
                            staging: staging, staged: staged, destDir: destDir, plan: plan, failures: failures
                        )
                    } else {
                        self.startDropLanding(staging: staging, staged: staged, into: destDir, policy: .keepBoth, failures: failures)
                    }
                }
            } catch {
                ImportStaging.discard(staging)
                DispatchQueue.main.async {
                    self.isPreparing = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func cancelPendingDrop() {
        if let drop = pendingDrop { ImportStaging.discard(drop.staging) }
        pendingDrop = nil
    }

    func finishPendingDrop(_ choice: PendingDropChoice, policy: ImportNamePolicy) {
        guard policy != .cancel else {
            cancelPendingDrop()
            return
        }
        guard pendingDrop != nil else { return }
        pendingDrop = nil
        startDropLanding(staging: choice.staging, staged: choice.staged, into: choice.destDir, policy: policy, failures: choice.failures)
    }

    private func startDropLanding(
        staging: URL,
        staged: [StagedImport],
        into destDir: String,
        policy: ImportNamePolicy,
        failures: [String]
    ) {
        let container = app.containerPath
        let title = staged.count == 1 ? "Importing “\(staged[0].name)”" : "Importing \(staged.count) items"
        operations.submit(title, kind: .heavy, scope: container, work: { context in
            context.meter.setTotals(items: staged.count)
            var landedCount = 0
            try self.escape.withHandle(for: container) { _ in
                try Self.assertPath(destDir, under: container)
                let landed = try ImportStaging.land(
                    staged, into: destDir, policy: policy, files: self.files,
                    observer: TransferObserver(job: context)
                )
                landedCount = landed.count
            }
            return landedCount == 1 ? "Imported 1 item" : "Imported \(landedCount) items"
        }, finish: { result in
            ImportStaging.discard(staging)
            if case .failed(let error) = result {
                self.operationError = IdentifiedError(message: error.localizedDescription)
            } else if !failures.isEmpty {
                self.operationError = IdentifiedError(message: "Some items could not be received: " + failures.joined(separator: " "))
            }
            self.open(self.currentPath)
        })
    }

    private enum ReceiveResult {
        case success(StagedImport)
        case failure(String)
    }

    /// Copy one dropped item into the staging folder. Runs on a background queue.
    private func receive(_ provider: NSItemProvider, into staging: URL, completion: @escaping (ReceiveResult) -> Void) {
        let label = provider.suggestedName ?? "an item"
        func stage(_ url: URL) {
            do {
                completion(.success(try ImportStaging.stage(source: url, into: staging, files: self.files)))
            } catch {
                completion(.failure("“\(label)”: \(error.localizedDescription)"))
            }
        }
        func viaURL() {
            guard provider.canLoadObject(ofClass: URL.self) else {
                completion(.failure("“\(label)” could not be received."))
                return
            }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else {
                    completion(.failure("“\(label)” could not be received."))
                    return
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                stage(url)
            }
        }
        let kind = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .item) == true }
        guard let kind else {
            viaURL()
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: kind) { url, _ in
            if let url {
                stage(url)
            } else {
                viaURL()
            }
        }
    }

    // MARK: - Share

    /// Stage every item and hand them all to one share sheet (issue #12). A folder is zipped; a file
    /// is copied as it is.
    func share(items: [FileItem]) {
        guard !items.isEmpty else { return }
        exportError = nil
        let box = Box<[URL]>()
        let title = items.count == 1 ? "Preparing “\(items[0].name)”" : "Preparing \(items.count) items"
        operations.submit(title, kind: .heavy, scope: app.containerPath, work: { context in
            try self.escape.withHandle(for: self.app.containerPath) { _ in
                let bytes = self.files.totalBytes(of: items)
                try SpaceCheck.require(
                    bytes,
                    at: FileManager.default.temporaryDirectory.path,
                    for: "prepare this for sharing",
                    files: self.files
                )
                context.meter.setTotals(bytes: bytes)
                box.value = try ShareStaging.stage(
                    entries: ShareStaging.plan(items: items),
                    files: self.files,
                    observer: TransferObserver(job: context)
                )
            }
            return nil
        }, finish: { result in
            switch result {
            case .done:
                if let urls = box.value, !urls.isEmpty { self.sharePayload = SharePayload(urls: urls) }
            case .failed(let error):
                self.exportError = IdentifiedError(message: error.localizedDescription)
            case .cancelled:
                break
            }
        })
    }

    // MARK: - Compress and extract

    func zip(items: [FileItem]) {
        guard !items.isEmpty else { return }
        operationError = nil
        let parent = currentPath
        run(items.count == 1 ? "Compressing “\(items[0].name)”" : "Compressing \(items.count) items") { context in
            // Raw size is the worst case (already-compressed data barely shrinks); checking it
            // up front beats failing after a long wait.
            let bytes = self.files.totalBytes(of: items)
            try SpaceCheck.require(
                bytes,
                at: parent,
                for: items.count == 1 ? "compress this item" : "compress these items",
                files: self.files
            )
            context.meter.setTotals(bytes: bytes)
            let dest = self.files.uniqueDestination(in: parent, preferredName: Self.zipName(for: items))
            let zip = ZipWriter()
            try zip.begin(at: URL(fileURLWithPath: dest))
            do {
                try zip.addItems(items, files: self.files, skipPath: dest, observer: TransferObserver(job: context))
                try zip.finish()
            } catch {
                zip.abandon()
                try? FileManager.default.removeItem(atPath: dest)
                throw error
            }
            return "Created “\((dest as NSString).lastPathComponent)”"
        }
    }

    func clearUnzipPasswordPrompt() {
        unzipPasswordItem = nil
        unzipPasswordMessage = "This archive is password-protected. Enter the password to extract it."
    }

    func unzip(item: FileItem, password: String? = nil) {
        operationError = nil
        let parent = currentPath
        run(
            "Extracting “\(item.name)”",
            handleFailure: { error in
                guard let zipError = error as? ZipReaderError else { return false }
                switch zipError {
                case .passwordRequired:
                    self.unzipPasswordMessage = "This archive is password-protected. Enter the password to extract it."
                    self.unzipPasswordItem = item
                    return true
                case .wrongPassword:
                    self.unzipPasswordMessage = "Wrong password. Try again."
                    self.unzipPasswordItem = item
                    return true
                default:
                    return false
                }
            }
        ) { context in
            let bytes = try self.files.readFile(at: item.path)
            if ArchiveExtractor.archiveNeedsPassword(bytes, name: item.name),
               password == nil || password?.isEmpty == true {
                throw ZipReaderError.passwordRequired
            }
            let preferred = ArchiveExtractor.folderName(from: item.name)
            let dest = self.files.uniqueDestination(
                in: parent,
                preferredName: preferred.isEmpty ? "Archive" : preferred
            )
            do {
                try ArchiveExtractor.extract(
                    data: bytes,
                    originalName: item.name,
                    into: dest,
                    files: self.files,
                    password: password,
                    observer: TransferObserver(job: context)
                )
            } catch {
                try? FileManager.default.removeItem(atPath: dest)
                throw error
            }
            DispatchQueue.main.async { self.clearUnzipPasswordPrompt() }
            return "Extracted to “\((dest as NSString).lastPathComponent)”"
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

    // MARK: - Back up a selection (issue #7)

    func backUp(items: [FileItem]) {
        let selection: BackupSelection
        do {
            selection = try BackupSelection.from(items: items, containerPath: app.containerPath)
        } catch {
            operationError = IdentifiedError(message: error.localizedDescription)
            return
        }
        let target = app
        let count = selection.paths.count
        let title = items.count == 1 ? "Backing up “\(items[0].name)”" : "Backing up \(items.count) items"
        operations.submit(title, kind: .heavy, scope: app.containerPath, work: { context in
            do {
                _ = try BackupService().exportBackup(
                    for: target,
                    selection: selection,
                    estimate: { context.meter.setTotals(bytes: $0) },
                    bytes: { context.meter.add(bytes: $0) },
                    progress: { _, _, current in
                        context.meter.setDetail(current)
                    },
                    isCancelled: { context.isCancelled }
                )
            } catch BackupError.cancelled {
                throw JobCancelled()
            }
            return "Backed up \(count == 1 ? "1 item" : "\(count) items") to Backups"
        }, finish: { result in
            if case .failed(let error) = result {
                self.operationError = IdentifiedError(message: error.localizedDescription)
            }
        })
    }
}

/// A place a job leaves a result for the code that queued it.
final class Box<Value> {
    var value: Value?
}

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
    }

    init(url: URL) {
        self.urls = [url]
    }

    var url: URL? { urls.first }
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
    let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
    }

    init(url: URL) {
        self.urls = [url]
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
