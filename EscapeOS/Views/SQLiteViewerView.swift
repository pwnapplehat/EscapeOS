import SwiftUI

/// Everything about one open database (issue #8): the private copy being edited, and what the
/// screens show of it.
///
/// All access to the database goes through one serial queue. Saving closes and reopens the
/// connection, so it must never overlap a query, and SQLite connections are not for sharing between
/// threads at will.
final class SQLiteViewerModel: ObservableObject {
    enum Phase: Equatable {
        case opening
        case ready
        case failed(String)
        case notDatabase
    }

    @Published var phase: Phase = .opening
    @Published var openFraction: Double?
    @Published var tables: [SQLiteTable] = []
    @Published var rowCounts: [String: Int] = [:]
    @Published var hasUnsavedChanges = false
    @Published var isSaving = false
    /// SQLite's report when its quick check finds something wrong, else nil.
    @Published var healthWarning: String?
    @Published var error: IdentifiedError?
    @Published var sharePayload: SharePayload?
    @Published var resumed = false

    let app: InstalledApp
    let item: FileItem
    private let escape = SandboxEscape()
    private let files = FileService()
    private let operations = OperationCenter.shared
    private let dbQueue = DispatchQueue(label: "escapeos.sqlite", qos: .userInitiated)
    private var copy: SQLiteWorkingCopy?
    private let cancelLock = NSLock()
    private var openCancelled = false

    /// Sessions that still hold unsaved edits, so navigating away and back does not lose them.
    private static var sessions: [String: SQLiteViewerModel] = [:]

    static func session(app: InstalledApp, item: FileItem) -> SQLiteViewerModel {
        let key = app.containerPath + "|" + item.path
        if let existing = sessions[key], existing.hasUnsavedChanges {
            existing.resumed = true
            return existing
        }
        return SQLiteViewerModel(app: app, item: item)
    }

    private var sessionKey: String { app.containerPath + "|" + item.path }

    private init(app: InstalledApp, item: FileItem) {
        self.app = app
        self.item = item
    }

    // MARK: - Opening

