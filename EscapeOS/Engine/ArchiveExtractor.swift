import Foundation

/// Detects and unpacks zip, tar, gzip, bzip2, xz, 7z, lz4, lzma, tgz, and deb
/// using vendored SWCompression, plus our password-capable ZipReader.
enum ArchiveExtractor {

    enum Kind {
        case zip
        case sevenZip
        case tar
        case gzip
        case bzip2
        case xz
        case lz4
        case lzma
        case deb
        case rar
        case unknown
    }

    static func kind(of data: Data, name: String) -> Kind {
        if data.count >= 6, data.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if data.count >= 4, data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if data.count >= 4, data.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if data.count >= 4, data.starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if data.count >= 7, data.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if data.count >= 2, data[0] == 0x1F, data[1] == 0x8B { return .gzip }
        if data.count >= 3, data[0] == 0x42, data[1] == 0x5A, data[2] == 0x68 { return .bzip2 }
        if data.count >= 6, data.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if data.count >= 4, data.starts(with: [0x04, 0x22, 0x4D, 0x18]) { return .lz4 }
        if data.count >= 8, data.starts(with: Array("!<arch>\n".utf8)) { return .deb }
        if isTar(data) { return .tar }
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") || lower.hasSuffix(".ipa") || lower.hasSuffix(".apk")
            || lower.hasSuffix(".jar") { return .zip }
        if lower.hasSuffix(".7z") { return .sevenZip }
        if lower.hasSuffix(".tar") { return .tar }
        if lower.hasSuffix(".gz") || lower.hasSuffix(".tgz") { return .gzip }
        if lower.hasSuffix(".bz2") || lower.hasSuffix(".tbz") || lower.hasSuffix(".tbz2") { return .bzip2 }
        if lower.hasSuffix(".xz") || lower.hasSuffix(".txz") { return .xz }
        if lower.hasSuffix(".lz4") { return .lz4 }
        if lower.hasSuffix(".lzma") { return .lzma }
        if lower.hasSuffix(".deb") { return .deb }
        if lower.hasSuffix(".rar") { return .rar }
        return .unknown
    }

    static func archiveNeedsPassword(_ data: Data, name: String) -> Bool {
        switch kind(of: data, name: name) {
        case .zip:
            return (try? ZipReader(data: data).needsPassword) == true
        case .sevenZip:
            do {
                _ = try SevenZipContainer.info(container: data)
                return false
            } catch SevenZipError.encryptionNotSupported {
                return true
            } catch {
                return false
            }
        default:
            return false
        }
    }

    static func extract(
        data: Data,
        originalName: String,
        into destDir: String,
        files: FileService,
        password: String?,
        observer: TransferObserver = .none
    ) throws {
        let kind = kind(of: data, name: originalName)
        switch kind {
        case .zip:
            try extractZip(data, into: destDir, files: files, password: password, observer: observer)
        case .sevenZip:
            try extractSevenZip(data, into: destDir, files: files, password: password, observer: observer)
        case .tar:
            try extractTar(data, into: destDir, files: files, observer: observer)
        case .gzip:
            try extractGzip(data, originalName: originalName, into: destDir, files: files, observer: observer)
        case .bzip2:
            try extractBzip2(data, originalName: originalName, into: destDir, files: files, observer: observer)
        case .xz:
            try extractXZ(data, originalName: originalName, into: destDir, files: files, observer: observer)
        case .lz4:
            try extractLayer(
                try LZ4.decompress(data: data),
                originalName: originalName,
                dropping: "lz4",
                into: destDir,
                files: files,
                observer: observer
            )
        case .lzma:
            try extractLayer(
                try LZMA.decompress(data: data),
                originalName: originalName,
                dropping: "lzma",
                into: destDir,
                files: files,
                observer: observer
            )
        case .deb:
            try extractDeb(data, into: destDir, files: files, observer: observer)
        case .rar:
            throw FileServiceError.operationFailed(
                "RAR isn’t supported. Save it as zip, 7z, or tar.gz and extract that."
            )
        case .unknown:
            throw FileServiceError.operationFailed(
                "Not a supported archive. Zip, 7z, tar, gz, bz2, xz, lz4, lzma, and deb work."
            )
        }
    }

    static func folderName(from originalName: String) -> String {
        let lower = originalName.lowercased()
        let compounds = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.lz4", ".tar.lzma", ".tgz", ".tbz2", ".tbz", ".txz"]
        for ext in compounds where lower.hasSuffix(ext) {
            return String(originalName.dropLast(ext.count))
        }
        let base = (originalName as NSString).deletingPathExtension
        return base.isEmpty ? "Archive" : base
    }

