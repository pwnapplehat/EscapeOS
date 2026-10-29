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

    // Without the Trash the buttons say Delete, as they always did.
    T.equal(one.confirmLabel, "Delete", "the permanent prompt's button says Delete")
    T.equal(one.dontAskLabel, "Delete, Don’t Ask Again", "and its don't-ask button says so")

    // With the Trash (issue #9) it talks about moving and restoring, never about permanent loss.
    let trashOne = DeleteConfirmation.prompt(for: [item("notes.txt")], usesTrash: true)
    T.equal(trashOne.title, "Move “notes.txt” to the Trash?", "a single file moves to the Trash")
    T.equal(trashOne.confirmLabel, "Move to Trash", "the button says what it does")
    T.equal(trashOne.dontAskLabel, "Move to Trash, Don’t Ask Again", "and so does the don't-ask button")
    T.check(trashOne.message.contains("restore it from the Trash"), "it says it can be restored")
    T.check(trashOne.message.contains("takes up its space"), "and that the Trash takes room")
    T.check(!trashOne.message.contains("permanently") && !trashOne.message.contains("can't be undone"), "and does not claim the loss is permanent")
    T.check(trashOne.offersDontAskAgain, "a single file still offers don't-ask-again")

    let trashFolder = DeleteConfirmation.prompt(for: [item("Caches", folder: true)], usesTrash: true)
    T.equal(trashFolder.title, "Move “Caches” and everything inside to the Trash?", "a folder says everything inside goes")
    T.check(trashFolder.message.contains("all of its contents go to the Trash"), "its message says so")
    T.check(!trashFolder.offersDontAskAgain, "a folder still never offers don't-ask-again")

    let trashMany = DeleteConfirmation.prompt(for: (1...7).map { item("f\($0).bin") }, usesTrash: true)
    T.equal(trashMany.title, "Move 7 items to the Trash?", "several items are counted")
    T.check(trashMany.message.contains("“f1.bin”, “f2.bin”, “f3.bin”, “f4.bin” and 3 more"), "four names then the rest")
    T.check(trashMany.message.contains("7 files"), "the files are counted")
    T.check(trashMany.message.contains("restore them"), "the plural wording is used")
    T.check(trashMany.message.contains("They stay on this device"), "all the way through")
    T.check(trashMany.offersDontAskAgain, "files alone still offer don't-ask-again")

    let trashMixed = DeleteConfirmation.prompt(for: [item("a.txt"), item("D", folder: true), item("b.txt")], usesTrash: true)
    T.check(trashMixed.message.contains("2 files and 1 folder"), "a mixed selection counts both")
    T.check(trashMixed.message.contains("Folders go with everything inside them"), "and warns about folders")
    T.check(!trashMixed.offersDontAskAgain, "and never offers don't-ask-again")

    let trashEmpty = DeleteConfirmation.prompt(for: [], usesTrash: true)
    T.equal(trashEmpty.title, "Move to Trash?", "an emptied selection gets a neutral title")
    T.check(trashEmpty.message.isEmpty && !trashEmpty.offersDontAskAgain, "and says nothing else")
    T.equal(trashEmpty.confirmLabel, "Move to Trash", "with the right button")
    T.equal(DeleteConfirmation.prompt(for: [item("a")], usesTrash: false), DeleteConfirmation.prompt(for: [item("a")]), "usesTrash defaults to the old wording")
}
