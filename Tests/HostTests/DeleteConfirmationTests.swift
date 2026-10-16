import Foundation

private func item(_ name: String, folder: Bool = false) -> FileItem {
    FileItem(
        name: name, path: "/x/" + name, kind: folder ? .directory : .regular, size: 1,
        modified: nil, isReadable: true, isWritable: true
    )
}

func runDeleteConfirmationTests() {
    T.section("DeleteConfirmation")

    // When it asks.
    T.check(!DeleteConfirmation.needsPrompt(for: [], confirmFileDeletes: true), "nothing selected never asks")
    T.check(DeleteConfirmation.needsPrompt(for: [item("a.txt")], confirmFileDeletes: true), "a file asks by default")
    T.check(!DeleteConfirmation.needsPrompt(for: [item("a.txt")], confirmFileDeletes: false), "a file does not ask once turned off")
    T.check(DeleteConfirmation.needsPrompt(for: [item("D", folder: true)], confirmFileDeletes: false), "a folder always asks")
    T.check(
        DeleteConfirmation.needsPrompt(for: [item("a.txt"), item("D", folder: true)], confirmFileDeletes: false),
        "a mixed selection with a folder always asks"
    )

    // The preference defaults to asking, and persists.
    let suite = "escapeos.host.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    T.check(DeleteConfirmation.confirmFileDeletes(in: defaults), "asks when nothing was ever chosen")
    DeleteConfirmation.setConfirmFileDeletes(false, in: defaults)
    T.check(!DeleteConfirmation.confirmFileDeletes(in: defaults), "turning it off persists")
    DeleteConfirmation.setConfirmFileDeletes(true, in: defaults)
    T.check(DeleteConfirmation.confirmFileDeletes(in: defaults), "turning it back on persists")

    // What it says.
    let one = DeleteConfirmation.prompt(for: [item("notes.txt")])
    T.equal(one.title, "Delete “notes.txt”?", "single file title names the file")
    T.check(one.offersDontAskAgain, "a single file offers don't-ask-again")
    T.check(one.message.contains("permanently"), "single file message says permanent")

    let folder = DeleteConfirmation.prompt(for: [item("Caches", folder: true)])
    T.equal(folder.title, "Delete “Caches” and everything inside?", "folder title says everything inside")
    T.check(!folder.offersDontAskAgain, "a folder never offers don't-ask-again")

    let many = DeleteConfirmation.prompt(for: (1...7).map { item("f\($0).bin") })
    T.equal(many.title, "Delete 7 items?", "multi title counts the items")
    T.check(many.message.contains("“f1.bin”, “f2.bin”, “f3.bin”, “f4.bin” and 3 more"), "multi message lists four names then the rest")
    T.check(many.message.contains("7 files"), "multi message counts files")
    T.check(many.offersDontAskAgain, "files only offers don't-ask-again")

    let mixed = DeleteConfirmation.prompt(for: [item("a.txt"), item("D", folder: true), item("b.txt")])
    T.check(mixed.message.contains("2 files and 1 folder"), "mixed message counts both")
    T.check(mixed.message.contains("everything inside"), "mixed message warns about folder contents")
    T.check(!mixed.offersDontAskAgain, "a mixed selection never offers don't-ask-again")

    let empty = DeleteConfirmation.prompt(for: [])
    T.equal(empty.title, "Delete?", "an emptied selection gets a neutral title, not 'Delete 0 items?'")
    T.check(empty.message.isEmpty && !empty.offersDontAskAgain, "and says nothing else")

    let exactlyFour = DeleteConfirmation.prompt(for: (1...4).map { item("g\($0)") })
    T.check(!exactlyFour.message.contains("more"), "four names are all listed with no 'more'")
}
