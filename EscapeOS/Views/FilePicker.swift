import Foundation
import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker in copy mode.
///
/// SwiftUI's `.fileImporter` opens the file in place and returns a security-scoped URL. The token
/// for that URL is checked against the app's signing identity. A re-sign whose
/// `application-identifier` is not the bundle id drops the hand-off, so tapping Open does nothing.
/// `asCopy: true` copies the file into this app and returns a normal local URL.
///
/// The presenter stays alive until the picker finishes. A delegate that is released early never
/// receives the result.
@MainActor
final class FilePickerPresenter: NSObject, UIDocumentPickerDelegate {
    private static var active: FilePickerPresenter?
    private let onPick: ([URL]) -> Void

    private init(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
    }

    static func present(contentTypes: [UTType], allowsMultiple: Bool, onPick: @escaping ([URL]) -> Void) {
        if topViewController() is UIDocumentPickerViewController { return }

        let presenter = FilePickerPresenter(onPick: onPick)
        active = presenter

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        picker.delegate = presenter
        picker.shouldShowFileExtensions = true

        let types = contentTypes.map(\.identifier).joined(separator: ", ")
        guard let top = topViewController() else {
            NSLog("FilePicker: no view controller to present from (%@)", types)
            active = nil
            return
        }
        NSLog("FilePicker: presenting (asCopy) for [%@]", types)
        top.present(picker, animated: true)
    }

    /// The import has the bytes. A copy the picker left in this app's temporary folder or Inbox
    /// is removed. Anything outside those two folders is left alone. Safe to call off the main thread.
    nonisolated static func discardCopy(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard ownedCopyRoots().contains(where: { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func noteReceived(_ urls: [URL]) {
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        NSLog("FilePicker: import received %d url(s): %@", urls.count, names)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        NSLog("FilePicker: didPickDocumentsAt %d url(s): %@", urls.count, names)
        onPick(urls)
        Self.active = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        NSLog("FilePicker: cancelled")
        Self.active = nil
    }

    nonisolated private static func ownedCopyRoots() -> [String] {
        var roots = [FileManager.default.temporaryDirectory.standardizedFileURL.path]
        roots += FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).map {
            $0.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        }
        return roots
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let keyWindow = windows.first(where: \.isKeyWindow) ?? windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
