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
    /// A file could not be read (or changed size while it was read). Whatever had been written for
    /// it is taken back out of the archive, so a caller may skip the file and carry on.
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notOpen: return "The zip file is not open."
        case .tooLarge(let name): return "“\(name)” is too large for a zip file."
        case .unreadable(let message): return message
        }
    }
}

/// Store-only ZIP writer for backups and Compress. Files are stored uncompressed
/// (DEFLATE adds little for already-compressed app data).
///
/// Archives of any size are written: past 65,535 entries, or a file, offset or directory of 4 GB,
/// the ZIP64 records are added (and only then, so a small archive is a plain zip every tool opens).
final class ZipWriter {

    private var fileHandle: FileHandle?
    private var centralDirectory: [CentralRecord] = []
    private var offset: UInt64 = 0

    /// A size or offset at or above this is written in ZIP64 form. The format's own limit; a test
    /// lowers it to exercise the ZIP64 records without writing 4 GB.
    var zip64Threshold: UInt64 = 0xFFFF_FFFF
    /// An entry count at or above this needs the ZIP64 end record. The format's limit, lowered by tests.
    var zip64EntryLimit: Int = 0xFFFF

    private var threshold: UInt64 { min(zip64Threshold, 0xFFFF_FFFF) }
    private var entryLimit: Int { min(zip64EntryLimit, 0xFFFF) }

    struct CentralRecord {
        let name: String
        let flags: UInt16
        let crc32: UInt32
        let size: UInt64
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
        let nameData = Array(name.utf8)
        let flags = Self.flags(for: nameData)
        let (dosTime, dosDate) = Self.msdosTimestamp(from: modified)
        let size = UInt64(data.count)

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
            size: size,
            zip64: size >= threshold
        )

        try handle.write(contentsOf: header)
        try handle.write(contentsOf: data)
        offset += UInt64(header.count + data.count)