    func open() {
        guard copy == nil, phase == .opening else { return }
        let total = max(item.size, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            var copied: Int64 = 0
            let observer = TransferObserver(
                bytes: { count in
                    copied += count
                    let fraction = min(Double(copied) / Double(total), 1)
                    DispatchQueue.main.async { self.openFraction = fraction }
                },
                isCancelled: {
                    self.cancelLock.lock()
                    defer { self.cancelLock.unlock() }
                    return self.openCancelled
                }
            )
            do {
                let opened: SQLiteWorkingCopy = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    guard SQLiteDatabase.looksLikeDatabase(at: self.item.path) else { throw SQLiteError.notADatabase }
                    return try SQLiteWorkingCopy.open(original: self.item.path, files: self.files, observer: observer)
                }
                let summary: (tables: [SQLiteTable], counts: [String: Int], health: String?) = try self.dbQueue.sync {
                    self.copy = opened
                    let tables = try opened.database.tables()
                    var counts: [String: Int] = [:]
                    for table in tables { counts[table.name] = try? opened.database.rowCount(of: table.name) }
                    let check = (try? opened.database.quickCheck()) ?? "ok"
                    return (tables, counts, check == "ok" ? nil : check)
                }
                DispatchQueue.main.async {
                    self.tables = summary.tables
                    self.rowCounts = summary.counts
                    self.healthWarning = summary.health
                    self.hasUnsavedChanges = opened.hasUnsavedChanges
                    self.phase = .ready
                }
            } catch is JobCancelled {
                DispatchQueue.main.async { self.phase = .failed("Opening was cancelled.") }
            } catch SQLiteError.notADatabase {
                DispatchQueue.main.async { self.phase = .notDatabase }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelOpening() {
        cancelLock.lock()
        openCancelled = true
        cancelLock.unlock()
    }

    // MARK: - Reading and editing, on the database's own queue

    func rows(in table: SQLiteTable, offset: Int, limit: Int, completion: @escaping (Result<[SQLiteRow], Error>) -> Void) {
        dbQueue.async {
            guard let database = self.copy?.database else {
                DispatchQueue.main.async { completion(.failure(SQLiteError.cannotOpen("The database is closed."))) }
                return
            }
            let result = Result { try database.rows(in: table, offset: offset, limit: limit) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func fullValue(in table: SQLiteTable, key: SQLiteRowKey, column: String, completion: @escaping (Result<SQLiteValue, Error>) -> Void) {
        dbQueue.async {
            guard let database = self.copy?.database else {
                DispatchQueue.main.async { completion(.failure(SQLiteError.cannotOpen("The database is closed."))) }
                return
            }
            let result = Result { try database.fullValue(in: table, key: key, column: column) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Run an edit and report back. Marks the session as having unsaved changes when it worked.
    private func write(_ body: @escaping (SQLiteDatabase) throws -> Void, completion: @escaping (Error?) -> Void) {
        dbQueue.async {
            guard let copy = self.copy else {
                DispatchQueue.main.async { completion(SQLiteError.cannotOpen("The database is closed.")) }
                return
            }
            var failure: Error?
            do { try body(copy.database) } catch { failure = error }
            let dirty = copy.hasUnsavedChanges
            DispatchQueue.main.async {
                self.hasUnsavedChanges = dirty
                if dirty { Self.sessions[self.sessionKey] = self }
                completion(failure)
            }
        }
    }

    func update(table: SQLiteTable, key: SQLiteRowKey, column: String, value: SQLiteValue, completion: @escaping (Error?) -> Void) {
        write({ try $0.update(table: table, key: key, column: column, to: value) }, completion: completion)
    }

    func insert(table: SQLiteTable, values: [String: SQLiteValue], completion: @escaping (Error?) -> Void) {
        write({ try $0.insert(table: table, values: values) }, completion: { error in
            if error == nil { self.refreshCount(of: table) }
            completion(error)
        })
    }

    func delete(table: SQLiteTable, key: SQLiteRowKey, completion: @escaping (Error?) -> Void) {
        write({ try $0.delete(table: table, key: key) }, completion: { error in
            if error == nil { self.refreshCount(of: table) }
            completion(error)
        })
    }

    func refreshCount(of table: SQLiteTable) {
        dbQueue.async {
            guard let database = self.copy?.database, let count = try? database.rowCount(of: table.name) else { return }
            DispatchQueue.main.async { self.rowCounts[table.name] = count }
        }
    }

    // MARK: - Saving and sharing

    /// Replace the original with the edited copy. The original is kept in the Trash first.
    func save() {
        guard let copy, !isSaving else { return }
        guard let relative = TrashStore.relativePath(of: item.path, in: app.containerPath) else {
            error = IdentifiedError(message: "This file is not inside the app's data, so it cannot be saved back.")
            return
        }
        isSaving = true
        let source = TrashSource(bundleIdentifier: app.bundleIdentifier, appName: app.name, containerPath: app.containerPath)
        let name = item.name
        let container = app.containerPath
        operations.submit("Saving “\(name)”", kind: .heavy, scope: container, work: { context in
            try self.dbQueue.sync {
                try self.escape.withHandle(for: container) { _ in
                    try copy.saveToOriginal { snapshot in
                        try TrashStore.standard().keepCopy(
                            of: snapshot,
                            name: name,
                            restoringTo: relative,
                            from: source,
                            reason: "The original, kept before an edit to “\(name)” was saved over it",
                            observer: TransferObserver(job: context)
                        )
                    }
                }
            }
            return "Saved “\(name)”. The original is in the Trash."
        }, finish: { result in
            self.isSaving = false
            if case .failed(let failure) = result {
                self.error = IdentifiedError(message: failure.localizedDescription)
            }
            self.dbQueue.async {
                let dirty = copy.hasUnsavedChanges
                DispatchQueue.main.async {
                    self.hasUnsavedChanges = dirty
                    if !dirty { Self.sessions[self.sessionKey] = nil }
                }
            }
        })
    }

    /// Offer the edited database as a file, without touching the app's copy.
    func shareCopy() {
        guard let copy else { return }
        let name = item.name
        let box = Box<[URL]>()
        operations.submit("Preparing “\(name)”", kind: .heavy, scope: nil, work: { context in
            try self.dbQueue.sync {
                ShareStaging.sweepLeftovers()
                let path = try copy.shareablePath()
                let shareItem = FileItem(
                    name: name, path: path, kind: .regular,
                    size: self.item.size, modified: nil, isReadable: true, isWritable: false
                )
                box.value = try ShareStaging.stage(
                    entries: ShareStaging.plan(items: [shareItem]),
                    files: self.files,
                    observer: TransferObserver(job: context)
                )
            }
            return nil
        }, finish: { result in
            switch result {
            case .done:
                if let urls = box.value, !urls.isEmpty { self.sharePayload = SharePayload(urls: urls) }
            case .failed(let failure):
                self.error = IdentifiedError(message: failure.localizedDescription)
            case .cancelled:
                break
            }
        })
    }

    // MARK: - Leaving

    /// Close the copy. If there are unsaved edits the session is kept, so opening the file again
    /// resumes them; `discardEdits` throws them away.
    func close() {
        guard !isSaving else { return }
        if hasUnsavedChanges {
            Self.sessions[sessionKey] = self
            return
        }
        discard()
    }

    func discardEdits() {
        Self.sessions[sessionKey] = nil
        discard()
    }

    private func discard() {
        cancelOpening()
        dbQueue.sync {
            copy?.discard()
            copy = nil
        }
    }
}

// MARK: - Screens

/// A SQLite database: its tables, and whether there are edits waiting to be saved.
struct SQLiteViewerView: View {
    let app: InstalledApp
    let item: FileItem

    @StateObject private var model: SQLiteViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClose = false

    init(app: InstalledApp, item: FileItem) {
        self.app = app
        self.item = item
        _model = StateObject(wrappedValue: SQLiteViewerModel.session(app: app, item: item))
    }

    var body: some View {
        content
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        if model.hasUnsavedChanges { confirmClose = true } else { closeNow() }
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if model.phase == .ready {
                        Menu {
                            Button {
                                model.shareCopy()
                            } label: {
                                Label("Share a Copy", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        Button("Save") { model.save() }
                            .disabled(!model.hasUnsavedChanges || model.isSaving)
                    }
                }
            }
            .onAppear { model.open() }
            .confirmationDialog(
                "You have unsaved changes",
                isPresented: $confirmClose,
                titleVisibility: .visible
            ) {
                Button("Keep Editing Later") { closeNow() }
                Button("Discard Changes", role: .destructive) {
                    model.discardEdits()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Keep Editing Later leaves your changes here, and opening the file again picks them up. Nothing reaches the app until you Save.")
            }
            .alert(item: $model.error) { failure in
                Alert(title: Text("Database"), message: Text(failure.message), dismissButton: .default(Text("OK")))
            }
            .sheet(item: $model.sharePayload) { payload in
                ActivityShareView(urls: payload.urls)
            }
    }

    private func closeNow() {
        model.close()
        dismiss()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .opening:
            VStack(spacing: 14) {
                if let fraction = model.openFraction {
                    ProgressView(value: fraction)
                        .padding(.horizontal, 40)
                } else {
                    ProgressView()
                }
                Text("Copying the database to work on…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("Cancel", role: .cancel) {
                    model.cancelOpening()
                }
            }
            .padding()
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        case .notDatabase:
            VStack(spacing: 14) {
                Image(systemName: "questionmark.folder")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("This file is not a SQLite database, or it is damaged.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                NavigationLink(destination: FileViewerView(app: app, item: item, mode: .hex)) {
                    Label("Open as Hex", systemImage: "number")
                }
                .buttonStyle(.bordered)
            }
            .padding()
        case .ready:
            List {
                Section(footer: Text("Close the app that owns this database before saving. The copy you are editing is private: nothing reaches the app until you tap Save, and then the original is kept in the Trash first.")) {
                    Label(
                        model.resumed
                            ? "Picking up your unsaved edits."
                            : "Working on a copy. The app's file is untouched until you Save.",
                        systemImage: "doc.on.doc"
                    )
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    if let warning = model.healthWarning {
                        Label("SQLite reports a problem with this database: \(warning)", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                }
                Section(header: Text(model.tables.count == 1 ? "1 table" : "\(model.tables.count) tables")) {
                    ForEach(model.tables) { table in
                        NavigationLink(destination: SQLiteTableView(model: model, table: table)) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: table.kind == .view ? "eye" : "tablecells")
                                        .foregroundColor(.accentColor)
                                    Text(table.name).font(.body)
                                }
                                Text(subtitle(for: table))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func subtitle(for table: SQLiteTable) -> String {
        var parts: [String] = []
        if let rows = model.rowCounts[table.name] {
            parts.append(rows == 1 ? "1 row" : "\(rows) rows")
        }
        parts.append(table.columns.count == 1 ? "1 column" : "\(table.columns.count) columns")
        if !table.isEditable { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }
}

/// Rows of one table, a page at a time.
struct SQLiteTableView: View {
    @ObservedObject var model: SQLiteViewerModel
    let table: SQLiteTable

    private static let pageSize = 50
    @State private var rows: [SQLiteRow] = []
    @State private var page = 0
    @State private var isLoading = true
    @State private var message: String?
    @State private var editing: SQLiteRow?
    @State private var adding = false
    @State private var pendingDelete: SQLiteRow?

    private var total: Int { model.rowCounts[table.name] ?? rows.count }
    private var pageCount: Int { max(1, (total + Self.pageSize - 1) / Self.pageSize) }

    var body: some View {
        List {
            if let reason = table.readOnlyReason {
                Section {
                    Label(reason, systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            Section(header: Text(rangeText)) {
                if isLoading && rows.isEmpty {
                    ProgressView()
                } else if rows.isEmpty {
                    Text(message ?? "No rows.")
                        .foregroundColor(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Button {
                        editing = row
                    } label: {
                        RowSummary(table: table, row: row)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if table.isEditable, row.key != nil {
                            Button(role: .destructive) {
                                pendingDelete = row
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if pageCount > 1 {
                Section {
                    HStack {
                        Button("Previous") { move(-1) }
                            .disabled(page == 0)
                        Spacer()
                        Text("Page \(page + 1) of \(pageCount)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Next") { move(1) }
                            .disabled(page + 1 >= pageCount)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle(table.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if table.isEditable {
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a row")
                }
            }
        }
        .onAppear { load() }
        .sheet(item: Binding(
            get: { editing.map { RowSelection(row: $0) } },
            set: { if $0 == nil { editing = nil } }
        )) { selection in
            SQLiteRowEditor(model: model, table: table, row: selection.row) { reload() }
        }
        .sheet(isPresented: $adding) {
            SQLiteNewRowView(model: model, table: table) { reload() }
        }
        .alert("Delete this row?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let key = pendingDelete?.key {
                    model.delete(table: table, key: key) { error in
                        if let error { message = error.localizedDescription }
                        reload()
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("The row is removed from your copy. Nothing changes in the app until you Save, and the original is kept in the Trash when you do.")
        }
    }

    private var rangeText: String {
        guard total > 0 else { return "No rows" }
        let first = page * Self.pageSize + 1
        let last = min(first + Self.pageSize - 1, total)
        return "Rows \(first)–\(last) of \(total)"
    }

    private func move(_ delta: Int) {
        page = min(max(page + delta, 0), pageCount - 1)
        load()
    }

    private func reload() {
        model.refreshCount(of: table)
        load()
    }

    private func load() {
        isLoading = true
        model.rows(in: table, offset: page * Self.pageSize, limit: Self.pageSize) { result in
            isLoading = false
            switch result {
            case .success(let found):
                rows = found
                message = nil
            case .failure(let error):
                rows = []
                message = error.localizedDescription
            }
        }
    }
}

private struct RowSelection: Identifiable {
    let id = UUID()
    let row: SQLiteRow
}

private func display(_ cell: SQLiteCell) -> String {
    switch cell.value {
    case .null: return "NULL"
    case .integer(let number): return String(number)
    case .real(let number): return String(number)
    case .text(let text):
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return cell.isPreview ? flat + "…" : flat
    case .blob:
        return "BLOB · \(ProgressFormat.bytes(Int64(cell.byteCount ?? 0)))"
    }
}

private struct RowSummary: View {
    let table: SQLiteTable
    let row: SQLiteRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(zip(table.columns, row.cells).prefix(5)), id: \.0.name) { column, cell in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(column.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(display(cell))
                        .font(.footnote)
                        .foregroundColor(cell.value == .null ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if table.columns.count > 5 {
                Text("and \(table.columns.count - 5) more columns")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// One row: every column, each editable.
struct SQLiteRowEditor: View {
    @ObservedObject var model: SQLiteViewerModel
    let table: SQLiteTable
    let row: SQLiteRow
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editing: FieldEdit?
    @State private var error: IdentifiedError?

    var body: some View {
        NavigationView {
            List {
                if !table.isEditable || row.key == nil {
                    Section {
                        Label(table.readOnlyReason ?? "This row cannot be edited.", systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Section {
                    ForEach(Array(zip(table.columns, row.cells).enumerated()), id: \.offset) { _, pair in
                        let column = pair.0
                        let cell = pair.1
                        Button {
                            begin(column: column, cell: cell)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(column.name).font(.caption).foregroundColor(.secondary)
                                    if column.isPrimaryKey {
                                        Image(systemName: "key.fill").font(.caption2).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(cell.value.kindName).font(.caption2).foregroundColor(.secondary)
                                }
                                Text(display(cell))
                                    .font(.body)
                                    .foregroundColor(cell.value == .null ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(6)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!table.isEditable || row.key == nil || isBlob(cell))
                    }
                }
            }
            .navigationTitle("Row")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { edit in
                SQLiteFieldEditor(edit: edit) { value in
                    guard let key = row.key else { return }
                    model.update(table: table, key: key, column: edit.column.name, value: value) { failure in
                        if let failure {
                            error = IdentifiedError(message: failure.localizedDescription)
                        } else {
                            onChange()
                            dismiss()
                        }
                    }
                }
            }
            .alert(item: $error) { failure in
                Alert(title: Text("Could not save the change"), message: Text(failure.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func isBlob(_ cell: SQLiteCell) -> Bool {
        if case .blob = cell.value { return true }
        return false
    }

    /// Open the editor. A long value is fetched in full first, so editing never saves a cut-short copy.
    private func begin(column: SQLiteColumn, cell: SQLiteCell) {
        guard let key = row.key else { return }
        if cell.isPreview {
            model.fullValue(in: table, key: key, column: column.name) { result in
                switch result {
                case .success(let value): editing = FieldEdit(column: column, original: value)
                case .failure(let failure): error = IdentifiedError(message: failure.localizedDescription)
                }
            }
        } else {
            editing = FieldEdit(column: column, original: cell.value)
        }
    }
}

struct FieldEdit: Identifiable {
    let id = UUID()
    let column: SQLiteColumn
    let original: SQLiteValue
}

/// Edit one value: its text, and what kind of value it should be stored as.
private struct SQLiteFieldEditor: View {
    let edit: FieldEdit
    let onSave: (SQLiteValue) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind: SQLiteInputKind = .text
    @State private var problem: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(edit.column.name), footer: Text(footer)) {
                    Picker("Store as", selection: $kind) {
                        Text("Text").tag(SQLiteInputKind.text)
                        Text("Integer").tag(SQLiteInputKind.integer)
                        Text("Real").tag(SQLiteInputKind.real)
                        Text("NULL").tag(SQLiteInputKind.null)
                    }
                    .pickerStyle(.segmented)
                    if kind != .null {
                        TextEditor(text: $text)
                            .frame(minHeight: 120)
                            .font(.body)
                            .disableAutocorrection(true)
                            .autocapitalization(.none)
                    }
                    if let problem {
                        Text(problem).font(.footnote).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Edit Value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { commit() }
                }
            }
            .onAppear { prepare() }
        }
    }

    private var footer: String {
        if edit.column.declaredType.isEmpty { return "This column has no declared type." }
        return "Declared type: \(edit.column.declaredType)\(edit.column.isNotNull ? " · cannot be NULL" : "")"
    }

    private func prepare() {
        switch edit.original {
        case .null: kind = .null; text = ""
        case .integer(let number): kind = .integer; text = String(number)
        case .real(let number): kind = .real; text = String(number)
        case .text(let value): kind = .text; text = value
        case .blob: kind = .text; text = ""
        }
    }

    private func commit() {
        do {
            let value = try kind.value(from: text)
            onSave(value)
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A new row: fill in the columns you want; the rest take their defaults.
struct SQLiteNewRowView: View {
    @ObservedObject var model: SQLiteViewerModel
    let table: SQLiteTable
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var texts: [String: String] = [:]
    @State private var error: IdentifiedError?

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("Leave a column empty to use its default (or NULL). Text is stored as typed; whole numbers and decimals are stored as numbers.")) {
                    ForEach(table.columns, id: \.name) { column in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(column.name + (column.declaredType.isEmpty ? "" : " · \(column.declaredType)"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField(
                                column.defaultValue.map { "Default: \($0)" } ?? (column.isNotNull ? "Required" : "NULL"),
                                text: Binding(
                                    get: { texts[column.name] ?? "" },
                                    set: { texts[column.name] = $0 }
                                )
                            )
                            .disableAutocorrection(true)
                            .autocapitalization(.none)
                        }
                    }
                }
            }
            .navigationTitle("New Row")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { add() }
                }
            }
            .alert(item: $error) { failure in
                Alert(title: Text("Could not add the row"), message: Text(failure.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func add() {
        var values: [String: SQLiteValue] = [:]
        for column in table.columns {
            let raw = texts[column.name] ?? ""
            if raw.isEmpty { continue }
            values[column.name] = Self.guess(raw, declaredType: column.declaredType)
        }
        model.insert(table: table, values: values) { failure in
            if let failure {
                error = IdentifiedError(message: failure.localizedDescription)
            } else {
                onAdded()
                dismiss()
            }
        }
    }

    /// Numbers go in as numbers for a column declared as one; everything else is text.
    private static func guess(_ raw: String, declaredType: String) -> SQLiteValue {
        let type = declaredType.uppercased()
        if type.contains("INT"), let number = Int64(raw.trimmingCharacters(in: .whitespaces)) { return .integer(number) }
        if type.contains("REAL") || type.contains("FLOA") || type.contains("DOUB"),
           let number = Double(raw.trimmingCharacters(in: .whitespaces)), number.isFinite { return .real(number) }
        return .text(raw)
    }
}
