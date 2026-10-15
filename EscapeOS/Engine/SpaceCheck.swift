import Foundation

/// A check, made before an operation starts, that its result will fit on disk.
///
/// Issue #3: a large zip ran for a long time and only then failed for lack of space, after the
/// person had waited with no hint it could not finish. Sizes are known up front for copy, zip,
/// duplicate, import and backup, so the answer can be given immediately and silently when
/// there is room.
enum SpaceCheck {
    /// Kept free on top of the operation's own size: temp files, zip directories, and the room iOS
    /// itself needs to keep working.
    static let reserveBytes: Int64 = 32 * 1024 * 1024

    enum Verdict: Equatable {
        case enough
        case notEnough(needed: Int64, available: Int64)
        /// Free space could not be read. The operation goes ahead; it fails on its own if it must.
        case unknown
    }

    static func verdict(needed: Int64, available: Int64?) -> Verdict {
        guard needed > 0 else { return .enough }
        guard let available else { return .unknown }
        let (required, overflow) = needed.addingReportingOverflow(reserveBytes)
        if !overflow && available >= required { return .enough }
        return .notEnough(needed: needed, available: available)
    }

    static func message(for operation: String, needed: Int64, available: Int64) -> String {
        "Not enough free space to \(operation). It needs about \(format(needed)) plus some working room, and only \(format(max(available, 0))) is free on this device. Free up space and try again."
    }

    private static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Throws a readable error when `needed` bytes will not fit on the volume holding `path`.
    static func require(
        _ needed: Int64,
        at path: String,
        for operation: String,
        files: FileService = FileService()
    ) throws {
        if case .notEnough(let need, let available) = verdict(needed: needed, available: files.availableCapacity(at: path)) {
            throw FileServiceError.insufficientSpace(message(for: operation, needed: need, available: available))
        }
    }
}

extension FileService {
    /// Free bytes on the volume holding `path`, or nil when it cannot be read.
    func availableCapacity(at path: String) -> Int64? {
        #if canImport(UIKit)
        // Counts space iOS can reclaim (purgeable caches), which is what a large write can use.
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        #endif
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }

    /// Total bytes of regular files under `path`, or of the file itself. Symlinks count as the
    /// link, never their target, and are not followed.
    func treeBytes(at path: String) -> Int64 {
        let fm = FileManager.default
        guard let rootType = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return 0 }
        if rootType != FileAttributeType.typeDirectory {
            return ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let walker = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let relative = walker.nextObject() as? String {
            let full = (path as NSString).appendingPathComponent(relative)
            guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
            if (attrs[.type] as? FileAttributeType) == FileAttributeType.typeRegular {
                total += (attrs[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    func totalBytes(of items: [FileItem]) -> Int64 {
        items.reduce(into: Int64(0)) { sum, item in
            sum += item.isDirectory ? treeBytes(at: item.path) : item.size
        }
    }
}
