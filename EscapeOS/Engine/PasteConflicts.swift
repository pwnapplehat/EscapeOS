import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What pasting would collide with in the destination folder.
///
/// Issue #4: pasting a copied file where that name already existed silently saved "name 2",
/// while Import from Files asked. Paste now asks the same Replace / Keep Both / Cancel.
struct PastePlan: Equatable {
    /// A file is pasted over an existing file at a different place. Replace is offered for these.
    var replaceableFiles: [String] = []
    /// Names that are taken but must not be replaced: the existing item is a folder, a folder
    /// would land on a file, or the destination is the very item being pasted. Keep Both only.
    var keepBothOnly: [String] = []

    var hasConflicts: Bool { !replaceableFiles.isEmpty || !keepBothOnly.isEmpty }
    var canReplace: Bool { !replaceableFiles.isEmpty }
}

enum PasteConflictPlanner {
    /// True when `itemPath` already lives directly in `destDir`. Compared by path components, the
    /// same way the Import guard is, so `/var` and `/private/var` spellings agree.
    static func isInSameFolder(_ itemPath: String, as destDir: String) -> Bool {
        PathContainment.components(of: (itemPath as NSString).deletingLastPathComponent)
            == PathContainment.components(of: destDir)
    }

    /// - Parameter moving: a cut-and-paste. Moving an item into the folder it is already in does
    ///   nothing, so it is not a conflict.
    static func plan(items: [FileItem], into destDir: String, moving: Bool, files: FileService) -> PastePlan {
        var plan = PastePlan()
        for item in items {
            let sameFolder = isInSameFolder(item.path, as: destDir)
            if moving && sameFolder { continue }
            let preferred = files.preferredDestination(in: destDir, preferredName: item.name)
            let name = (preferred as NSString).lastPathComponent
            switch files.existingKind(at: preferred) {
            case .none:
                continue
            case .directory:
                append(name, to: &plan.keepBothOnly)
            case .file:
                if item.isDirectory || sameFolder {
                    append(name, to: &plan.keepBothOnly)
                } else {
                    append(name, to: &plan.replaceableFiles)
                }
            }
        }
        return plan
    }

    private static func append(_ name: String, to list: inout [String]) {
        if !list.contains(name) { list.append(name) }
    }

    // MARK: - Wording

    static func title(for plan: PastePlan) -> String {
        if plan.replaceableFiles.count == 1 && plan.keepBothOnly.isEmpty {
            return "Replace “\(plan.replaceableFiles[0])”?"
        }
        if !plan.replaceableFiles.isEmpty {
            return plan.replaceableFiles.count == 1 ? "Replace existing file?" : "Replace \(plan.replaceableFiles.count) files?"
        }
        return "Name already used"
    }

    static func message(for plan: PastePlan) -> String {
        var parts: [String] = []
        if plan.replaceableFiles.count == 1 {
            parts.append("A file with this name is already in this folder. Replace overwrites it with the pasted file.")
        } else if plan.replaceableFiles.count > 1 {
            parts.append("\(quotedList(plan.replaceableFiles)) already exist in this folder. Replace overwrites each with the pasted file.")
        }
        if !plan.keepBothOnly.isEmpty {
            parts.append(
                "\(quotedList(plan.keepBothOnly)) can’t be replaced (it is a folder, or it is the item being pasted), so Keep Both saves \(plan.keepBothOnly.count == 1 ? "it" : "those") under a new name."
            )
        }
        return parts.joined(separator: " ")
    }

    private static func quotedList(_ names: [String]) -> String {
        let shown = names.prefix(4).map { "“\($0)”" }.joined(separator: ", ")
        return names.count <= 4 ? shown : "\(shown), and \(names.count - 4) more"
    }
}

extension FileService {
    /// Put `source` into `destDir` under its own name, following `policy`.
    ///
    /// Replace never destroys the original before the new copy is safe: the item is first
    /// copied (or moved) to a hidden sibling name, then `rename(2)` swaps it over the existing file
    /// in one atomic step, so a failure leaves the existing file as it was. A folder is never
    /// replaced, a folder never replaces a file, and an item is never replaced by itself; those
    /// land beside the existing name instead.
    ///
    /// - Returns: where the item landed, or nil when the policy was `.cancel`.
    @discardableResult
    func land(
        source: String,
        sourceIsDirectory: Bool,
        named name: String,
        into destDir: String,
        policy: ImportNamePolicy,
        move: Bool,
        swap: (String, String) -> Int32 = { rename($0, $1) }
    ) throws -> String? {
        if policy == .cancel { return nil }

        var destination = uniqueDestination(in: destDir, preferredName: name)
        var replacing = false
        if policy == .replace {
            let preferred = preferredDestination(in: destDir, preferredName: name)
            let samePlace = PathContainment.components(of: preferred) == PathContainment.components(of: source)
            if !sourceIsDirectory, !samePlace, existingKind(at: preferred) == .file {
                destination = preferred
                replacing = true
            } else if existingKind(at: preferred) == .none {
                destination = preferred
            }
        }

        if !replacing {
            if move { try moveItem(at: source, to: destination) } else { try copyItem(at: source, to: destination) }
            return destination
        }

        let staged = (destDir as NSString).appendingPathComponent(".escapeos-replace-\(UUID().uuidString)")
        do {
            if move { try moveItem(at: source, to: staged) } else { try copyItem(at: source, to: staged) }
        } catch {
            // A copy can stop part-way (out of space). Never leave a hidden half-file in the folder.
            restoreAfterFailedStage(staged: staged, source: source)
            throw error
        }
        if swap(staged, destination) != 0 {
            let reason = String(cString: strerror(errno))
            restoreAfterFailedStage(staged: staged, source: source)
            throw FileServiceError.operationFailed("Could not replace “\((destination as NSString).lastPathComponent)”: \(reason)")
        }
        return destination
    }

    /// Undo a Replace that could not finish: drop a leftover staged copy, or, if the original was
    /// moved into staging, put it back where it came from.
    private func restoreAfterFailedStage(staged: String, source: String) {
        guard existingKind(at: staged) != .none else { return }
        if existingKind(at: source) == .none {
            try? moveItem(at: staged, to: source)
        } else {
            try? deleteItem(at: staged)
        }
    }
}
