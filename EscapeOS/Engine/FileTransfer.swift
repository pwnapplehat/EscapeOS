import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
import CXattr
#endif

/// How a copy or move reports progress and learns it should stop (issue #11).
struct TransferObserver {
    /// Told once the total size of the work is known, when it is only discovered part-way (an
    /// archive's contents are known once it has been read, not before).
    var total: (Int64) -> Void = { _ in }
    /// Bytes just written.
    var bytes: (Int64) -> Void = { _ in }
    /// The file being worked on.
    var detail: (String) -> Void = { _ in }
    var isCancelled: () -> Bool = { false }

    static let none = TransferObserver()

    /// Throws `JobCancelled` so the caller unwinds through its normal error path and cleans up.
    func checkCancelled() throws {
        if isCancelled() { throw JobCancelled() }
    }
}

extension TransferObserver {
    /// Report into a running job, and stop when it is cancelled.
    init(job: JobContext) {
        self.init(
            total: { job.meter.setTotals(bytes: $0) },
            bytes: { job.meter.add(bytes: $0) },
            detail: { job.meter.setDetail($0) },
            isCancelled: { job.isCancelled }
        )
    }
}

extension FileService {
    /// How much is read and written at a time. Small enough that memory stays flat on a multi-GB
    /// file and progress moves smoothly; big enough that throughput is not lost to syscalls.
    static let transferChunkBytes = 4 * 1024 * 1024

    /// Copy a file, folder or symlink to a path that does not exist yet, streaming file contents.
    ///
    /// Unlike `FileManager.copyItem`, it reports progress, stops when asked, and never reads a whole
    /// file into memory. A symlink is recreated as a symlink, never followed, so a link that points
    /// at a big folder (or back up the tree) cannot make the copy huge or endless. If anything
    /// fails, including a cancel, the partial destination is removed rather than left half-written.
    ///
    /// - Returns: bytes of file content copied.
    @discardableResult
    func copyTree(
        from source: String,
        to destination: String,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes
    ) throws -> Int64 {
        if existingKind(at: destination) != .none || isSymlink(at: destination) {
            throw FileServiceError.operationFailed("“\((destination as NSString).lastPathComponent)” already exists.")
        }
        var total: Int64 = 0
        do {
            try copyEntry(from: source, to: destination, observer: observer, chunkSize: max(chunkSize, 1), total: &total)
        } catch {
            try? deleteItem(at: destination)
            throw error
        }
        return total
    }

    /// Move to a path that does not exist yet. Renames when it can (instant, no extra space);
    /// otherwise copies and then deletes the original, and only after the copy is complete. If the
    /// original cannot be deleted the copy is removed again, so a failed move never leaves two.
    ///
    /// - Parameter rename: the rename attempt; replaceable so the fallback can be tested.
    @discardableResult
    func moveTree(
        from source: String,
        to destination: String,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes,
        rename attempt: (String, String) -> Bool = { rename($0, $1) == 0 }
    ) throws -> Int64 {
        if existingKind(at: destination) != .none || isSymlink(at: destination) {
            throw FileServiceError.operationFailed("“\((destination as NSString).lastPathComponent)” already exists.")
        }
        guard existingKind(at: source) != .none || isSymlink(at: source) else {
            throw FileServiceError.pathNotFound(source)
        }
        try observer.checkCancelled()
        if attempt(source, destination) { return 0 }

        let copied = try copyTree(from: source, to: destination, observer: observer, chunkSize: chunkSize)
        do {
            try deleteItem(at: source)
        } catch {
            try? deleteItem(at: destination)
            throw FileServiceError.operationFailed(
                "Could not remove the original “\((source as NSString).lastPathComponent)”, so nothing was moved. \(error.localizedDescription)"
            )
        }
        return copied
    }

