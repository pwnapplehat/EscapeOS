import Foundation

/// Errors that can occur while consuming or releasing a sandbox extension
/// for a container path via the containermanager primitives.
enum SandboxEscapeError: Error, LocalizedError {
    case notAbsolutePath
    case targetMissing
    case resolveFailed
    case queryCreateFailed
    case outsideSandbox
    case kernelRejected
    case asprintfFailed
    case symlinkFailed
    case appGroupUnavailable
    case invalidHandle
    case unknown(code: Int64)

    var errorDescription: String? {
        switch self {
        case .notAbsolutePath:
            return "The provided path is not an absolute path."
        case .targetMissing:
            return "The target path does not exist on this device."
        case .resolveFailed:
            return "Failed to resolve containermanager symbols."
        case .queryCreateFailed:
            return "Failed to create the container query."
        case .outsideSandbox:
            return "The path lies outside containermanager's sandbox."
        case .kernelRejected:
            return "The kernel refused to issue a sandbox extension."
        case .asprintfFailed:
            return "Failed to build the query part string."
        case .symlinkFailed:
            return "Could not prepare EscapeOS's App Group container."
        case .appGroupUnavailable:
            return "EscapeOS could not open this app's data. The signature has no App Group this install can use. Sideload it again with iPASide."
        case .invalidHandle:
            return "Attempted to use an invalid sandbox handle."
        case .unknown(let code):
            return "Unknown sandbox error (code \(code))."
        }
    }
}

/// Thin, type-safe wrapper around `worse_query`. All access to another app's
/// container must go through this type so that handles are tracked and released.
///
/// `worse_query` (class 7, this app's own App Group) is the successor to
/// `bad_query`. Upstream covers iOS 26.0 through 26.7.2 and iOS 27.2. It requires
/// EscapeOS to be signed with the App Group below. iPASide keeps that
/// entitlement when it signs the IPA and registers the group with the Apple ID.
/// The query briefly replaces the group's `Library/Caches` with a symlink, so
/// calls are serialized.
final class SandboxEscape {

    /// The App Group declared in EscapeOS.entitlements.
    ///
    /// The identifier is the same for every team. The signing tool registers it
    /// with the Apple ID that signs the app.
    static let appGroupIdentifier = "group.com.ipaside.escapeos"

    /// An opaque, positive handle representing a live sandbox extension.
    struct Handle: Hashable {
        let raw: Int64
    }

    private var liveHandles: Set<Int64> = []
    private let lock = NSLock()

    /// `worse_query` swaps a directory inside the App Group for a symlink for the
    /// duration of the query. That directory belongs to the whole app, so two
    /// escapes must never overlap.
    private static let worseQueryLock = NSLock()

    /// Consume a sandbox extension for `path`.
    /// - Parameters:
    ///   - path: Absolute path inside another app's container.
    ///   - groupIdentifier: Optional app-group identifier for the legacy primitive.
    ///   - isGroup: Whether the target is an App Group container.
    /// - Returns: A `Handle` that must later be passed to `release(_:)`.
    /// - Throws: `SandboxEscapeError` on failure.
    func consume(path: String, groupIdentifier: String? = nil, isGroup: Bool = false) throws -> Handle {
        guard path.hasPrefix("/") else { throw SandboxEscapeError.notAbsolutePath }

        // The group identifier argument belongs to the removed bad_query path.
        // Targets are still Data containers; an App Group target only changes flags.
        _ = groupIdentifier
        let code = consumeWithWorseQuery(path: path, isGroup: isGroup)
        if code >= 0 {
            return register(code)
        }
        throw Self.error(code)
    }

    /// Release a previously consumed handle. Safe to call multiple times.
    func release(_ handle: Handle) {
        lock.lock()
        let removed = liveHandles.remove(handle.raw)
        lock.unlock()
        guard removed != nil else { return }
        worse_query_release(handle.raw)
    }

    /// Number of currently live (consumed, not yet released) handles.
    var liveHandleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveHandles.count
    }

    /// Convenience scoped accessor: consumes a handle, runs `body`, always releases.
    @discardableResult
    func withHandle<T>(
        for path: String,
        groupIdentifier: String? = nil,
        isGroup: Bool = false,
        _ body: (Handle) throws -> T
    ) throws -> T {
        let handle = try consume(path: path, groupIdentifier: groupIdentifier, isGroup: isGroup)
        defer { release(handle) }
        return try body(handle)
    }

    // MARK: - Primitives

    private func consumeWithWorseQuery(path: String, isGroup: Bool) -> Int64 {
        guard let group = Self.resolvedAppGroup() else {
            return -1
        }
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group
        ) else {
            return -1
        }

        // worse_query replaces this directory with a symlink, so it has to exist
        // first. A freshly created group container may not have it yet.
        let caches = root.appendingPathComponent("Library/Caches")
        if !FileManager.default.fileExists(atPath: caches.path) {
            try? FileManager.default.createDirectory(
                at: caches,
                withIntermediateDirectories: true
            )
        }

        Self.worseQueryLock.lock()
        defer { Self.worseQueryLock.unlock() }
        let altFlags = Self.worseQueryAlternateFlags(path: path, isGroup: isGroup)
        return worse_query(path, group, altFlags, false)
    }

    /// The App Group this install is actually signed with.
    ///
    /// iPASide registers `group.com.ipaside.escapeos`. eSign and other custom
    /// certificates replace that with the groups already on their profile
    /// (`group.<TEAM>.*`). Either one works; the identifier has to be one the
    /// signature grants.
    private static func resolvedAppGroup() -> String? {
        var candidates: [String] = []
        let entitled = entitledAppGroups()
        if entitled.contains(appGroupIdentifier) || entitled.isEmpty {
            candidates.append(appGroupIdentifier)
        }
        for group in entitled where !candidates.contains(group) {
            candidates.append(group)
        }
        for group in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
                return group
            }
        }
        return nil
    }

    private static func entitledAppGroups() -> [String] {
        let signed = EscapeOSSignedAppGroups() ?? []
        if !signed.isEmpty {
            return signed
        }
        return groupsFromProvisioningProfile()
    }

    /// App Group identifiers in the embedded provisioning profile.
    private static func groupsFromProvisioningProfile() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else {
            return []
        }
        let blob = data[start.lowerBound..<end.upperBound]
        guard let parsed = try? PropertyListSerialization.propertyList(from: Data(blob), format: nil) as? [String: Any],
              let entitlements = parsed["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else {
            return []
        }
        return groups.filter { $0.hasPrefix("group.") }
    }

    /// iOS 26 needs a different flags value for App Group targets. Targeting an
    /// app's Data container (the usual case) does not.
    private static func worseQueryAlternateFlags(path: String, isGroup: Bool) -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else {
            return false
        }
        return isGroup || path.contains("/var/mobile/Containers/Shared/AppGroup")
    }

    // MARK: - Handles and errors

    private func register(_ raw: Int64) -> Handle {
        lock.lock()
        liveHandles.insert(raw)
        lock.unlock()
        return Handle(raw: raw)
    }

    /// `-1` means this copy of EscapeOS was not signed with the App Group.
    private static func error(_ code: Int64) -> SandboxEscapeError {
        switch code {
        case -1:   return .appGroupUnavailable
        case -255: return .targetMissing
        case -2:   return .resolveFailed
        case -3:   return .queryCreateFailed
        case -4:   return .symlinkFailed
        case -5:   return .outsideSandbox
        case -6:   return .kernelRejected
        default:   return .unknown(code: code)
        }
    }
}
