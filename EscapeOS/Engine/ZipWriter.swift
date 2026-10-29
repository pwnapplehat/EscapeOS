import Foundation
import zlib

/// A single file recorded in a backup archive's manifest.
struct BackupManifestEntry: Codable {
    let path: String
    let size: Int
    let sha256: String
}

enum ZipWriterError: Error, LocalizedError {
    case notOpen
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .notOpen: return "The zip file is not open."
        case .tooLarge(let name): return "“\(name)” is too large for a zip file (4 GB limit)."
        }
    }
}

/// Store-only ZIP writer for backups and Compress. Files are stored uncompressed
/// (DEFLATE adds little for already-compressed app data).
final class ZipWriter {

    private var fileHandle: FileHandle?
    private var centralDirectory: [CentralRecord] = []
    private var offset: UInt64 = 0

    struct CentralRecord {
        let name: String
        let flags: UInt16
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt64
        let dosTime: UInt16
        let dosDate: UInt16
    }

    /// General-purpose flag bit 11: the name is UTF-8. Without it, tools read a name such as
    /// `café.txt` in the local code page and show it garbled.
    private static let utf8NameFlag: UInt16 = 0x0800

    private static func flags(for nameData: [UInt8]) -> UInt16 {
        nameData.contains { $0 > 0x7F } ? utf8NameFlag : 0
    }

    /// Begin writing a new zip at `url`. Any existing file is truncated.
    func begin(at url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        self.fileHandle = handle
        self.centralDirectory = []
        self.offset = 0
    }

