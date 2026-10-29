import Foundation
import zlib

/// A single entry inside a ZIP archive.
struct ZipMember {
    let name: String
    let compressedSize: Int
    let uncompressedSize: Int
    let crc32: UInt32
    let localHeaderOffset: Int
    let compression: Int
    let flags: UInt16
    let dosTime: UInt16
    let aes: ZipAESInfo?

    var isEncrypted: Bool { flags & 0x1 != 0 || compression == 99 || aes != nil }
    var usesDataDescriptor: Bool { flags & 0x8 != 0 }
}

/// Errors when reading ZIP archives.
enum ZipReaderError: Error, LocalizedError {
    case invalidArchive(String)
    case entryNotFound(String)
    case checksumMismatch(String)
    case unsupportedCompression(String)
    case passwordRequired
    case wrongPassword

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let m): return "Invalid zip: \(m)"
        case .entryNotFound(let n): return "Missing file in archive: \(n)"
        case .checksumMismatch(let n): return "Checksum failed for \(n)"
        case .unsupportedCompression(let n): return "Unsupported compression for \(n)"
        case .passwordRequired: return "This archive is password-protected."
        case .wrongPassword: return "Wrong archive password."
        }
    }
}

/// ZIP reader for store (method 0) and deflate (method 8). Used by backup restore and Extract.
final class ZipReader {

    /// The most one entry may hold when it has to be read into memory whole.
    static let maxEntryBytes = 2_000_000_000

    private let data: Data
    private(set) var entries: [String: ZipMember] = [:]

    /// - Parameter only: read just these entries out of the directory, so a caller that wants one
    ///   small file of a big archive (a backup's `backup.json`) does not build a record for every
    ///   file in it.
    ///
    /// The file is mapped, not read: a backup can be larger than the memory this app may use.
    init(url: URL, only: Set<String>? = nil) throws {
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        try parseCentralDirectory(only: only)
    }

    init(data: Data) throws {
        self.data = data
        try parseCentralDirectory(only: nil)
    }

    func entryNames() -> [String] {
        entries.keys.sorted()
    }

    var needsPassword: Bool {
        entries.values.contains(where: \.isEncrypted)
    }

    func readEntry(named name: String, password: String? = nil) throws -> Data {
        guard let entry = entries[name] else {
            throw ZipReaderError.entryNotFound(name)
        }
        return try readEntry(entry, password: password)
    }

    /// Where an entry's bytes are in the archive, and the method its local header says it uses.
    private func payloadLocation(of entry: ZipMember) throws -> (start: Int, end: Int, compression: Int) {
        let localOffset = entry.localHeaderOffset
        guard localOffset >= 0, localOffset <= data.count - 30 else {
            throw ZipReaderError.invalidArchive("Truncated local header for \(entry.name)")
        }

        let sig = data.readUInt32(at: localOffset)
        guard sig == 0x04034b50 else {
            throw ZipReaderError.invalidArchive("Bad local header for \(entry.name)")
        }

        let compression = Int(data.readUInt16(at: localOffset + 8))
        let nameLen = Int(data.readUInt16(at: localOffset + 26))
        let extraLen = Int(data.readUInt16(at: localOffset + 28))
        let payloadStart = localOffset + 30 + nameLen + extraLen
        let (payloadEnd, overflow) = payloadStart.addingReportingOverflow(entry.compressedSize)
        guard !overflow, payloadEnd <= data.count else {
            throw ZipReaderError.invalidArchive("Truncated payload for \(entry.name)")
        }
        return (payloadStart, payloadEnd, compression)
    }

    /// True when the entry can be read in pieces with `streamEntry`: stored and not encrypted. A
    /// backup always is; a deflated entry has to be inflated whole, so it is read with `readEntry`.
    func canStream(_ entry: ZipMember) -> Bool {
        guard !entry.isEncrypted, let location = try? payloadLocation(of: entry) else { return false }
        return location.compression == 0
    }