    /// True for a symlink, including one whose target is gone.
    func isSymlink(at path: String) -> Bool {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
            return false
        }
        return type == FileAttributeType.typeSymbolicLink
    }

    // MARK: - Internals

    private func copyEntry(
        from source: String,
        to destination: String,
        observer: TransferObserver,
        chunkSize: Int,
        total: inout Int64
    ) throws {
        try observer.checkCancelled()
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: source)
        } catch {
            throw mapError(error, path: source)
        }
        let type = attrs[.type] as? FileAttributeType

        if type == FileAttributeType.typeSymbolicLink {
            do {
                let target = try fm.destinationOfSymbolicLink(atPath: source)
                try fm.createSymbolicLink(atPath: destination, withDestinationPath: target)
            } catch {
                throw mapError(error, path: source)
            }
            return
        }

        if type == FileAttributeType.typeDirectory {
            do {
                try fm.createDirectory(atPath: destination, withIntermediateDirectories: false)
            } catch {
                throw mapError(error, path: destination)
            }
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: source).sorted()
            } catch {
                throw mapError(error, path: source)
            }
            for name in names {
                try copyEntry(
                    from: (source as NSString).appendingPathComponent(name),
                    to: (destination as NSString).appendingPathComponent(name),
                    observer: observer,
                    chunkSize: chunkSize,
                    total: &total
                )
            }
            applyAttributes(attrs, to: destination, from: source)
            return
        }

        guard type == FileAttributeType.typeRegular else {
            // Sockets, FIFOs and device nodes have no content to copy.
            return
        }

        observer.detail((source as NSString).lastPathComponent)
        total += try copyFileContents(from: source, to: destination, observer: observer, chunkSize: chunkSize)
        applyAttributes(attrs, to: destination, from: source)
    }

    private func copyFileContents(
        from source: String,
        to destination: String,
        observer: TransferObserver,
        chunkSize: Int
    ) throws -> Int64 {
        guard let input = FileHandle(forReadingAtPath: source) else {
            throw FileServiceError.permissionDenied(source)
        }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination, contents: nil),
              let output = FileHandle(forWritingAtPath: destination) else {
            throw FileServiceError.operationFailed("Could not create “\((destination as NSString).lastPathComponent)”.")
        }
        defer { try? output.close() }

        var copied: Int64 = 0
        while true {
            try observer.checkCancelled()
            let chunk: Data
            do {
                guard let read = try pooled({ try input.read(upToCount: chunkSize) }), !read.isEmpty else { break }
                chunk = read
            } catch {
                throw mapError(error, path: source)
            }
            do {
                try pooled { try output.write(contentsOf: chunk) }
            } catch {
                throw mapError(error, path: destination)
            }
            copied += Int64(chunk.count)
            observer.bytes(Int64(chunk.count))
        }
        return copied
    }

    /// Permissions, modification time and extended attributes, best effort: a copy that lacks them
    /// is still a copy. Extended attributes matter on iOS: a cache file carries
    /// `com.apple.MobileBackup` to stay out of backups, and `FileManager.copyItem`, which this
    /// replaces for large copies, kept it.
    private func applyAttributes(_ attrs: [FileAttributeKey: Any], to path: String, from source: String) {
        copyExtendedAttributes(from: source, to: path)
        var wanted: [FileAttributeKey: Any] = [:]
        if let permissions = attrs[.posixPermissions] { wanted[.posixPermissions] = permissions }
        if let modified = attrs[.modificationDate] { wanted[.modificationDate] = modified }
        guard !wanted.isEmpty else { return }
        try? FileManager.default.setAttributes(wanted, ofItemAtPath: path)
    }

    /// Copy every extended attribute of `source` to `destination`, never following a link.
    /// Failures are ignored: some volumes and some attributes cannot be copied, and the data is what counts.
    func copyExtendedAttributes(from source: String, to destination: String) {
        #if canImport(Darwin)
        let size = listxattr(source, nil, 0, XATTR_NOFOLLOW)
        #else
        let size = llistxattr(source, nil, 0)
        #endif
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        #if canImport(Darwin)
        let listed = listxattr(source, &names, size, XATTR_NOFOLLOW)
        #else
        let listed = llistxattr(source, &names, size)
        #endif
        guard listed > 0 else { return }
        var start = 0
        while start < listed {
            var end = start
            while end < listed && names[end] != 0 { end += 1 }
            let name = String(cString: Array(names[start..<end]) + [0])
            start = end + 1
            #if canImport(Darwin)
            let length = getxattr(source, name, nil, 0, 0, XATTR_NOFOLLOW)
            #else
            let length = lgetxattr(source, name, nil, 0)
            #endif
            guard length >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: length)
            #if canImport(Darwin)
            let got = value.isEmpty ? 0 : getxattr(source, name, &value, length, 0, XATTR_NOFOLLOW)
            guard got >= 0 else { continue }
            _ = setxattr(destination, name, value, got, 0, XATTR_NOFOLLOW)
            #else
            let got = value.isEmpty ? 0 : lgetxattr(source, name, &value, length)
            guard got >= 0 else { continue }
            _ = lsetxattr(destination, name, value, got, 0)
            #endif
        }
    }

    /// Bounds memory per chunk on Apple platforms, where Foundation returns autoreleased objects.
    private func pooled<T>(_ body: () throws -> T) rethrows -> T {
        #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: body)
        #else
        return try body()
        #endif
    }
}
