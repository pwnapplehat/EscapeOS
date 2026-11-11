import Foundation

func runAppGroupAndBackupImportTests() {
    T.section("App groups from an install record")
    let listed = AppGroupListing.containers(in: [
        "GroupContainers": [
            "group.com.example.shared": "/private/var/mobile/Containers/Shared/AppGroup/AAA",
            "not-a-group": "/tmp/nope"
        ],
        "Entitlements": [
            "com.apple.security.application-groups": ["group.com.example.shared", "group.com.example.extra"]
        ]
    ])
    T.equal(listed.map(\.identifier), ["group.com.example.extra", "group.com.example.shared"], "groups sorted, non-group dropped")
    T.equal(listed.first { $0.identifier == "group.com.example.shared" }?.path, "/private/var/mobile/Containers/Shared/AppGroup/AAA", "path kept")
    T.equal(listed.first { $0.identifier == "group.com.example.extra" }?.canBrowse, false, "identifier without a path cannot be browsed")

    let nested = AppGroupListing.containers(in: [
        "GroupContainers": [
            "group.com.example.nested": ["Path": "/private/var/mobile/Containers/Shared/AppGroup/BBB"]
        ]
    ])
    T.equal(nested.first?.path, "/private/var/mobile/Containers/Shared/AppGroup/BBB", "path inside a record")
    T.equal(AppGroupListing.containers(in: ["CFBundleIdentifier": "com.example"]).isEmpty, true, "no groups is empty")
    T.equal(AppGroupListing.groupKeyNames(in: ["GroupContainers": [:], "Container": "/tmp"]), ["GroupContainers"], "group-like key names")

    T.section("Importing an exported backup")
    let scratch = Scratch()
    let dir = URL(fileURLWithPath: scratch.path("backups"), isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let taken = dir.appendingPathComponent("Example.zip")
    FileManager.default.createFile(atPath: taken.path, contents: Data("x".utf8))
    let unique = BackupPaths.uniqueArchiveURL(in: dir, preferredName: "Example.zip")
    T.equal(unique.lastPathComponent, "Example 2.zip", "an existing backup name is kept")

    let metadata = BackupMetadata(
        bundleIdentifier: "com.example.app",
        appName: "Example",
        containerPath: "/private/var/mobile/Containers/Data/Application/ABC",
        createdAt: "2026-11-11T00:00:00Z",
        fileCount: 0,
        totalBytes: 0,
        manifestSHA256: "abc",
        escapeOSVersion: "0.3.2"
    )
    let json = try! JSONEncoder().encode(metadata)
    let source = URL(fileURLWithPath: scratch.path("export/Example_backup.zip"))
    try? FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = ZipWriter()
    try! writer.begin(at: source)
    try! writer.addFile(name: "backup.json", data: json)
    try! writer.finish()

    let imported = try! BackupCatalog().importArchive(from: source, into: dir)
    T.equal(imported.metadata.bundleIdentifier, "com.example.app", "imported backup keeps its app")
    T.equal(imported.archiveFileName, "Example_backup.zip", "imported name")
    T.check(FileManager.default.fileExists(atPath: imported.archiveURL.path), "copy is in the backups folder")

    let again = try! BackupCatalog().importArchive(from: source, into: dir)
    T.equal(again.archiveFileName, "Example_backup 2.zip", "a second import does not replace the first")

    let junk = URL(fileURLWithPath: scratch.path("export/notes.zip"))
    let junkWriter = ZipWriter()
    try! junkWriter.begin(at: junk)
    try! junkWriter.addFile(name: "notes.txt", data: Data("hi".utf8))
    try! junkWriter.finish()
    do {
        _ = try BackupCatalog().importArchive(from: junk, into: dir)
        T.check(false, "a zip that is not a backup is refused")
    } catch {
        T.check(true, "a zip that is not a backup is refused")
    }
}