        centralDirectory.append(CentralRecord(
            name: name,
            flags: flags,
            crc32: UInt32(truncatingIfNeeded: crc),
            size: size,
            localHeaderOffset: localOffset,
            dosTime: dosTime,
            dosDate: dosDate
        ))
    }

    /// Add a file by streaming it from disk, so memory stays flat however large it is.
    ///
    /// The local header is written first with the CRC and size still zero, and patched once the
    /// whole file has gone through. That keeps a normal stored entry (no data descriptor, which
    /// some readers cannot handle for stored data) without reading the file twice. A file already
    /// at the ZIP64 size when it is opened gets the ZIP64 form of the header.
    ///
    /// If the file cannot be read part-way, or grows past what its header was written for, what was
    /// written for it is cut back out of the archive and `ZipWriterError.unreadable` is thrown.
    ///
    /// - Parameter onChunk: given every chunk as it is written, in order, so a caller can hash the
    ///   bytes that really went into the archive without reading the file a second time.
    /// - Returns: bytes of file content written.
    @discardableResult
    func addFile(
        name: String,
        fromPath path: String,
        modified: Date,
        observer: TransferObserver = .none,
        chunkSize: Int = FileService.transferChunkBytes,
        onChunk: ((Data) -> Void)? = nil
    ) throws -> Int64 {
        guard let handle = fileHandle else { throw ZipWriterError.notOpen }
        guard let input = FileHandle(forReadingAtPath: path) else {
            throw ZipWriterError.unreadable("Could not read “\((path as NSString).lastPathComponent)”.")
        }
        defer { try? input.close() }

        let nameData = Array(name.utf8)
        let flags = Self.flags(for: nameData)
        let (dosTime, dosDate) = Self.msdosTimestamp(from: modified)
        let localOffset = offset
        let startSize = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        let zip64 = startSize >= threshold

        let placeholder = Self.localHeader(nameData: nameData, flags: flags, dosTime: dosTime, dosDate: dosDate, crc: 0, size: 0, zip64: zip64)
        try handle.write(contentsOf: placeholder)
        offset += UInt64(placeholder.count)

        /// Take back everything written for this file.
        func rollBack() {
            try? handle.truncate(atOffset: localOffset)
            try? handle.seek(toOffset: localOffset)
            offset = localOffset
        }

        var crc: uLong = crc32(0, nil, 0)
        var written: UInt64 = 0
        var more = true
        while more {
            more = try withAutoreleasePool { () throws -> Bool in
                try observer.checkCancelled()
                let chunk: Data
                do {
                    guard let read = try input.read(upToCount: max(chunkSize, 1)), !read.isEmpty else { return false }
                    chunk = read
                } catch {
                    rollBack()
                    throw ZipWriterError.unreadable("Could not read “\((path as NSString).lastPathComponent)”: \(error.localizedDescription)")
                }
                written += UInt64(chunk.count)
                if !zip64, written >= threshold {
                    rollBack()
                    throw ZipWriterError.unreadable("“\((path as NSString).lastPathComponent)” grew while it was being read.")
                }
                chunk.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        crc = crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(chunk.count))
                    }
                }
                try handle.write(contentsOf: chunk)
                offset += UInt64(chunk.count)
                observer.bytes(Int64(chunk.count))
                onChunk?(chunk)
                return true
            }
        }

        // Fill in the CRC and sizes the header was written without, then return to the end.
        let end = offset
        var crcPatch = Data()
        crcPatch.appendLE(UInt32(truncatingIfNeeded: crc))
        try handle.seek(toOffset: localOffset + 14)
        try handle.write(contentsOf: crcPatch)
        var sizes = Data()
        if zip64 {
            // The 32-bit sizes stay at the marker value; the real ones are in the extra field.
            sizes.appendLE(written)
            sizes.appendLE(written)
            try handle.seek(toOffset: localOffset + 30 + UInt64(nameData.count) + 4)
        } else {
            sizes.appendLE(UInt32(written))
            sizes.appendLE(UInt32(written))
        }
        try handle.write(contentsOf: sizes)
        try handle.seek(toOffset: end)

        centralDirectory.append(CentralRecord(
            name: name,
            flags: flags,
            crc32: UInt32(truncatingIfNeeded: crc),
            size: written,
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
        let limit = threshold

        // Written in blocks, not one record at a time: a backup can hold hundreds of thousands.
        var block = Data()
        func flush() throws {
            guard !block.isEmpty else { return }
            try handle.write(contentsOf: block)
            offset += UInt64(block.count)
            block.removeAll(keepingCapacity: true)
        }

        for record in centralDirectory {
            let nameData = Array(record.name.utf8)
            let bigSize = record.size >= limit
            let bigOffset = record.localHeaderOffset >= limit
            var extra = Data()
            if bigSize || bigOffset {
                extra.appendLE(UInt16(0x0001))
                extra.appendLE(UInt16((bigSize ? 16 : 0) + (bigOffset ? 8 : 0)))
                if bigSize {
                    extra.appendLE(record.size)   // uncompressed
                    extra.appendLE(record.size)   // compressed
                }
                if bigOffset { extra.appendLE(record.localHeaderOffset) }
            }
            let sizeField = bigSize ? UInt32.max : UInt32(record.size)
            let offsetField = bigOffset ? UInt32.max : UInt32(record.localHeaderOffset)

            block.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // signature
            block.appendLE(UInt16(extra.isEmpty ? 20 : 45))     // version made by
            block.appendLE(UInt16(extra.isEmpty ? 20 : 45))     // version needed
            block.appendLE(record.flags)   // flags
            block.appendLE(UInt16(0))      // compression
            block.appendLE(record.dosTime)
            block.appendLE(record.dosDate)
            block.appendLE(record.crc32)
            block.appendLE(sizeField)      // compressed
            block.appendLE(sizeField)      // uncompressed
            block.appendLE(UInt16(nameData.count))
            block.appendLE(UInt16(extra.count))
            block.appendLE(UInt16(0))      // comment
            block.appendLE(UInt16(0))      // disk number
            block.appendLE(UInt16(0))      // internal attrs
            block.appendLE(UInt32(0))      // external attrs
            block.appendLE(offsetField)
            block.append(contentsOf: nameData)
            block.append(extra)
            if block.count >= 1 << 20 { try flush() }
        }
        try flush()

        let centralSize = offset - centralStart
        let count = centralDirectory.count
        let needsZip64End = count >= entryLimit || centralSize >= limit || centralStart >= limit

        if needsZip64End {
            let zip64EndOffset = offset
            var end64 = Data()
            end64.append(contentsOf: [0x50, 0x4B, 0x06, 0x06]) // ZIP64 end of central directory
            end64.appendLE(UInt64(44))      // size of the rest of this record
            end64.appendLE(UInt16(45))      // version made by
            end64.appendLE(UInt16(45))      // version needed
            end64.appendLE(UInt32(0))       // disk
            end64.appendLE(UInt32(0))       // disk with central
            end64.appendLE(UInt64(count))   // entries on this disk
            end64.appendLE(UInt64(count))   // entries in total
            end64.appendLE(centralSize)
            end64.appendLE(centralStart)
            end64.append(contentsOf: [0x50, 0x4B, 0x06, 0x07]) // ZIP64 end locator
            end64.appendLE(UInt32(0))       // disk with the ZIP64 end record
            end64.appendLE(zip64EndOffset)
            end64.appendLE(UInt32(1))       // disks in total
            try handle.write(contentsOf: end64)
            offset += UInt64(end64.count)
        }

        var end = Data()
        end.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // EOCD signature
        end.appendLE(UInt16(0))  // disk
        end.appendLE(UInt16(0))  // disk with central
        end.appendLE(UInt16(min(count, 0xFFFF)))
        end.appendLE(UInt16(min(count, 0xFFFF)))
        end.appendLE(UInt32(min(centralSize, 0xFFFF_FFFF)))
        end.appendLE(UInt32(min(centralStart, 0xFFFF_FFFF)))
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

    /// The local file header. With `zip64`, the sizes are in an extra field and the 32-bit fields
    /// hold the marker value; `size` is what the extra field starts out holding.
    private static func localHeader(
        nameData: [UInt8],
        flags: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        crc: UInt32,
        size: UInt64,
        zip64: Bool
    ) -> Data {
        var header = Data()
        header.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // signature
        header.appendLE(UInt16(zip64 ? 45 : 20))   // version needed
        header.appendLE(flags)             // flags
        header.appendLE(UInt16(0))         // compression = store
        header.appendLE(dosTime)
        header.appendLE(dosDate)
        header.appendLE(crc)
        header.appendLE(zip64 ? UInt32.max : UInt32(size))   // compressed size
        header.appendLE(zip64 ? UInt32.max : UInt32(size))   // uncompressed size
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(zip64 ? 20 : 0))   // extra field length
        header.append(contentsOf: nameData)
        if zip64 {
            header.appendLE(UInt16(0x0001))
            header.appendLE(UInt16(16))
            header.appendLE(size)   // uncompressed
            header.appendLE(size)   // compressed
        }
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
    /// message instead of a jetsam kill. (Backups have no such limit: they stream, and the archive
    /// is read back by this app, which handles ZIP64. Compress and Share Zip are read by other
    /// tools and by Extract, which still reads each file into memory.)
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
    mutating func appendLE(_ value: UInt64) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