    /// Add a file to the archive. `data` is stored uncompressed under `name`.
    func addFile(name: String, data: Data, modified: Date = Date()) throws {
        guard let handle = fileHandle else { throw ZipWriterError.notOpen }
        guard data.count <= Int(UInt32.max) else { throw ZipWriterError.tooLarge(name) }
        let nameData = Array(name.utf8)
        let flags = Self.flags(for: nameData)
        let (dosTime, dosDate) = Self.msdosTimestamp(from: modified)

        var crc: uLong = crc32(0, nil, 0)
        data.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                crc = crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(data.count))
            }
        }

        let localOffset = offset
        let header = Self.localHeader(
            nameData: nameData,
            flags: flags,
            dosTime: dosTime,
            dosDate: dosDate,
            crc: UInt32(truncatingIfNeeded: crc),
            size: UInt32(data.count)
        )

        try handle.write(contentsOf: header)
        try handle.write(contentsOf: data)
        offset += UInt64(header.count + data.count)

        centralDirectory.append(CentralRecord(
            name: name,
            flags: flags,
            crc32: UInt32(truncatingIfNeeded: crc),
            size: UInt32(data.count),
            localHeaderOffset: localOffset,
            dosTime: dosTime,
            dosDate: dosDate
        ))
    }

    /// Add a file by streaming it from disk, so memory stays flat however large it is.
    ///
    /// The local header is written first with the CRC and size still zero, and patched once the
    /// whole file has gone through. That keeps a normal stored entry (no data descriptor, which
    /// some readers cannot handle for stored data) without reading the file twice.
    ///
    /// - Returns: bytes of file content written.
    @discardableResult
    func addFile(
        name: String,
        fromPath path: String,
        modified: Date,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes
    ) throws -> Int64 {
        guard let handle = fileHandle else { throw ZipWriterError.notOpen }
        guard let input = FileHandle(forReadingAtPath: path) else {
            throw FileServiceError.permissionDenied(path)
        }
        defer { try? input.close() }

        let nameData = Array(name.utf8)
        let flags = Self.flags(for: nameData)
        let (dosTime, dosDate) = Self.msdosTimestamp(from: modified)
        let localOffset = offset

        let placeholder = Self.localHeader(nameData: nameData, flags: flags, dosTime: dosTime, dosDate: dosDate, crc: 0, size: 0)
        try handle.write(contentsOf: placeholder)
        offset += UInt64(placeholder.count)

        var crc: uLong = crc32(0, nil, 0)
        var written: UInt64 = 0
        while true {
            try observer.checkCancelled()
            let chunk: Data
            do {
                guard let read = try input.read(upToCount: max(chunkSize, 1)), !read.isEmpty else { break }
                chunk = read
            } catch {
                throw FileServiceError.operationFailed("Could not read “\((path as NSString).lastPathComponent)”: \(error.localizedDescription)")
            }
            written += UInt64(chunk.count)
            guard written <= UInt64(UInt32.max) else { throw ZipWriterError.tooLarge(name) }
            chunk.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    crc = crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(chunk.count))
                }
            }
            try handle.write(contentsOf: chunk)
            offset += UInt64(chunk.count)
            observer.bytes(Int64(chunk.count))
        }

        // Fill in the CRC and sizes the header was written without, then return to the end.
        var patch = Data()
        patch.appendLE(UInt32(truncatingIfNeeded: crc))
        patch.appendLE(UInt32(written))
        patch.appendLE(UInt32(written))
        let end = offset
        try handle.seek(toOffset: localOffset + 14)
        try handle.write(contentsOf: patch)
        try handle.seek(toOffset: end)

        centralDirectory.append(CentralRecord(
            name: name,
            flags: flags,
            crc32: UInt32(truncatingIfNeeded: crc),
            size: UInt32(written),
            localHeaderOffset: localOffset,
            dosTime: dosTime,
            dosDate: dosDate
        ))
        return Int64(written)
    }

    /// Finalize the archive (writes central directory + end record).
    func finish() throws {
        guard let handle = fileHandle else { return }
        let centralStart = offset

        for record in centralDirectory {
            let nameData = Array(record.name.utf8)
            var central = Data()
            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // signature
            central.appendLE(UInt16(20))     // version made by
            central.appendLE(UInt16(20))     // version needed
            central.appendLE(record.flags)   // flags
            central.appendLE(UInt16(0))      // compression
            central.appendLE(record.dosTime)
            central.appendLE(record.dosDate)
            central.appendLE(record.crc32)
            central.appendLE(record.size)    // compressed
            central.appendLE(record.size)    // uncompressed
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0))      // extra
            central.appendLE(UInt16(0))      // comment
            central.appendLE(UInt16(0))      // disk number
            central.appendLE(UInt16(0))      // internal attrs
            central.appendLE(UInt32(0))      // external attrs
            central.appendLE(UInt32(record.localHeaderOffset))
            central.append(contentsOf: nameData)
            try handle.write(contentsOf: central)
            offset += UInt64(central.count)
        }

        let centralSize = offset - centralStart

        var end = Data()
        end.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // EOCD signature
        end.appendLE(UInt16(0))  // disk
        end.appendLE(UInt16(0))  // disk with central
        end.appendLE(UInt16(centralDirectory.count))
        end.appendLE(UInt16(centralDirectory.count))
        end.appendLE(UInt32(centralSize))
        end.appendLE(UInt32(centralStart))
        end.appendLE(UInt16(0))  // comment length
        try handle.write(contentsOf: end)

        try handle.close()
        fileHandle = nil
    }

    /// Close the file without writing a directory, for an archive being thrown away. Safe to call
    /// at any point, and after `finish()`.
    func abandon() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private static func localHeader(
        nameData: [UInt8],
        flags: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        crc: UInt32,
        size: UInt32
    ) -> Data {
        var header = Data()
        header.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // signature
        header.appendLE(UInt16(20))        // version needed
        header.appendLE(flags)             // flags
        header.appendLE(UInt16(0))         // compression = store
        header.appendLE(dosTime)
        header.appendLE(dosDate)
        header.appendLE(crc)
        header.appendLE(size)              // compressed size
        header.appendLE(size)              // uncompressed size
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0))         // extra field length
        header.append(contentsOf: nameData)
        return header
    }

    /// MS-DOS time/date used by ZIP local and central headers.
    private static func msdosTimestamp(from date: Date) -> (UInt16, UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: TimeZone.current, from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let month = c.month ?? 1
        let day = c.day ?? 1
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let second = (c.second ?? 0) / 2
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    /// Most files and bytes one Compress / Share will take, so a runaway folder stops with a clear
    /// message instead of a jetsam kill.
    static let maxFiles = 20_000
    static let maxBytes: Int64 = 2_000_000_000

    /// Pack files and folders into this archive. Directory entries keep their
    /// top-level names (`Caches/foo.plist`). `skipPath` is the zip being written
    /// so a folder compress never includes itself. Symlinks are skipped: following one can loop
    /// back up the tree, and a zip of the links themselves is not what anyone asked for.
    func addItems(
        _ items: [FileItem],
        files: FileService,
        skipPath: String,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes
    ) throws {
        var fileCount = 0
        var byteCount: Int64 = 0
        for item in items {
            try addEntry(
                path: item.path,
                archiveName: item.name,
                files: files,
                skipPath: skipPath,
                observer: observer,
                chunkSize: chunkSize,
                fileCount: &fileCount,
                byteCount: &byteCount
            )
        }
        if fileCount == 0 && centralDirectory.isEmpty {
            throw FileServiceError.operationFailed("Nothing to zip.")
        }
    }

    private func addEntry(
        path: String,
        archiveName: String,
        files: FileService,
        skipPath: String,
        observer: TransferObserver,
        chunkSize: Int,
        fileCount: inout Int,
        byteCount: inout Int64
    ) throws {
        try observer.checkCancelled()
        let standardized = (path as NSString).standardizingPath
        let skip = (skipPath as NSString).standardizingPath
        if standardized == skip || standardized.hasPrefix(skip + "/") {
            return
        }
        let attrs = try files.attributes(at: path)
        let type = attrs[.type] as? FileAttributeType
        if type == FileAttributeType.typeSymbolicLink { return }

        if type == FileAttributeType.typeDirectory {
            let children = try files.list(directory: path)
            if children.isEmpty {
                try addFile(name: archiveName.hasSuffix("/") ? archiveName : archiveName + "/", data: Data())
                return
            }
            for child in children {
                try addEntry(
                    path: child.path,
                    archiveName: archiveName + "/" + child.name,
                    files: files,
                    skipPath: skipPath,
                    observer: observer,
                    chunkSize: chunkSize,
                    fileCount: &fileCount,
                    byteCount: &byteCount
                )
            }
            return
        }
        guard type == FileAttributeType.typeRegular else { return }

        fileCount += 1
        if fileCount > Self.maxFiles {
            throw FileServiceError.operationFailed("Too many files to zip (20,000 limit).")
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        byteCount += size
        if byteCount > Self.maxBytes {
            throw FileServiceError.operationFailed("Zip would be larger than 2 GB.")
        }
        observer.detail((path as NSString).lastPathComponent)
        try addFile(
            name: archiveName,
            fromPath: path,
            modified: (attrs[.modificationDate] as? Date) ?? Date(),
            observer: observer,
            chunkSize: chunkSize
        )
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
