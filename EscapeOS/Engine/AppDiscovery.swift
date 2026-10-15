import Foundation
import UIKit

/// A single installed (user/App Store) application discoverable on-device.
struct InstalledApp: Identifiable, Hashable {
    let id = UUID()
    let bundleIdentifier: String
    let name: String
    let containerPath: String
    let version: String?
}

/// Errors surfaced by tunnel-based app discovery.
enum AppDiscoveryError: LocalizedError {
    case noPairingFile
    case heartbeatFailed(String)
    case enumerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPairingFile:
            return "No pairing file imported. Pairing is required to list apps on-device."
        case .heartbeatFailed(let m):
            // lockdownd answers InvalidHostID when the pairing file's host is not in the
            // device's trusted list: the file is stale, belongs to another device, or trust
            // was reset. LocalDevVPN is working in that case, so the generic network advice
            // below would send people the wrong way.
            if m.range(of: "InvalidHostID", options: .caseInsensitive) != nil {
                return "This device does not recognise EscapeOS's pairing file (InvalidHostID), so it refused the connection. The file is out of date, was made for a different device, or this device's trust list was reset. Place a fresh pairing file with iPASide (Settings, Pairing file, Place), or import the one your other sideloading app uses, then tap Retry."
            }
            return "Could not connect to the local tunnel: \(m). Enable LocalDevVPN on its default 10.7.0.1 IPs, stay on Wi-Fi, and use a pairing file from iPASide."
        case .enumerationFailed(let m):
            return "Failed to enumerate apps: \(m)"
        }
    }
}

/// Discovers installed apps on-device via LocalDevVPN + a pairing file.
/// iOS 26.4+ uses RPPairing/RSD; iOS 18 falls back to lockdown over the same VPN.
final class AppDiscovery {

    private let tunnel = TunnelContext.shared

    /// Whether a pairing file has been imported.
    var hasPairingFile: Bool { tunnel.hasPairingFile }

    /// Establish the tunnel and enumerate installed apps.
    /// - Throws: `AppDiscoveryError` when pairing/heartbeat/enumeration fails.
    func fetchInstalledApps() throws -> [InstalledApp] {
        guard tunnel.hasPairingFile else {
            throw AppDiscoveryError.noPairingFile
        }

        do {
            try tunnel.ensureHeartbeat()
        } catch {
            throw AppDiscoveryError.heartbeatFailed(error.localizedDescription)
        }

        let all: [String: [AnyHashable: Any]]
        do {
            all = try tunnel.getAllAppsInfo()
        } catch {
            throw AppDiscoveryError.enumerationFailed(error.localizedDescription)
        }

        var apps: [InstalledApp] = []
        for (bundleId, infoRaw) in all {
            let info = infoRaw.reduce(into: [String: Any]()) { $0[$1.key.base as? String ?? ""] = $1.value }
            // Only user-installed (App Store / sideloaded) apps.
            if let appType = info["ApplicationType"] as? String, appType != "User" {
                continue
            }
            // Resolve display name.
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? bundleId
            // Container path (Data container).
            guard let container = info["Container"] as? String, !container.isEmpty else { continue }
            let version = info["CFBundleShortVersionString"] as? String
            apps.append(InstalledApp(
                bundleIdentifier: bundleId,
                name: name,
                containerPath: container,
                version: version
            ))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Fetch the SpringBoard icon for an app, if the tunnel is up.
    func appIcon(for bundleId: String) -> UIImage? {
        try? tunnel.getAppIcon(withBundleId: bundleId)
    }

    /// Import a pairing file (contents of a .mobiledevicepairing plist).
    func importPairingFile(_ contents: String) throws {
        try tunnel.savePairingFile(contents)
    }

    /// Remove the stored pairing file.
    func resetPairing() {
        tunnel.resetPairingFile()
    }
}
