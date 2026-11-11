import SwiftUI

/// Honest product limits. Shown on first launch and in Settings.
enum ProductLimits {
    static let title = "Sandbox access with limits"

    static let body = """
EscapeOS lists installed apps through LocalDevVPN and a pairing file, then opens another app's Data container: Documents, Library, and tmp. House Arrest is only how a PC can drop that pairing file into EscapeOS Documents — it does not replace pairing, and it cannot list or open other apps from inside EscapeOS.

You can browse, preview, edit, back up, restore, and reclaim cache/tmp space in those containers. Reclaim never deletes Documents, Preferences, Application Support, Keychain, App Groups, or system folders. Reset App Data on an app’s detail screen does empty Documents, Library, and tmp.

Deleted items go to a Trash inside EscapeOS so they can be restored; turn that off in Settings. The SQLite editor works on a copy and keeps the original in the Trash before it saves over it.

Close the target app before restoring, reclaiming, or editing live databases. A restore overwrites files in that container.
"""
}

struct LimitsDisclaimerView: View {
    var onAcknowledge: () -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text(ProductLimits.title)
                    .font(.title2).bold()
                Text(ProductLimits.body)
                    .font(.body)
                    .foregroundColor(.secondary)
                Spacer()
                Button("I understand", action: onAcknowledge)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("Before you start")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