    /// Hand a stored, unencrypted entry's bytes to `body` in order, in pieces of `chunkSize`, so a
    /// file of any size is read with flat memory. The entry's CRC and size are checked at the end,
    /// so `body` has seen all of a damaged entry before this throws: discard what it wrote.
    func streamEntry(_ entry: ZipMember, chunkSize: Int = 4 * 1024 * 1024, body: (Data) throws -> Void) throws {
        let location = try payloadLocation(of: entry)
        guard !entry.isEncrypted, location.compression == 0 else {
            throw ZipReaderError.unsupportedCompression(entry.name)
        }
        var crc: uLong = crc32(0, nil, 0)
        var position = location.start
        let step = max(chunkSize, 1)
        while position < location.end {
            let next = min(position + step, location.end)
            try withAutoreleasePool {
                let piece = data.subdata(in: position..<next)
                piece.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        crc = crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(piece.count))
                    }
                }
                try body(piece)
            }
            position = next
        }
        if entry.crc32 != 0, UInt32(truncatingIfNeeded: crc) != entry.crc32 {
            throw ZipReaderError.checksumMismatch(entry.name)
        }
        if entry.uncompressedSize > 0, location.end - location.start != entry.uncompressedSize {
            throw ZipReaderError.invalidArchive("Size mismatch for \(entry.name)")
        }
    }

    func readEntry(_ entry: ZipMember, password: String? = nil) throws -> Data {
        // The whole entry is held in memory; a size from a ZIP64 header can be far past that.
        guard entry.compressedSize <= Self.maxEntryBytes, entry.uncompressedSize <= Self.maxEntryBytes else {
            throw FileServiceError.operationFailed("“\(entry.name)” is larger than 2 GB, too large to read into memory at once.")
        }
        let location = try payloadLocation(of: entry)
        let compression = location.compression
        let stored = data.subdata(in: location.start..<location.end)
        var working = stored
        var method = compression
        if entry.isEncrypted {
            guard let password, !password.isEmpty else {
                throw ZipReaderError.passwordRequired
            }
            if let aes = entry.aes {
                working = try ZipPassword.decryptAES(ciphertext: stored, password: password, aes: aes)
                method = aes.compression
            } else if compression == 99 {
                throw ZipReaderError.invalidArchive("AES extra field missing for \(entry.name)")
            } else {
                working = try ZipPassword.decryptZipCrypto(
                    ciphertext: stored,
                    password: password,
                    crc32: entry.crc32,
                    dosTime: entry.dosTime,
                    usesDataDescriptor: entry.usesDataDescriptor
                )
            }
        }

        let payload: Data
        switch method {
        case 0:
            payload = working
        case 8:
            payload = try Self.inflateRaw(working, expected: entry.uncompressedSize)
        default:
            throw ZipReaderError.unsupportedCompression(entry.name)
        }

        if entry.crc32 != 0 {
            var crc: uLong = crc32(0, nil, 0)
            payload.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    crc = crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(payload.count))
                }
            }
            guard UInt32(truncatingIfNeeded: crc) == entry.crc32 else {
                throw ZipReaderError.checksumMismatch(entry.name)
            }
        }
        if entry.uncompressedSize > 0, payload.count != entry.uncompressedSize {
            throw ZipReaderError.invalidArchive("Size mismatch for \(entry.name)")
        }
        return payload
    }

    /// Unpack every entry under `destDir`. Rejects `..` paths.
    func extract(into destDir: String, files: FileService, password: String? = nil, observer: TransferObserver = .none) throws {
        if needsPassword, password == nil || password?.isEmpty == true {
            throw ZipReaderError.passwordRequired
        }
        let root = (destDir as NSString).standardizingPath
        try files.createDirectory(at: root)
        var fileCount = 0
        var byteCount: Int64 = 0
        if entries.values.contains(where: { $0.uncompressedSize > Self.maxEntryBytes || $0.compressedSize > Self.maxEntryBytes }) {
            throw FileServiceError.operationFailed("Extracted data would be larger than 2 GB.")
        }
        observer.total(entries.values.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) })
        for name in entryNames() {
            try observer.checkCancelled()
            if name.isEmpty { continue }
            let resolved = try ArchiveEntryPath.resolve(name, under: destDir)
            if resolved.isDirectory {
                try files.createDirectory(at: resolved.path)
                continue
            }
            let payload = try readEntry(named: name, password: password)
            fileCount += 1
            byteCount += Int64(payload.count)
            if fileCount > 20_000 {
                throw FileServiceError.operationFailed("Too many files to extract (20,000 limit).")
            }
            if byteCount > 2_000_000_000 {
                throw FileServiceError.operationFailed("Extracted data would be larger than 2 GB.")
            }
            observer.detail((resolved.path as NSString).lastPathComponent)
            try files.writeFile(data: payload, to: resolved.path)
            observer.bytes(Int64(payload.count))
        }
    }

    private static func inflateRaw(_ input: Data, expected: Int) throws -> Data {
        if input.isEmpty { return Data() }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ZipReaderError.unsupportedCompression("deflate")
        }
        defer { inflateEnd(&stream) }

        return try input.withUnsafeBytes { raw in
            guard let inBase = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw ZipReaderError.invalidArchive("Empty deflate stream")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(input.count)

            var output = Data()
            output.reserveCapacity(min(max(expected, 64), 1 << 28))
            let chunk = 64 * 1024
            var buffer = [Bytef](repeating: 0, count: chunk)
            var status: Int32 = Z_OK
            repeat {
                buffer.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    let produced = chunk - Int(stream.avail_out)
                    if produced > 0, let base = buf.baseAddress {
                        output.append(base, count: produced)
                    }
                }
                if output.count > 2_000_000_000 {
                    throw FileServiceError.operationFailed("Extracted data would be larger than 2 GB.")
                }
                if status == Z_STREAM_ERROR || status == Z_DATA_ERROR || status == Z_MEM_ERROR {
                    throw ZipReaderError.invalidArchive("Deflate failed")
                }
            } while status == Z_OK
            guard status == Z_STREAM_END else {
                throw ZipReaderError.invalidArchive("Truncated deflate stream")
            }
            return output
        }
    }

    private func parseCentralDirectory(only: Set<String>?) throws {
        guard data.count >= 22 else {
            throw ZipReaderError.invalidArchive("File too small")
        }

        var eocdOffset: Int?
        let searchStart = max(0, data.count - 65557)
        for i in stride(from: data.count - 22, through: searchStart, by: -1) {
            if data.readUInt32(at: i) == 0x06054b50 {
                eocdOffset = i
                break
            }
        }
        guard let eocd = eocdOffset else {
            throw ZipReaderError.invalidArchive("End-of-central-directory not found")
        }

        var centralSize = Int(data.readUInt32(at: eocd + 12))
        var centralOffset = Int(data.readUInt32(at: eocd + 16))
        // A marker value in any field of the end record means the real one is in the ZIP64 end
        // record, which the locator just before it points to.
        let countField = data.readUInt16(at: eocd + 10)
        let locator = eocd - 20
        let hasLocator = locator >= 0 && data.readUInt32(at: locator) == 0x07064b50
        // A count of exactly 0xFFFF is also an ordinary count (other tools write one with no ZIP64
        // records), so only the size and offset markers, or a locator that is there, demand them.
        if centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF || (countField == 0xFFFF && hasLocator) {
            guard hasLocator else {
                throw ZipReaderError.invalidArchive("ZIP64 end locator not found")
            }
            guard let end64 = Int(exactly: data.readUInt64(at: locator + 8)),
                  end64 >= 0, end64 <= data.count - 56,
                  data.readUInt32(at: end64) == 0x06064b50 else {
                throw ZipReaderError.invalidArchive("ZIP64 end record not found")
            }
            guard let size64 = Int(exactly: data.readUInt64(at: end64 + 40)),
                  let offset64 = Int(exactly: data.readUInt64(at: end64 + 48)) else {
                throw ZipReaderError.invalidArchive("Central directory out of range")
            }
            centralSize = size64
            centralOffset = offset64
        }
        let (centralEnd, overflow) = centralOffset.addingReportingOverflow(centralSize)
        guard centralOffset >= 0, centralSize >= 0, !overflow, centralEnd <= data.count else {
            throw ZipReaderError.invalidArchive("Central directory out of range")
        }

        var offset = centralOffset
        let end = centralEnd
        var parsed: [String: ZipMember] = [:]

        while offset + 46 <= end {
            let sig = data.readUInt32(at: offset)
            guard sig == 0x02014b50 else { break }

            let flags = data.readUInt16(at: offset + 8)
            let compression = Int(data.readUInt16(at: offset + 10))
            let dosTime = data.readUInt16(at: offset + 12)
            let crc = data.readUInt32(at: offset + 16)
            let compressed32 = data.readUInt32(at: offset + 20)
            let uncompressed32 = data.readUInt32(at: offset + 24)
            let nameLen = Int(data.readUInt16(at: offset + 28))
            let extraLen = Int(data.readUInt16(at: offset + 30))
            let commentLen = Int(data.readUInt16(at: offset + 32))
            let localHeaderOffset32 = data.readUInt32(at: offset + 42)

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd + extraLen <= data.count else {
                throw ZipReaderError.invalidArchive("Truncated entry name")
            }
            let next = nameEnd + extraLen + commentLen

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
            guard let name else {
                throw ZipReaderError.invalidArchive("Unreadable entry name")
            }
            if let only, !only.contains(name) {
                offset = next
                continue
            }

            let extra = extraLen > 0 ? data.subdata(in: nameEnd..<(nameEnd + extraLen)) : Data()
            let aes = Self.parseAESExtra(extra)

            // A size or offset at the marker value is held in full in the ZIP64 extra field, in
            // this order, and only the ones that need it are there.
            var uncompressed = Int(uncompressed32)
            var compressed = Int(compressed32)
            var localHeaderOffset = Int(localHeaderOffset32)
            if uncompressed32 == 0xFFFF_FFFF || compressed32 == 0xFFFF_FFFF || localHeaderOffset32 == 0xFFFF_FFFF {
                var wide = Self.zip64Values(in: extra)[...]
                func take() throws -> Int {
                    guard let value = wide.popFirst(), let narrowed = Int(exactly: value) else {
                        throw ZipReaderError.invalidArchive("Bad ZIP64 data for \(name)")
                    }
                    return narrowed
                }
                if uncompressed32 == 0xFFFF_FFFF { uncompressed = try take() }
                if compressed32 == 0xFFFF_FFFF { compressed = try take() }
                if localHeaderOffset32 == 0xFFFF_FFFF { localHeaderOffset = try take() }
            }

            parsed[name] = ZipMember(
                name: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                crc32: crc,
                localHeaderOffset: localHeaderOffset,
                compression: compression,
                flags: flags,
                dosTime: dosTime,
                aes: aes
            )

            offset = next
        }

        guard !parsed.isEmpty else {
            throw ZipReaderError.invalidArchive("No entries found")
        }
        entries = parsed
    }

    /// The 8-byte values in a ZIP64 extra field (id 0x0001), in order.
    private static func zip64Values(in extra: Data) -> [UInt64] {
        var i = 0
        while i + 4 <= extra.count {
            let id = extra.readUInt16(at: i)
            let size = Int(extra.readUInt16(at: i + 2))
            let bodyStart = i + 4
            let bodyEnd = bodyStart + size
            guard bodyEnd <= extra.count else { break }
            if id == 0x0001 {
                var values: [UInt64] = []
                var at = bodyStart
                while at + 8 <= bodyEnd {
                    values.append(extra.readUInt64(at: at))
                    at += 8
                }
                return values
            }
            i = bodyEnd
        }
        return []
    }

    private static func parseAESExtra(_ extra: Data) -> ZipAESInfo? {
        var i = 0
        while i + 4 <= extra.count {
            let id = extra.readUInt16(at: i)
            let size = Int(extra.readUInt16(at: i + 2))
            let bodyStart = i + 4
            let bodyEnd = bodyStart + size
            guard bodyEnd <= extra.count else { break }
            if id == 0x9901, size >= 7 {
                let vendor = extra.subdata(in: (bodyStart + 2)..<(bodyStart + 4))
                if vendor == Data([0x41, 0x45]) { // "AE"
                    let strength = extra[bodyStart + 4]
                    let method = Int(extra.readUInt16(at: bodyStart + 5))
                    let bits: Int
                    switch strength {
                    case 1: bits = 128
                    case 2: bits = 192
                    case 3: bits = 256
                    default: return nil
                    }
                    return ZipAESInfo(keyBits: bits, compression: method)
                }
            }
            i = bodyEnd
        }
        return nil
    }
}

private extension Data {
    // Read straight from the bytes: these run for every field of every entry, and a backup can
    // have hundreds of thousands of entries.
    func readUInt16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(readUInt16(at: offset)) | UInt32(readUInt16(at: offset + 2)) << 16
    }

    func readUInt64(at offset: Int) -> UInt64 {
        UInt64(readUInt32(at: offset)) | UInt64(readUInt32(at: offset + 4)) << 32
    }
}
