import Foundation
import SQLite3

/// Reading and editing a SQLite database (issue #8).
///
/// This is only ever pointed at a private working copy (see `SQLiteWorkingCopy`), never at another
/// app's live database: writing to a database an app has open can corrupt it.

enum SQLiteError: Error, LocalizedError, Equatable {
    case cannotOpen(String)
    case notADatabase
    case sql(String)
    case notEditable(String)
    case rowChanged
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let message): return "Could not open the database: \(message)"
        case .notADatabase: return "This file is not a SQLite database, or it is damaged."
        case .sql(let message): return message
        case .notEditable(let reason): return reason
        case .rowChanged: return "That row has changed or been removed. Reload the table and try again."
        case .invalidValue(let message): return message
        }
    }
}

/// One value in a table.
enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    /// What kind it is, in the words a person would use.
    var kindName: String {
        switch self {
        case .null: return "NULL"
        case .integer: return "integer"
        case .real: return "real"
        case .text: return "text"
        case .blob: return "blob"
        }
    }
}

/// What a person typed, and what kind of value it should become.
enum SQLiteInputKind: String, CaseIterable {
    case text
    case integer
    case real
    case null

    func value(from input: String) throws -> SQLiteValue {
        switch self {
        case .null:
            return .null
        case .text:
            return .text(input)
        case .integer:
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Int64(trimmed) else {
                throw SQLiteError.invalidValue("“\(trimmed)” is not a whole number.")
            }
            return .integer(number)
        case .real:
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Double(trimmed), number.isFinite else {
                throw SQLiteError.invalidValue("“\(trimmed)” is not a number.")
            }
            return .real(number)
        }
    }
}

/// A value as read for display: long text and blobs are cut short so a table of big values stays
/// fast. `fullValue` fetches the real thing for editing.
struct SQLiteCell: Equatable {
    let value: SQLiteValue
    /// Full size in bytes for text and blobs.
    let byteCount: Int?
    /// True when `value` holds only the start of a longer text or blob.
    let isPreview: Bool
}

struct SQLiteColumn: Equatable {
    let name: String
    let declaredType: String
    let isNotNull: Bool
    /// 1-based position within the primary key, or 0 when it is not part of it.
    let primaryKeyPosition: Int
    let defaultValue: String?
    /// Worked out by SQLite from other columns: shown, never written.
    var isGenerated = false

    var isPrimaryKey: Bool { primaryKeyPosition > 0 }
}

/// How a row in a table is found again for editing.
enum SQLiteRowKey: Equatable {
    case rowID(Int64)
    case primaryKey([SQLiteValue])
}

struct SQLiteRow: Equatable {
    /// Nil in a table that has no way to name a row, which is therefore read-only.
    let key: SQLiteRowKey?
    let cells: [SQLiteCell]
}

struct SQLiteTable: Equatable, Identifiable {
    enum Kind: Equatable {
        case table
        case view
        case virtual
    }

    enum KeyKind: Equatable {
        /// Rows are named by SQLite's hidden row id, under this column name.
        case rowID(alias: String)
        case primaryKey
        case none
    }

    let name: String
    let kind: Kind
    let columns: [SQLiteColumn]
    let keyKind: KeyKind
    /// Why it cannot be edited, or nil if it can.
    let readOnlyReason: String?
    let sql: String?

    var id: String { name }
    var isEditable: Bool { readOnlyReason == nil }
}

final class SQLiteDatabase {
    /// Longest text or blob read in full when listing rows; more is cut and marked.
    static let previewBytes = 512

    /// The first 16 bytes of every SQLite database.
    static let fileHeader = Array("SQLite format 3\u{0}".utf8)

    private var handle: OpaquePointer?
    let path: String

