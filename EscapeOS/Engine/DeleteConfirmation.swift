import Foundation

/// What the delete confirmation says. Built from the exact items about to be removed so the
/// person sees what is going, not a generic "Are you sure?".
struct DeletePrompt: Equatable {
    let title: String
    let message: String
    /// "Delete and Don't Ask Again" is only offered when the selection is files alone.
    let offersDontAskAgain: Bool
    /// The confirming button: "Delete", or "Move to Trash" when the Trash is on.
    var confirmLabel: String = "Delete"
    var dontAskLabel: String = "Delete, Don’t Ask Again"
}

/// When deleting asks first, and what it says.
///
/// Issue #3: a file used to be deleted the moment Delete was tapped (or swiped), with no way
/// back, and people lost data by accident. Files now ask too. A person who finds that
/// slow can turn it off, but only for files: a folder takes everything under it, so folders
/// always ask.
enum DeleteConfirmation {
    static let preferenceKey = "ConfirmFileDeletes"

    /// How many names the message lists before it says "and N more".
    static let namesShown = 4

    static func confirmFileDeletes(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func setConfirmFileDeletes(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: preferenceKey)
    }

    static func needsPrompt(for items: [FileItem], confirmFileDeletes: Bool) -> Bool {
        guard !items.isEmpty else { return false }
        if items.contains(where: \.isDirectory) { return true }
        return confirmFileDeletes
    }

    /// - Parameter usesTrash: deleting moves the items to the Trash (issue #9), so the wording is
    ///   about moving and restoring rather than about permanent loss.
    static func prompt(for items: [FileItem], usesTrash: Bool = false) -> DeletePrompt {
        if usesTrash { return trashPrompt(for: items) }
        // The alert re-reads this while it is dismissing, after the selection has been cleared;
        // a neutral prompt keeps it from flashing "Delete 0 items?".
        if items.isEmpty {
            return DeletePrompt(title: "Delete?", message: "", offersDontAskAgain: false)
        }
        let folders = items.filter(\.isDirectory)
        let others = items.count - folders.count
        let filesOnly = folders.isEmpty
        let permanent = "This can't be undone. Close the app first if it might be using the file."

        if items.count == 1, let only = items.first {
            if only.isDirectory {
                return DeletePrompt(
                    title: "Delete “\(only.name)” and everything inside?",
                    message: "The folder and all of its contents are permanently deleted. This can't be undone. Close the app first if it might be using them.",
                    offersDontAskAgain: false
                )
            }
            return DeletePrompt(
                title: "Delete “\(only.name)”?",
                message: "The file is permanently deleted. " + permanent,
                offersDontAskAgain: true
            )
        }

        let listed = items.prefix(namesShown).map { "“\($0.name)”" }.joined(separator: ", ")
        let more = items.count > namesShown ? " and \(items.count - namesShown) more" : ""
        var counts: [String] = []
        if others > 0 { counts.append(others == 1 ? "1 file" : "\(others) files") }
        if !folders.isEmpty { counts.append(folders.count == 1 ? "1 folder" : "\(folders.count) folders") }
        var message = "\(listed)\(more) (\(counts.joined(separator: " and "))) will be permanently deleted."
        if !filesOnly {
            message += " Folders are deleted with everything inside them."
        }
        message += " This can't be undone. Close the app first if it might be using them."
        return DeletePrompt(
            title: "Delete \(items.count) items?",
            message: message,
            offersDontAskAgain: filesOnly
        )
    }

    private static func trashPrompt(for items: [FileItem]) -> DeletePrompt {
        let move = "Move to Trash"
        let moveAndDontAsk = "Move to Trash, Don’t Ask Again"
        if items.isEmpty {
            return DeletePrompt(title: "Move to Trash?", message: "", offersDontAskAgain: false, confirmLabel: move, dontAskLabel: moveAndDontAsk)
        }
        let folders = items.filter(\.isDirectory)
        let others = items.count - folders.count
        let filesOnly = folders.isEmpty
        let keptOne = "You can restore it from the Trash (Settings, Trash) until you empty it. It stays on this device, and takes up its space, until then."
        let keptMany = "You can restore them from the Trash (Settings, Trash) until you empty it. They stay on this device, and take up their space, until then."

        if items.count == 1, let only = items.first {
            if only.isDirectory {
                return DeletePrompt(
                    title: "Move “\(only.name)” and everything inside to the Trash?",
                    message: "The folder and all of its contents go to the Trash. \(keptOne)",
                    offersDontAskAgain: false,
                    confirmLabel: move,
                    dontAskLabel: moveAndDontAsk
                )
            }
            return DeletePrompt(
                title: "Move “\(only.name)” to the Trash?",
                message: keptOne,
                offersDontAskAgain: true,
                confirmLabel: move,
                dontAskLabel: moveAndDontAsk
            )
        }

        let listed = items.prefix(namesShown).map { "“\($0.name)”" }.joined(separator: ", ")
        let more = items.count > namesShown ? " and \(items.count - namesShown) more" : ""
        var counts: [String] = []
        if others > 0 { counts.append(others == 1 ? "1 file" : "\(others) files") }
        if !folders.isEmpty { counts.append(folders.count == 1 ? "1 folder" : "\(folders.count) folders") }
        var message = "\(listed)\(more) (\(counts.joined(separator: " and "))) go to the Trash."
        if !filesOnly {
            message += " Folders go with everything inside them."
        }
        message += " " + keptMany
        return DeletePrompt(
            title: "Move \(items.count) items to the Trash?",
            message: message,
            offersDontAskAgain: filesOnly,
            confirmLabel: move,
            dontAskLabel: moveAndDontAsk
        )
    }
}