    private static func extractZip(_ data: Data, into dest: String, files: FileService, password: String?, observer: TransferObserver) throws {
        if let password, !password.isEmpty,
           let reader = try? ZipReader(data: data), reader.needsPassword {
            try reader.extract(into: dest, files: files, password: password, observer: observer)
            return
        }
        do {
            let entries = try ZipContainer.open(container: data)
            try writeContainer(entries.map { ($0.info.name, $0.info.type, $0.data) }, into: dest, files: files, observer: observer)
        } catch ZipError.encryptionNotSupported {
            guard let password, !password.isEmpty else { throw ZipReaderError.passwordRequired }
            try ZipReader(data: data).extract(into: dest, files: files, password: password, observer: observer)
        }
    }

    private static func extractSevenZip(
        _ data: Data,
        into dest: String,
        files: FileService,
        password: String?,
        observer: TransferObserver
    ) throws {
        let supplied = password?.isEmpty == false
        SevenZipAES.password = supplied ? password : nil
        defer { SevenZipAES.password = nil }
        let entries: [SevenZipEntry]
        do {
            entries = try SevenZipContainer.open(container: data)
        } catch SevenZipError.encryptionNotSupported {
            if supplied {
                throw FileServiceError.operationFailed(
                    "This 7z uses encryption that isn’t supported."
                )
            }
            throw ZipReaderError.passwordRequired
        } catch ZipReaderError.wrongPassword {
            throw ZipReaderError.wrongPassword
        } catch let error as SevenZipError {
            switch error {
            case .wrongCRC, .wrongSize:
                if supplied { throw ZipReaderError.wrongPassword }
                throw error
            default:
                throw error
            }
        } catch let error as LZMAError {
            if supplied { throw ZipReaderError.wrongPassword }
            throw error
        } catch let error as LZMA2Error {
            if supplied { throw ZipReaderError.wrongPassword }
            throw error
        }
        try writeContainer(entries.map { ($0.info.name, $0.info.type, $0.data) }, into: dest, files: files, observer: observer)
    }

    private static func extractTar(_ data: Data, into dest: String, files: FileService, observer: TransferObserver) throws {
        let entries = try TarContainer.open(container: data)
        try writeContainer(entries.map { ($0.info.name, $0.info.type, $0.data) }, into: dest, files: files, observer: observer)
    }

    private static func extractGzip(_ data: Data, originalName: String, into dest: String, files: FileService, observer: TransferObserver) throws {
        let plain = try GzipArchive.unarchive(archive: data)
        if isTar(plain) || originalName.lowercased().contains(".tar.") || originalName.lowercased().hasSuffix(".tgz") {
            try extractTar(plain, into: dest, files: files, observer: observer)
            return
        }
        let header = try? GzipHeader(archive: data)
        let outName = header?.fileName ?? strippedName(originalName, dropping: "gz")
        try writeSingleNamed(plain, as: outName, into: dest, files: files, observer: observer)
    }

    private static func extractBzip2(_ data: Data, originalName: String, into dest: String, files: FileService, observer: TransferObserver) throws {
        let plain = try BZip2.decompress(data: data)
        let lower = originalName.lowercased()
        if isTar(plain) || lower.contains(".tar.") || lower.hasSuffix(".tbz") || lower.hasSuffix(".tbz2") {
            try extractTar(plain, into: dest, files: files, observer: observer)
            return
        }
        try writeSingleFile(plain, originalName: originalName, dropping: "bz2", into: dest, files: files, observer: observer)
    }

    private static func extractXZ(_ data: Data, originalName: String, into dest: String, files: FileService, observer: TransferObserver) throws {
        let plain = try XZArchive.unarchive(archive: data)
        let lower = originalName.lowercased()
        if isTar(plain) || lower.contains(".tar.") || lower.hasSuffix(".txz") {
            try extractTar(plain, into: dest, files: files, observer: observer)
            return
        }
        try writeSingleFile(plain, originalName: originalName, dropping: "xz", into: dest, files: files, observer: observer)
    }

    private static func extractLayer(
        _ plain: Data,
        originalName: String,
        dropping ext: String,
        into destDir: String,
        files: FileService,
        observer: TransferObserver
    ) throws {
        let lower = originalName.lowercased()
        if isTar(plain) || lower.contains(".tar.") {
            try extractTar(plain, into: destDir, files: files, observer: observer)
            return
        }
        try writeSingleFile(plain, originalName: originalName, dropping: ext, into: destDir, files: files, observer: observer)
    }

