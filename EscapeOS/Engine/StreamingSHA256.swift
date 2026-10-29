import Foundation

/// SHA-256 over data that arrives in pieces, so a file of any size is hashed without being held in
/// memory. On the device this is CryptoKit; a small portable version stands in where CryptoKit does
/// not exist (the Linux host that runs the logic tests), and is checked against published vectors.
#if canImport(CryptoKit)
import CryptoKit

struct StreamingSHA256 {
    private var hasher = SHA256()

    init() {}

    mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    /// The digest as 64 lowercase hex characters.
    func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#else
struct StreamingSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    init() { pending.reserveCapacity(64) }

    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        var input = [UInt8](data)[...]
        if !pending.isEmpty {
            let need = 64 - pending.count
            pending.append(contentsOf: input.prefix(need))
            input = input.dropFirst(need)
            if pending.count == 64 {
                Self.compress(&state, pending[...])
                pending.removeAll(keepingCapacity: true)
            }
        }
        while input.count >= 64 {
            Self.compress(&state, input.prefix(64))
            input = input.dropFirst(64)
        }
        pending.append(contentsOf: input)
    }

    func finalize() -> String {
        var copy = self
        var tail = copy.pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bits >> UInt64(shift)) & 0xff)) }
        var offset = 0
        while offset < tail.count {
            Self.compress(&copy.state, tail[offset..<(offset + 64)])
            offset += 64
        }
        return copy.state.map { String(format: "%08x", $0) }.joined()
    }

    private static func compress(_ state: inout [UInt32], _ block: ArraySlice<UInt8>) {
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for i in 0..<16 {
            let j = base + i * 4
            w[i] = UInt32(block[j]) << 24 | UInt32(block[j + 1]) << 16 | UInt32(block[j + 2]) << 8 | UInt32(block[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] = state[0] &+ a; state[1] = state[1] &+ b; state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f; state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }
}
#endif

extension StreamingSHA256 {
    /// The digest of `data` held in memory, as 64 lowercase hex characters.
    static func hex(of data: Data) -> String {
        var hasher = StreamingSHA256()
        hasher.update(data)
        return hasher.finalize()
    }
}
