import Foundation

func runFileKindTests() {
    T.section("FileKind")
    for name in ["app.db", "App.SQLITE", "store.sqlite3", "x.db3", "y.sqlitedb", "dir/Data.DB"] {
        T.check(FileContentKind.opensAsDatabase(name: name), "\(name) opens as a database")
    }
    for name in ["app.db-wal", "a.wal", "a.shm", "data.realm", "notes.txt", "db", "archive.zip", "database", "x.dbx"] {
        T.check(!FileContentKind.opensAsDatabase(name: name), "\(name) does not open as a database")
    }
    T.equal(FileContentKind.classify(name: "a.sqlite", isDirectory: false), .database, "a sqlite file is classified as a database")
    T.equal(FileContentKind.classify(name: "a.wal", isDirectory: false), .database, "a log file keeps the database icon")
    T.equal(FileOpenMode(rawValue: "database"), .database, "the database open mode exists")
}
