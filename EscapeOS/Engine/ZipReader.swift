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

    private let data: Data
    private(set) var entries: [String: ZipMember] = [:]

    init(url: URL) throws {
        self.data = try Data(contentsOf: url)
        try parseCentralDirectory()
    }

    init(data: Data) throws {
        self.data = data
        try parseCentralDirectory()
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

    func readEntry(_ entry: ZipMember, password: String? = nil) throws -> Data {
        let localOffset = entry.localHeaderOffset
        guard localOffset + 30 <= data.count else {
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
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadEnd <= data.count else {
            throw ZipReaderError.invalidArchive("Truncated payload for \(entry.name)")
        }

        let stored = data.subdata(in: payloadStart..<payloadEnd)
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
            output.reserveCapacity(max(expected, 64))
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

    private func parseCentralDirectory() throws {
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

        let centralSize = Int(data.readUInt32(at: eocd + 12))
        let centralOffset = Int(data.readUInt32(at: eocd + 16))
        guard centralOffset >= 0, centralOffset + centralSize <= data.count else {
            throw ZipReaderError.invalidArchive("Central directory out of range")
        }

        var offset = centralOffset
        let end = centralOffset + centralSize
        var parsed: [String: ZipMember] = [:]

        while offset + 46 <= end {
            let sig = data.readUInt32(at: offset)
            guard sig == 0x02014b50 else { break }

            let flags = data.readUInt16(at: offset + 8)
            let compression = Int(data.readUInt16(at: offset + 10))
            let dosTime = data.readUInt16(at: offset + 12)
            let crc = data.readUInt32(at: offset + 16)
            let compressed = Int(data.readUInt32(at: offset + 20))
            let uncompressed = Int(data.readUInt32(at: offset + 24))
            let nameLen = Int(data.readUInt16(at: offset + 28))
            let extraLen = Int(data.readUInt16(at: offset + 30))
            let commentLen = Int(data.readUInt16(at: offset + 32))
            let localHeaderOffset = Int(data.readUInt32(at: offset + 42))

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else {
                throw ZipReaderError.invalidArchive("Truncated entry name")
            }
            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
            guard let name else {
                throw ZipReaderError.invalidArchive("Unreadable entry name")
            }

            let extraStart = nameEnd
            let extraEnd = extraStart + extraLen
            let extra = extraEnd <= data.count ? data.subdata(in: extraStart..<extraEnd) : Data()
            let aes = Self.parseAESExtra(extra)

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

            offset = nameEnd + extraLen + commentLen
        }

        guard !parsed.isEmpty else {
            throw ZipReaderError.invalidArchive("No entries found")
        }
        entries = parsed
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
    func readUInt16(at offset: Int) -> UInt16 {
        let slice = subdata(in: offset..<(offset + 2))
        return slice.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let slice = subdata(in: offset..<(offset + 4))
        return slice.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
}
