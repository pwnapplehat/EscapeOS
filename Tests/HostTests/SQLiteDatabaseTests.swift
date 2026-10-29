import Foundation

/// A database file with the given statements run in it. `wal` puts it in write-ahead-log mode.
@discardableResult
func makeDatabase(_ path: String, wal: Bool = false, _ statements: [String]) -> SQLiteDatabase? {
    guard let db = try? SQLiteDatabase(path: path, create: true) else { return nil }
    if wal { try? db.execute("PRAGMA journal_mode=WAL") }
    for statement in statements { try? db.execute(statement) }
    return db
}

func table(_ db: SQLiteDatabase, _ name: String) -> SQLiteTable? {
    (try? db.tables())?.first { $0.name == name }
}

func runSQLiteDatabaseTests() {
    T.section("SQLiteDatabase")

    // reading the schema
    do {
        let s = Scratch("sql-schema")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL, body TEXT DEFAULT 'none', score REAL)",
            "CREATE TABLE pairs (a TEXT, b INTEGER, note TEXT, PRIMARY KEY (b, a)) WITHOUT ROWID",
            "CREATE TABLE counter (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER)",
            "INSERT INTO counter (n) VALUES (1)",
            "CREATE VIEW titles AS SELECT title FROM notes",
            "CREATE TABLE Zebra (x)",
        ])!
        let tables = (try? db.tables()) ?? []
        T.equal(tables.map(\.name), ["counter", "notes", "pairs", "titles", "Zebra"], "tables and views are listed, case-insensitively sorted, without sqlite_ internals")
        T.check(!tables.contains { $0.name.hasPrefix("sqlite_") }, "sqlite_sequence is hidden")
        let notes = table(db, "notes")
        T.equal(notes?.columns.map(\.name) ?? [], ["id", "title", "body", "score"], "columns in order")
        T.equal(notes?.columns[1].isNotNull, true, "NOT NULL is read")
        T.equal(notes?.columns[0].isPrimaryKey, true, "a primary key is read")
        T.equal(notes?.columns[2].defaultValue ?? "", "'none'", "a default is read")
        T.equal(notes?.columns[3].declaredType ?? "", "REAL", "a declared type is read")
        T.equal(notes?.keyKind, .rowID(alias: "rowid"), "an ordinary table is keyed by its row id")
        T.check(notes?.isEditable == true && notes?.kind == .table, "and is editable")
        let pairs = table(db, "pairs")
        T.equal(pairs?.keyKind, .primaryKey, "a WITHOUT ROWID table is keyed by its primary key")
        T.equal(pairs?.columns.map(\.primaryKeyPosition) ?? [], [2, 1, 0], "composite key positions are kept")
        T.check(pairs?.isEditable == true, "and is editable")
        let view = table(db, "titles")
        T.equal(view?.kind, .view, "a view is a view")
        T.check(view?.isEditable == false, "and read-only")
        T.check((view?.readOnlyReason ?? "").contains("view"), "with a reason that says so")
        T.check((try? db.rowCount(of: "notes")) == 0, "an empty table has no rows")
    }

    // a column can hide the row id name
    do {
        let s = Scratch("sql-rowid")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE t1 (rowid TEXT, v TEXT)",
            "CREATE TABLE t2 (rowid TEXT, oid TEXT, v TEXT)",
            "CREATE TABLE t3 (rowid TEXT, oid TEXT, _rowid_ TEXT, v TEXT)",
        ])!
        T.equal(table(db, "t1")?.keyKind, .rowID(alias: "oid"), "a column named rowid makes it use oid")
        T.equal(table(db, "t2")?.keyKind, .rowID(alias: "_rowid_"), "and so on down the aliases")
        T.equal(table(db, "t3")?.keyKind, SQLiteTable.KeyKind.none, "with all three taken and no primary key there is no safe key")
        T.check(table(db, "t3")?.isEditable == false, "so it is read-only")
        T.check((table(db, "t3")?.readOnlyReason ?? "").contains("no row id and no primary key"), "and says why")
    }

    // reading rows
    do {
        let s = Scratch("sql-rows")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE t (id INTEGER PRIMARY KEY, i INTEGER, r REAL, s TEXT, b BLOB, n TEXT)",
            "INSERT INTO t VALUES (1, 42, 2.5, 'héllo', x'00ff10', NULL)",
        ] + (2...25).map { "INSERT INTO t (id, i) VALUES (\($0), \($0 * 10))" })!
        guard let t = table(db, "t") else { T.check(false, "set-up"); return }
        let rows = (try? db.rows(in: t, offset: 0, limit: 5)) ?? []
        T.equal(rows.count, 5, "a page holds the limit")
        T.equal(rows.first?.key, .rowID(1), "a row carries its key")
        let first = rows.first?.cells.map(\.value) ?? []
        T.equal(first, [.integer(1), .integer(42), .real(2.5), .text("héllo"), .blob(Data([0x00, 0xFF, 0x10])), .null], "every kind of value is read")
        T.equal(rows.map { $0.key }, (1...5).map { SQLiteRowKey.rowID(Int64($0)) }, "in row id order")
        let second = (try? db.rows(in: t, offset: 5, limit: 5)) ?? []
        T.equal(second.first?.key, .rowID(6), "the next page starts where the last stopped")
        let tail = (try? db.rows(in: t, offset: 20, limit: 50)) ?? []
        T.equal(tail.count, 5, "the last page is short")
        T.equal((try? db.rows(in: t, offset: 100, limit: 10))?.count ?? -1, 0, "past the end is empty")
        T.equal((try? db.rowCount(of: "t")) ?? -1, 25, "the row count")
    }

    // long values are previewed, and read in full on request
    do {
        let s = Scratch("sql-long")
        let long = String(repeating: "abc ", count: 1_000)
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT, b BLOB)",
            "INSERT INTO t VALUES (1, '\(long)', zeroblob(5000))",
            "INSERT INTO t VALUES (2, 'short', x'0102')",
        ])!
        guard let t = table(db, "t") else { T.check(false, "set-up"); return }
        let rows = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        let bigText = rows[0].cells[1]
        T.check(bigText.isPreview, "a long text is a preview")
        T.equal(bigText.byteCount ?? -1, 4_000, "and says how long it really is")
        if case .text(let shown) = bigText.value { T.equal(shown.utf8.count, SQLiteDatabase.previewBytes, "the preview is the preview length") }
        let bigBlob = rows[0].cells[2]
        T.check(bigBlob.isPreview && bigBlob.byteCount == 5_000, "a long blob is a preview with its size")
        T.check(!rows[1].cells[1].isPreview && !rows[1].cells[2].isPreview, "short values are shown whole")
        T.equal(rows[1].cells[1].byteCount ?? -1, 5, "with their size")
        if let key = rows[0].key {
            let full = try? db.fullValue(in: t, key: key, column: "s")
            T.equal(full, .text(long), "the full text can be fetched for editing")
            let blob = try? db.fullValue(in: t, key: key, column: "b")
            if case .blob(let data)? = blob { T.equal(data.count, 5_000, "and the full blob") } else { T.check(false, "the full blob is a blob") }
        }
        var gone: SQLiteError?
        do { _ = try db.fullValue(in: t, key: .rowID(99), column: "s") } catch let e as SQLiteError { gone = e } catch {}
        T.equal(gone, .rowChanged, "fetching a row that is gone says it changed")
    }

    // editing by row id
    do {
        let s = Scratch("sql-edit")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER NOT NULL, tag TEXT UNIQUE)",
            "INSERT INTO t VALUES (1, 'one', 1, 'a')",
            "INSERT INTO t VALUES (2, 'two', 2, 'b')",
        ])!
        guard let t = table(db, "t") else { T.check(false, "set-up"); return }
        let before = db.totalChanges
        T.check((try? db.update(table: t, key: .rowID(1), column: "name", to: .text("ONE"))) != nil, "a value is updated")
        T.check(db.totalChanges > before, "and counts as a change")
        var rows = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        T.equal(rows[0].cells[1].value, .text("ONE"), "the new value reads back")
        T.equal(rows[1].cells[1].value, .text("two"), "the other row is untouched")
        T.check((try? db.update(table: t, key: .rowID(1), column: "name", to: .null)) != nil, "a value can be set to NULL")
        T.check((try? db.update(table: t, key: .rowID(1), column: "qty", to: .integer(7))) != nil, "an integer is stored")
        rows = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        T.equal(rows[0].cells[1].value, .null, "NULL reads back as NULL")
        T.equal(rows[0].cells[2].value, .integer(7), "and the integer as an integer")

        func failure(_ body: () throws -> Void) -> SQLiteError? {
            do { try body(); return nil } catch let e as SQLiteError { return e } catch { return nil }
        }
        T.equal(failure { try db.update(table: t, key: .rowID(99), column: "name", to: .text("x")) }, .rowChanged, "updating a row that is gone says it changed")
        T.check((failure { try db.update(table: t, key: .rowID(1), column: "qty", to: .null) }?.errorDescription ?? "").contains("NOT NULL"), "a NOT NULL violation is reported in SQLite's words")
        T.check((failure { try db.update(table: t, key: .rowID(1), column: "tag", to: .text("b")) }?.errorDescription ?? "").contains("UNIQUE"), "and a UNIQUE one")
        T.equal(failure { try db.update(table: t, key: .rowID(1), column: "nope", to: .text("x")) }, .invalidValue("There is no column “nope”."), "an unknown column is refused")
        T.equal(failure { try db.update(table: t, key: .primaryKey([.integer(1)]), column: "name", to: .text("x")) }, .invalidValue("The row's key does not fit this table."), "a key of the wrong kind is refused")
        rows = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        T.equal(rows[0].cells[3].value, .text("a"), "a refused update changes nothing")
    }

    // insert and delete
    do {
        let s = Scratch("sql-insdel")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, n INTEGER DEFAULT 5)",
            "INSERT INTO t VALUES (1, 'a', 1)",
        ])!
        guard let t = table(db, "t") else { T.check(false, "set-up"); return }
        T.check((try? db.insert(table: t, values: ["name": .text("b")])) != nil, "a row is inserted")
        var rows = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        T.equal(rows.count, 2, "now two rows")
        T.equal(rows[1].cells[2].value, .integer(5), "unset columns take their default")
        T.check((try? db.insert(table: t, values: [:])) != nil, "an empty insert uses defaults throughout")
        rows = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        T.equal(rows.count, 3, "now three")
        if let key = rows[1].key {
            T.check((try? db.delete(table: t, key: key)) != nil, "a row is deleted")
        }
        rows = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        T.equal(rows.count, 2, "and gone")
        var error: SQLiteError?
        do { try db.delete(table: t, key: .rowID(999)) } catch let e as SQLiteError { error = e } catch {}
        T.equal(error, .rowChanged, "deleting a row that is gone says it changed")
        error = nil
        do { try db.insert(table: t, values: ["ghost": .text("x")]) } catch let e as SQLiteError { error = e } catch {}
        T.equal(error, .invalidValue("There is no column “ghost”."), "inserting into an unknown column is refused")
    }

    // composite primary keys, with a NULL in the key
    do {
        let s = Scratch("sql-pk")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE pairs (a TEXT, b INTEGER, note TEXT, PRIMARY KEY (b, a)) WITHOUT ROWID",
            "INSERT INTO pairs VALUES ('x', 2, 'first')",
            "INSERT INTO pairs VALUES ('y', 1, 'second')",
            "INSERT INTO pairs VALUES ('x', 1, 'third')",
        ])!
        guard let pairs = table(db, "pairs") else { T.check(false, "set-up"); return }
        let rows = (try? db.rows(in: pairs, offset: 0, limit: 10)) ?? []
        T.equal(rows.map { $0.cells[2].value }, [.text("third"), .text("second"), .text("first")], "rows come in primary-key order (b, then a)")
        T.equal(rows.first?.key, .primaryKey([.integer(1), .text("x")]), "the key is the key columns in key order")
        if let key = rows.first?.key {
            T.check((try? db.update(table: pairs, key: key, column: "note", to: .text("changed"))) != nil, "a row is updated by its composite key")
        }
        let after = (try? db.rows(in: pairs, offset: 0, limit: 10)) ?? []
        T.equal(after.map { $0.cells[2].value }, [.text("changed"), .text("second"), .text("first")], "only that row changed")
        if let key = after.last?.key {
            T.check((try? db.delete(table: pairs, key: key)) != nil, "and a row is deleted by it")
        }
        T.equal((try? db.rowCount(of: "pairs")) ?? -1, 2, "leaving two")
        T.equal(table(db, "pairs")?.isEditable, true, "the table stays editable")
    }

    // a NULL in a unique-but-nullable key still finds its row
    do {
        let s = Scratch("sql-nullkey")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE t (k TEXT, v TEXT, PRIMARY KEY (k)) WITHOUT ROWID",
        ])!
        guard let t = table(db, "t") else { T.check(false, "set-up"); return }
        T.check((try? db.insert(table: t, values: ["k": .text("a"), "v": .text("1")])) != nil, "set-up row")
        T.check((try? db.update(table: t, key: .primaryKey([.text("a")]), column: "v", to: .text("2"))) != nil, "a text key finds its row")
    }

    // a row whose key is NULL is still found again: `=` never matches NULL, `IS` does
    do {
        let s = Scratch("sql-realnullkey")
        let db = makeDatabase(s.path("a.db"), [
            // every name SQLite would use for the row id is taken, so the primary key is the only handle
            "CREATE TABLE t (rowid TEXT, oid TEXT, _rowid_ TEXT, k TEXT PRIMARY KEY, v TEXT)",
            "INSERT INTO t (k, v) VALUES (NULL, 'x')",
            "INSERT INTO t (k, v) VALUES ('a', 'y')",
        ])!
        guard let t = table(db, "t") else { T.check(false, "set-up"); return }
        T.equal(t.keyKind, .primaryKey, "set-up: keyed by the primary key")
        let rows = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        let nullRow = rows.first { $0.key == .primaryKey([.null]) }
        T.check(nullRow != nil, "the row with a NULL key reads back with that key")
        T.check((try? db.update(table: t, key: .primaryKey([.null]), column: "v", to: .text("changed"))) != nil, "a NULL key finds its row")
        let after = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        T.equal(after.first { $0.key == .primaryKey([.null]) }?.cells.last?.value, .text("changed"), "and the change landed on that row")
        T.equal(after.first { $0.key == .primaryKey([.text("a")]) }?.cells.last?.value, .text("y"), "while the other row is untouched")
    }

    // generated columns are shown in their place and never written
    do {
        let s = Scratch("sql-generated")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE g (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER GENERATED ALWAYS AS (a * 2) VIRTUAL, c TEXT)",
            "INSERT INTO g (id, a, c) VALUES (1, 5, 'see')",
        ])!
        guard let g = table(db, "g") else { T.check(false, "set-up"); return }
        T.equal(g.columns.map(\.name), ["id", "a", "b", "c"], "the generated column is listed")
        T.equal(g.columns.map(\.isGenerated), [false, false, true, false], "and marked")
        let rows = (try? db.rows(in: g, offset: 0, limit: 10)) ?? []
        T.equal(rows.first?.cells.map(\.value) ?? [], [.integer(1), .integer(5), .integer(10), .text("see")], "its value sits in its own place, so no cell is shifted onto the wrong name")
        func failure(_ body: () throws -> Void) -> SQLiteError? {
            do { try body(); return nil } catch let e as SQLiteError { return e } catch { return nil }
        }
        T.check((failure { try db.update(table: g, key: .rowID(1), column: "b", to: .integer(3)) }?.errorDescription ?? "").contains("worked out by SQLite"), "it cannot be updated")
        T.check((failure { try db.insert(table: g, values: ["a": .integer(1), "b": .integer(2)]) }?.errorDescription ?? "").contains("worked out by SQLite"), "or given a value on insert")
        T.check((try? db.update(table: g, key: .rowID(1), column: "c", to: .text("ok"))) != nil, "the ordinary columns still edit")
    }

    // one view that SQLite cannot read does not stop the rest of the file opening
    do {
        let s = Scratch("sql-badview")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE good (id INTEGER PRIMARY KEY, v TEXT)",
            "CREATE VIEW broken AS SELECT no_such_function(v) AS x FROM good",
        ])!
        let all = try? db.tables()
        T.check(all != nil, "the schema still loads")
        T.check(all?.contains { $0.name == "good" && $0.isEditable } ?? false, "the ordinary table is there and editable")
        let broken = all?.first { $0.name == "broken" }
        T.check(broken != nil && broken?.isEditable == false && broken?.readOnlyReason != nil, "the unreadable view is listed, read-only, with a reason")
    }

    // names that need quoting, and values that look like SQL
    do {
        let s = Scratch("sql-quote")
        let weird = "we\"ird name"
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE \(SQLiteDatabase.quote(weird)) (id INTEGER PRIMARY KEY, \(SQLiteDatabase.quote("a\"b; DROP TABLE x; --")) TEXT)",
            "CREATE TABLE x (id INTEGER PRIMARY KEY)",
        ])!
        T.equal(SQLiteDatabase.quote("plain"), "\"plain\"", "a name is quoted")
        T.equal(SQLiteDatabase.quote("a\"b"), "\"a\"\"b\"", "and its quotes doubled")
        guard let t = table(db, weird) else { T.check(false, "a table with quotes and spaces in its name is found"); return }
        let column = t.columns[1].name
        T.equal(column, "a\"b; DROP TABLE x; --", "a column with SQL in its name is read back as a name")
        let evil = "'); DROP TABLE x; --"
        T.check((try? db.insert(table: t, values: [column: .text(evil)])) != nil, "a value that looks like SQL is inserted")
        let rows = (try? db.rows(in: t, offset: 0, limit: 10)) ?? []
        T.equal(rows.first?.cells[1].value, .text(evil), "and stored exactly as typed")
        T.check(table(db, "x") != nil, "the other table is still there")
        T.check((try? db.update(table: t, key: .rowID(1), column: column, to: .text("it's \"quoted\""))) != nil, "quotes in a value are fine")
        T.equal((try? db.rows(in: t, offset: 0, limit: 1))?.first?.cells[1].value, .text("it's \"quoted\""), "and read back")
    }

    // unicode
    do {
        let s = Scratch("sql-unicode")
        let db = makeDatabase(s.path("a.db"), ["CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT)"])!
        guard let t = table(db, "t") else { T.check(false, "set-up"); return }
        let text = "héllo wörld 日本語 🎉 \u{0301}"
        T.check((try? db.insert(table: t, values: ["s": .text(text)])) != nil, "unicode is inserted")
        T.equal((try? db.rows(in: t, offset: 0, limit: 1))?.first?.cells[1].value, .text(text), "and read back unchanged")
    }

    // read-only tables refuse every write
    do {
        let s = Scratch("sql-readonly")
        let db = makeDatabase(s.path("a.db"), [
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT)",
            "INSERT INTO notes VALUES (1, 'a')",
            "CREATE VIEW v AS SELECT * FROM notes",
        ])!
        guard let view = table(db, "v") else { T.check(false, "set-up"); return }
        func refused(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch SQLiteError.notEditable { return true } catch { return false }
        }
        T.check(refused { try db.update(table: view, key: .rowID(1), column: "title", to: .text("x")) }, "a view cannot be updated")
        T.check(refused { try db.insert(table: view, values: ["title": .text("x")]) }, "or inserted into")
        T.check(refused { try db.delete(table: view, key: .rowID(1)) }, "or deleted from")
        let rows = (try? db.rows(in: view, offset: 0, limit: 10)) ?? []
        T.equal(rows.count, 1, "but it can be read")
        T.check(rows.first?.key == nil, "its rows have no key")
        T.equal((try? db.rows(in: table(db, "notes")!, offset: 0, limit: 10))?.first?.cells[1].value, .text("a"), "and nothing was written to the table behind it")
    }

    // search indexes: the virtual table and its shadow tables are protected
    do {
        let s = Scratch("sql-fts")
        let db = makeDatabase(s.path("a.db"), [])!
        if (try? db.execute("CREATE VIRTUAL TABLE docs USING fts5(body)")) != nil {
            try? db.execute("INSERT INTO docs (body) VALUES ('hello world')")
            let tables = (try? db.tables()) ?? []
            T.equal(table(db, "docs")?.kind, .virtual, "a virtual table is recognised")
            T.check(table(db, "docs")?.isEditable == false, "and is read-only")
            let shadows = tables.filter { $0.name.hasPrefix("docs_") }
            T.check(!shadows.isEmpty, "its shadow tables are listed")
            T.check(shadows.allSatisfy { !$0.isEditable }, "and every one is read-only")
            T.check(shadows.allSatisfy { ($0.readOnlyReason ?? "").contains("search index") }, "with a reason that names the index")
        } else {
            print("  (fts5 not available in this SQLite; search-index check skipped)")
        }
        T.equal(SQLiteDatabase.shadowOwner(of: "notes_content", among: ["notes"]), "notes", "shadow naming: content")
        T.check(SQLiteDatabase.shadowOwner(of: "notes_extra", among: ["notes"]) == nil, "an unrelated suffix is not a shadow")
        T.check(SQLiteDatabase.shadowOwner(of: "mynotes_content", among: ["notes"]) == nil, "a longer name is not a shadow")
    }

    // typed input
    do {
        T.equal(try? SQLiteInputKind.text.value(from: " hi "), .text(" hi "), "text is kept exactly")
        T.equal(try? SQLiteInputKind.integer.value(from: " 42 "), .integer(42), "an integer is parsed, ignoring spaces")
        T.equal(try? SQLiteInputKind.integer.value(from: "-7"), .integer(-7), "a negative integer")
        T.equal(try? SQLiteInputKind.real.value(from: "2.5"), .real(2.5), "a real")
        T.equal(try? SQLiteInputKind.null.value(from: "ignored"), SQLiteValue.null, "NULL ignores the text")
        func message(_ body: () throws -> SQLiteValue) -> String {
            do { _ = try body(); return "" } catch { return error.localizedDescription }
        }
        T.check(message { try SQLiteInputKind.integer.value(from: "4.5") }.contains("not a whole number"), "4.5 is not an integer")
        T.check(message { try SQLiteInputKind.integer.value(from: "abc") }.contains("“abc”"), "the message quotes what was typed")
        T.check(message { try SQLiteInputKind.real.value(from: "nan") }.contains("not a number"), "NaN is refused")
        T.check(message { try SQLiteInputKind.real.value(from: "inf") }.contains("not a number"), "and infinity")
        T.check(message { try SQLiteInputKind.integer.value(from: "99999999999999999999") }.contains("not a whole number"), "an integer too big is refused, not wrapped")
        T.equal(SQLiteValue.integer(1).kindName, "integer", "kind names")
        T.equal(SQLiteValue.null.kindName, "NULL", "NULL's kind name")
    }

    // health, journal mode, and files that are not databases
    do {
        let s = Scratch("sql-health")
        let db = makeDatabase(s.path("a.db"), wal: true, ["CREATE TABLE t (x)", "INSERT INTO t VALUES (1)"])!
        T.equal((try? db.quickCheck()) ?? "", "ok", "a healthy database passes the quick check")
        T.equal((try? db.journalMode()) ?? "", "wal", "WAL mode is reported")
        T.check((try? db.checkpointAndTruncate()) != nil, "a checkpoint runs")
        let wal = (try? FileManager.default.attributesOfItem(atPath: s.path("a.db-wal")))?[.size] as? NSNumber
        T.equal(wal?.intValue ?? 0, 0, "and empties the log")
        T.check(SQLiteDatabase.looksLikeDatabase(at: s.path("a.db")), "a database has the SQLite header")
        s.write("text.txt", text: "just some text, not a database at all")
        T.check(!SQLiteDatabase.looksLikeDatabase(at: s.path("text.txt")), "a text file does not")
        T.check(!SQLiteDatabase.looksLikeDatabase(at: s.path("missing")), "a missing file does not")
        var error: SQLiteError?
        do { _ = try SQLiteDatabase(path: s.path("text.txt")) } catch let e as SQLiteError { error = e } catch {}
        T.equal(error, .notADatabase, "opening a non-database says so")
        T.check((error?.errorDescription ?? "").contains("not a SQLite database"), "in plain words")
        T.check(!s.exists("text.txt-journal") && s.read("text.txt") == Data("just some text, not a database at all".utf8), "and does not touch the file")
        s.write("empty.db", bytes: 0)
        T.check(SQLiteDatabase.looksLikeDatabase(at: s.path("empty.db")) == false, "an empty file has no header")
        var missing: SQLiteError?
        do { _ = try SQLiteDatabase(path: s.path("nowhere/missing.db")) } catch let e as SQLiteError { missing = e } catch {}
        T.check(missing != nil, "a path that cannot be opened is an error")
        let closed = makeDatabase(s.path("b.db"), ["CREATE TABLE t (x)"])!
        closed.close()
        T.check(!closed.isOpen, "a closed database reports it")
        T.check((try? closed.tables()) == nil, "and refuses queries rather than crashing")
        closed.close()
        T.check(true, "closing twice is harmless")
    }

    // a read-only open cannot write
    do {
        let s = Scratch("sql-ro")
        makeDatabase(s.path("a.db"), ["CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", "INSERT INTO t VALUES (1, 'a')"])
        let db = try? SQLiteDatabase(path: s.path("a.db"), readOnly: true)
        T.check(db != nil, "a database opens read-only")
        if let db, let t = table(db, "t") {
            T.check((try? db.update(table: t, key: .rowID(1), column: "v", to: .text("b"))) == nil, "and a write to it fails")
            T.equal((try? db.rows(in: t, offset: 0, limit: 1))?.first?.cells[1].value, .text("a"), "leaving the data as it was")
        }
    }
}