    private static func extractDeb(_ data: Data, into dest: String, files: FileService, observer: TransferObserver) throws {
        guard let payload = try arMember(namedPrefix: "data.tar", in: data) else {
            throw FileServiceError.operationFailed("No data.tar inside this .deb.")
        }
        let innerKind = kind(of: payload, name: "data.tar")
        switch innerKind {
        case .gzip: try extractGzip(payload, originalName: "data.tar.gz", into: dest, files: files, observer: observer)
        case .xz: try extractXZ(payload, originalName: "data.tar.xz", into: dest, files: files, observer: observer)
        case .bzip2: try extractBzip2(payload, originalName: "data.tar.bz2", into: dest, files: files, observer: observer)
        case .lz4: try extractLayer(try LZ4.decompress(data: payload), originalName: "data.tar.lz4", dropping: "lz4", into: dest, files: files, observer: observer)
        case .lzma: try extractLayer(try LZMA.decompress(data: payload), originalName: "data.tar.lzma", dropping: "lzma", into: dest, files: files, observer: observer)
        case .tar: try extractTar(payload, into: dest, files: files, observer: observer)
        default:
            if isTar(payload) {
                try extractTar(payload, into: dest, files: files, observer: observer)
            } else {
                throw FileServiceError.operationFailed("Unsupported data.tar compression in this .deb.")
            }
        }
    }

    private static func writeContainer(
        _ entries: [(name: String, type: ContainerEntryType, data: Data?)],
        into destDir: String,
        files: FileService,
        observer: TransferObserver
    ) throws {
        let root = (destDir as NSString).standardizingPath
        try files.createDirectory(at: root)
        var fileCount = 0
        var byteCount: Int64 = 0
        observer.total(entries.reduce(Int64(0)) { $0 + Int64($1.data?.count ?? 0) })
        for entry in entries {
            try observer.checkCancelled()
            if entry.name.isEmpty { continue }
            let resolved = try ArchiveEntryPath.resolve(entry.name, under: destDir)
            if entry.type == .directory || resolved.isDirectory {
                try files.createDirectory(at: resolved.path)
                continue
            }
            guard let payload = entry.data else { continue }
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

    private static func writeSingleFile(
        _ data: Data,
        originalName: String,
        dropping ext: String,
        into destDir: String,
        files: FileService,
        observer: TransferObserver
    ) throws {
        try writeSingleNamed(data, as: strippedName(originalName, dropping: ext), into: destDir, files: files, observer: observer)
    }

    private static func writeSingleNamed(_ data: Data, as name: String, into destDir: String, files: FileService, observer: TransferObserver) throws {
        try files.createDirectory(at: destDir)
        let leaf = (name as NSString).lastPathComponent
        guard FileNameRules.sanitize(leaf) != nil else {
            throw FileServiceError.operationFailed("Unsafe path in archive: \(name)")
        }
        let dest = files.uniqueDestination(in: destDir, preferredName: leaf)
        observer.total(Int64(data.count))
        try observer.checkCancelled()
        observer.detail(leaf)
        try files.writeFile(data: data, to: dest)
        observer.bytes(Int64(data.count))
    }

    private static func strippedName(_ original: String, dropping ext: String) -> String {
        let ns = original as NSString
        if ns.pathExtension.lowercased() == ext.lowercased() {
            let base = ns.deletingPathExtension
            return base.isEmpty ? original : base
        }
        return original
    }

    private static func isTar(_ data: Data) -> Bool {
        guard data.count >= 262 else { return false }
        let ustar = data.subdata(in: 257..<262)
        return ustar == Data("ustar".utf8)
    }

    /// GNU ar used by .deb: `!<arch>\\n` then 60-byte headers.
    private static func arMember(namedPrefix: String, in data: Data) throws -> Data? {
        let magic = Data("!<arch>\n".utf8)
        guard data.starts(with: [UInt8](magic)) else { return nil }
        var offset = magic.count
        while offset + 60 <= data.count {
            let header = data.subdata(in: offset..<(offset + 60))
            offset += 60
            guard header.count == 60 else { break }
            let name = String(data: header.subdata(in: 0..<16), encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            let sizeStr = String(data: header.subdata(in: 48..<58), encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            guard let size = Int(sizeStr), size >= 0, offset + size <= data.count else {
                throw FileServiceError.operationFailed("Corrupt ar/deb archive.")
            }
            let payload = data.subdata(in: offset..<(offset + size))
            if name.hasPrefix(namedPrefix) {
                return payload
            }
            offset += size
            if size % 2 == 1 { offset += 1 }
        }
        return nil
    }
}
