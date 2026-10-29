import Foundation

// ZipReader reads password-protected archives through ZipPassword, which needs the C crypto in
// zip_crypto.c and so cannot be built on the host. Nothing the host tests read is encrypted, so
// these stand in for it; reading an encrypted entry on the host fails as "password required".

struct ZipAESInfo {
    let keyBits: Int
    let compression: Int
}

enum ZipPassword {
    static func decryptZipCrypto(
        ciphertext: Data,
        password: String,
        crc32: UInt32,
        dosTime: UInt16,
        usesDataDescriptor: Bool
    ) throws -> Data {
        throw ZipReaderError.wrongPassword
    }

    static func decryptAES(ciphertext: Data, password: String, aes: ZipAESInfo) throws -> Data {
        throw ZipReaderError.wrongPassword
    }
}
