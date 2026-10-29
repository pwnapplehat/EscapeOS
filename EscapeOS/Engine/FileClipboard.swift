import Combine
import Foundation
import SwiftUI
import UIKit

/// App-wide Copy/Cut buffer for container files (Filza-style).
///
/// Each folder push creates its own `FileBrowserViewModel`, so the buffer
/// cannot live on the view model. Paste works in any folder of any app.
final class FileClipboard: ObservableObject {
    static let shared = FileClipboard()

    enum Mode {
        case copy
        case cut
    }

    struct Payload {
        let containerPath: String
        let items: [FileItem]
        let mode: Mode
    }

    @Published private(set) var payload: Payload?

    var isEmpty: Bool { payload == nil }

    var pasteTitle: String {
        guard let payload else { return "Paste" }
        let n = payload.items.count
        let verb = payload.mode == .cut ? "Move here" : "Paste"
        if n == 1 {
            return "\(verb) “\(payload.items[0].name)”"
        }
        return "\(verb) \(n) items"
    }

    func copy(_ items: [FileItem], containerPath: String) {
        payload = Payload(containerPath: containerPath, items: items, mode: .copy)
        CopyFeedback.shared.show(
            items.count == 1 ? "Copied “\(items[0].name)”" : "Copied \(items.count) items"
        )
    }

    func cut(_ items: [FileItem], containerPath: String) {
        payload = Payload(containerPath: containerPath, items: items, mode: .cut)
        CopyFeedback.shared.show(
            items.count == 1 ? "Cut “\(items[0].name)”" : "Cut \(items.count) items"
        )
    }

    func clear() {
        payload = nil
    }

    static func copyText(_ text: String, confirmation: String = "Copied") {
        UIPasteboard.general.string = text
        CopyFeedback.shared.show(confirmation)
    }
}

/// Brief on-screen confirmation for copy/cut. Observed at the root so it
/// appears over Apps, detail, and the file browser.
final class CopyFeedback: ObservableObject {
    static let shared = CopyFeedback()

    @Published private(set) var message: String?

    private var hideWork: DispatchWorkItem?

    func show(_ message: String) {
        hideWork?.cancel()
        self.message = message
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let work = DispatchWorkItem { [weak self] in
            if self?.message == message {
                self?.message = nil
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

struct CopyBanner: View {
    let message: String?
    /// Extra room at the bottom, so the banner clears the operations bar when that is showing.
    var lift: CGFloat = 0

    var body: some View {
        VStack {
            Spacer()
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: Color.black.opacity(0.18), radius: 8, y: 2)
                    .padding(.bottom, 72 + lift)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: message)
        .allowsHitTesting(false)
    }
}