    /// True when the file starts with SQLite's header. Says nothing about whether it is healthy.
    static func looksLikeDatabase(at path: String) -> Bool {
        guard let input = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? input.close() }
        guard let head = try? input.read(upToCount: fileHeader.count) else { return false }
        return Array(head) == fileHeader
    }

    /// - Parameter create: make the file if it is not there. Only for building databases in tests:
    ///   the editor opens existing files and must never invent one at a wrong path.
    init(path: String, readOnly: Bool = false, create: Bool = false) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0))
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(result)"
            if let db { sqlite3_close(db) }
            throw SQLiteError.cannotOpen(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
        // A file that is not a database only says so at the first query.
        do {
            _ = try query("SELECT count(*) FROM sqlite_master")
        } catch {
            sqlite3_close(db)
            handle = nil
            throw SQLiteError.notADatabase
        }
    }

    deinit { close() }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    var isOpen: Bool { handle != nil }

    /// Rows changed since the database was opened. Compared across calls to know if anything was edited.
    var totalChanges: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_total_changes(handle))
    }

    // MARK: - Schema

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Tables and views, without SQLite's own internal tables.
    func tables() throws -> [SQLiteTable] {
        let master = try query("SELECT name, type, sql FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name COLLATE NOCASE")
        let virtualNames = master.compactMap { row -> String? in
            guard case .text(let name) = row[0], case .text(let sql) = row[2],
                  sql.uppercased().hasPrefix("CREATE VIRTUAL TABLE") else { return nil }
            return name
        }
        var result: [SQLiteTable] = []
        for row in master {
            guard case .text(let name) = row[0], case .text(let type) = row[1] else { continue }
            var sql: String?
            if case .text(let text) = row[2] { sql = text }
            let isVirtual = virtualNames.contains(name)
            let kind: SQLiteTable.Kind = type == "view" ? .view : (isVirtual ? .virtual : .table)
            let columns: [SQLiteColumn]
            do {
                columns = try self.columns(of: name)
            } catch {
                // A view or virtual table that needs something this SQLite lacks (a custom
                // tokenizer, a function the app registers) must not make the whole file unopenable.
                result.append(SQLiteTable(
                    name: name, kind: kind, columns: [], keyKind: .none,
                    readOnlyReason: "SQLite here cannot read this \(kind == .view ? "view" : "table"): \(error.localizedDescription)",
                    sql: sql
                ))
                continue
            }

            var keyKind = SQLiteTable.KeyKind.none
            var reason: String?
            switch kind {
            case .view:
                reason = "This is a view, which cannot be edited."
            case .virtual:
                reason = "This is a virtual table (such as a search index), which cannot be safely edited."
            case .table:
                if let owner = Self.shadowOwner(of: name, among: virtualNames) {
                    reason = "This table belongs to the search index “\(owner)”; editing it would corrupt the index."
                } else {
                    keyKind = rowKeyKind(for: name, columns: columns)
                    if keyKind == .none {
                        reason = "This table has no row id and no primary key, so there is no safe way to say which row to change."
                    }
                }
            }
            result.append(SQLiteTable(name: name, kind: kind, columns: columns, keyKind: keyKind, readOnlyReason: reason, sql: sql))
        }
        return result
    }

    func columns(of table: String) throws -> [SQLiteColumn] {
        // table_xinfo, not table_info: generated columns are in SELECT * but left out of table_info,
        // which would shift every cell against its column name. Hidden columns of a virtual table
        // (hidden = 1) are not in SELECT *, so they are left out here.
        let info = try query("PRAGMA table_xinfo(\(Self.quote(table)))")
        return info.compactMap { row in
            guard row.count >= 7, case .text(let name) = row[1] else { return nil }
            if case .integer(let hidden) = row[6], hidden == 1 { return nil }
            var declared = ""
            if case .text(let type) = row[2] { declared = type }
            var notNull = false
            if case .integer(let flag) = row[3] { notNull = flag != 0 }
            var fallback: String?
            if case .text(let text) = row[4] { fallback = text }
            var position = 0
            if case .integer(let pk) = row[5] { position = Int(pk) }
            var generated = false
            if case .integer(let hidden) = row[6], hidden >= 2 { generated = true }
            return SQLiteColumn(name: name, declaredType: declared, isNotNull: notNull, primaryKeyPosition: position, defaultValue: fallback, isGenerated: generated)
        }
    }

    func rowCount(of table: String) throws -> Int {
        let rows = try query("SELECT count(*) FROM \(Self.quote(table))")
        if case .integer(let count)? = rows.first?.first { return Int(count) }
        return 0
    }

    /// Names SQLite gives the row id: a table can hide it by having a column of the same name.
    private static let rowIDAliases = ["rowid", "oid", "_rowid_"]

    private func rowKeyKind(for table: String, columns: [SQLiteColumn]) -> SQLiteTable.KeyKind {
        let taken = Set(columns.map { $0.name.lowercased() })
        for alias in Self.rowIDAliases where !taken.contains(alias) {
            // A WITHOUT ROWID table has none of these, and says so here.
            if (try? prepareOnly("SELECT \(alias) FROM \(Self.quote(table)) LIMIT 0")) != nil {
                return .rowID(alias: alias)
            }
        }
        return columns.contains { $0.isPrimaryKey } ? .primaryKey : .none
    }

    /// The virtual table a shadow table belongs to, by SQLite's naming: `docs_content`, `docs_segments`...
    static func shadowOwner(of name: String, among virtualNames: [String]) -> String? {
        let suffixes = ["content", "docsize", "segdir", "segments", "stat", "config", "data", "idx", "node", "parent", "rowid"]
        for owner in virtualNames {
            for suffix in suffixes where name == "\(owner)_\(suffix)" { return owner }
        }
        return nil
    }

    // MARK: - Reading rows

    func rows(in table: SQLiteTable, offset: Int, limit: Int) throws -> [SQLiteRow] {
        let name = Self.quote(table.name)
        var sql: String
        var keyColumns: [Int] = []
        var hasLeadingKey = false
        switch table.keyKind {
        case .rowID(let alias):
            sql = "SELECT \(alias), * FROM \(name) ORDER BY \(alias) LIMIT ? OFFSET ?"
            hasLeadingKey = true
        case .primaryKey:
            let ordered = table.columns.enumerated()
                .filter { $0.element.isPrimaryKey }
                .sorted { $0.element.primaryKeyPosition < $1.element.primaryKeyPosition }
            keyColumns = ordered.map(\.offset)
            let order = ordered.map { Self.quote($0.element.name) }.joined(separator: ", ")
            sql = "SELECT * FROM \(name) ORDER BY \(order) LIMIT ? OFFSET ?"
        case .none:
            sql = "SELECT * FROM \(name) LIMIT ? OFFSET ?"
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(max(limit, 0)))
        sqlite3_bind_int64(statement, 2, Int64(max(offset, 0)))

        var result: [SQLiteRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw SQLiteError.sql(lastMessage()) }
            let count = Int(sqlite3_column_count(statement))
            var key: SQLiteRowKey?
            var cells: [SQLiteCell] = []
            let first = hasLeadingKey ? 1 : 0
            if hasLeadingKey, case .integer(let id) = readFull(statement, 0) { key = .rowID(id) }
            for index in first..<count {
                cells.append(readPreview(statement, Int32(index)))
            }
            if !keyColumns.isEmpty {
                key = .primaryKey(keyColumns.compactMap { $0 < cells.count ? cells[$0].value : nil })
            }
            result.append(SQLiteRow(key: key, cells: cells))
        }
        return result
    }

    /// One value in full, for editing.
    func fullValue(in table: SQLiteTable, key: SQLiteRowKey, column: String) throws -> SQLiteValue {
        let (condition, bindings) = try whereClause(for: table, key: key)
        let statement = try prepare("SELECT \(Self.quote(column)) FROM \(Self.quote(table.name)) WHERE \(condition)")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, from: 1)
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { throw SQLiteError.rowChanged }
            throw SQLiteError.sql(lastMessage())
        }
        return readFull(statement, 0)
    }

    // MARK: - Editing

    func update(table: SQLiteTable, key: SQLiteRowKey, column: String, to value: SQLiteValue) throws {
        try requireEditable(table)
        guard let target = table.columns.first(where: { $0.name == column }) else {
            throw SQLiteError.invalidValue("There is no column “\(column)”.")
        }
        guard !target.isGenerated else {
            throw SQLiteError.invalidValue("“\(column)” is worked out by SQLite from other columns, so it cannot be changed.")
        }
        let (condition, bindings) = try whereClause(for: table, key: key)
        let statement = try prepare("UPDATE \(Self.quote(table.name)) SET \(Self.quote(column)) = ? WHERE \(condition)")
        defer { sqlite3_finalize(statement) }
        try bind([value] + bindings, to: statement, from: 1)
        try runWrite(statement)
        guard sqlite3_changes(handle) == 1 else { throw SQLiteError.rowChanged }
    }

    func insert(table: SQLiteTable, values: [String: SQLiteValue]) throws {
        try requireEditable(table)
        for name in values.keys {
            guard let target = table.columns.first(where: { $0.name == name }) else {
                throw SQLiteError.invalidValue("There is no column “\(name)”.")
            }
            guard !target.isGenerated else {
                throw SQLiteError.invalidValue("“\(name)” is worked out by SQLite from other columns, so it cannot be given a value.")
            }
        }
        let ordered = table.columns.map(\.name).filter { values[$0] != nil }
        let sql: String
        if ordered.isEmpty {
            sql = "INSERT INTO \(Self.quote(table.name)) DEFAULT VALUES"
        } else {
            let names = ordered.map(Self.quote).joined(separator: ", ")
            let marks = Array(repeating: "?", count: ordered.count).joined(separator: ", ")
            sql = "INSERT INTO \(Self.quote(table.name)) (\(names)) VALUES (\(marks))"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(ordered.compactMap { values[$0] }, to: statement, from: 1)
        try runWrite(statement)
    }

    func delete(table: SQLiteTable, key: SQLiteRowKey) throws {
        try requireEditable(table)
        let (condition, bindings) = try whereClause(for: table, key: key)
        let statement = try prepare("DELETE FROM \(Self.quote(table.name)) WHERE \(condition)")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, from: 1)
        try runWrite(statement)
        guard sqlite3_changes(handle) == 1 else { throw SQLiteError.rowChanged }
    }

    // MARK: - Health and housekeeping

    /// "ok", or SQLite's description of what is wrong. A quick check, not a full integrity scan.
    func quickCheck() throws -> String {
        let rows = try query("PRAGMA quick_check")
        if case .text(let text)? = rows.first?.first { return text }
        return "ok"
    }

    /// Fold the write-ahead log into the main file and empty it, so the main file alone holds everything.
    func checkpointAndTruncate() throws {
        _ = try query("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func journalMode() throws -> String {
        if case .text(let mode)? = try query("PRAGMA journal_mode").first?.first { return mode.lowercased() }
        return "delete"
    }

    /// Run statements that return nothing (create tables, insert rows). For building databases in tests
    /// and for the working copy's own housekeeping; the editor uses the checked calls above.
    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError.cannotOpen("The database is closed.") }
        var message: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &message) != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? lastMessage()
            sqlite3_free(message)
            throw SQLiteError.sql(text)
        }
    }

    // MARK: - Internals

    private func requireEditable(_ table: SQLiteTable) throws {
        if let reason = table.readOnlyReason { throw SQLiteError.notEditable(reason) }
    }

    private func whereClause(for table: SQLiteTable, key: SQLiteRowKey) throws -> (String, [SQLiteValue]) {
        switch (table.keyKind, key) {
        case (.rowID(let alias), .rowID(let id)):
            return ("\(alias) = ?", [.integer(id)])
        case (.primaryKey, .primaryKey(let values)):
            let keyColumns = table.columns.filter(\.isPrimaryKey).sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }
            guard keyColumns.count == values.count, !keyColumns.isEmpty else {
                throw SQLiteError.invalidValue("The row's key does not match the table's primary key.")
            }
            // `IS` rather than `=`, so a NULL in a key column still finds its row.
            let condition = keyColumns.map { "\(Self.quote($0.name)) IS ?" }.joined(separator: " AND ")
            return (condition, values)
        default:
            throw SQLiteError.invalidValue("The row's key does not fit this table.")
        }
    }

    private func runWrite(_ statement: OpaquePointer?) throws {
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else { throw SQLiteError.sql(lastMessage()) }
    }

    private func lastMessage() -> String {
        guard let handle else { return "The database is closed." }
        return String(cString: sqlite3_errmsg(handle))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let handle else { throw SQLiteError.cannotOpen("The database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = lastMessage()
            sqlite3_finalize(statement)
            throw SQLiteError.sql(message)
        }
        return statement
    }

    /// Check that a statement compiles, without running it.
    private func prepareOnly(_ sql: String) throws {
        let statement = try prepare(sql)
        sqlite3_finalize(statement)
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?, from start: Int32) throws {
        // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift value need not outlive the call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = start + Int32(offset)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case .integer(let number):
                code = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                code = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                code = sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data):
                code = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), transient)
                }
            }
            guard code == SQLITE_OK else { throw SQLiteError.sql(lastMessage()) }
        }
    }

    /// Run a query and read every value in full. For schema queries, whose results are small.
    private func query(_ sql: String) throws -> [[SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var rows: [[SQLiteValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw SQLiteError.sql(lastMessage()) }
            rows.append((0..<sqlite3_column_count(statement)).map { readFull(statement, $0) })
        }
        return rows
    }

    private func readFull(_ statement: OpaquePointer?, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard let bytes = sqlite3_column_text(statement, index) else { return .text("") }
            return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self))
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard length > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: length))
        default:
            return .null
        }
    }

    private func readPreview(_ statement: OpaquePointer?, _ index: Int32) -> SQLiteCell {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_TEXT:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard let bytes = sqlite3_column_text(statement, index) else { return SQLiteCell(value: .text(""), byteCount: 0, isPreview: false) }
            let shown = min(length, Self.previewBytes)
            // Cutting inside a multi-byte character yields a replacement mark at the end of the preview, which is fine.
            let text = String(decoding: UnsafeBufferPointer(start: bytes, count: shown), as: UTF8.self)
            return SQLiteCell(value: .text(text), byteCount: length, isPreview: shown < length)
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard length > 0, let bytes = sqlite3_column_blob(statement, index) else {
                return SQLiteCell(value: .blob(Data()), byteCount: 0, isPreview: false)
            }
            let shown = min(length, Self.previewBytes)
            return SQLiteCell(value: .blob(Data(bytes: bytes, count: shown)), byteCount: length, isPreview: shown < length)
        default:
            return SQLiteCell(value: readFull(statement, index), byteCount: nil, isPreview: false)
        }
    }
}
