import BigInt
import CEd25519
import Foundation

/// Packet encryption keys after the handshake (ts3protocol.md 1.6 and 3.2.2.4).
struct SessionCrypto {
    static let fakeKey = Array("c:\\windows\\syste".utf8)
    static let fakeNonce = Array("m\\firewall32.cpl".utf8)

    let sharedIV: [UInt8]   // 64 bytes
    let sharedMac: [UInt8]  // 8 bytes

    private struct CacheKey: Hashable {
        let type: UInt8
        let toServer: Bool
        let generation: UInt32
    }
    private var cache: [CacheKey: (key: [UInt8], nonce: [UInt8])] = [:]

    init(alpha: [UInt8], beta: [UInt8], ephemeralPrivate: [UInt8], serverEphemeral: [UInt8]) throws {
        let shared = try Ed25519.multiply(ephemeralPrivate, serverEphemeral)
        var iv = Hash.sha512(shared)
        for i in 0..<10 { iv[i] ^= alpha[i] }
        for i in 0..<54 { iv[i + 10] ^= beta[i] }
        sharedIV = iv
        sharedMac = Array(Hash.sha1(iv)[0..<8])
    }

    mutating func keyNonce(type: PacketType, toServer: Bool, packetId: UInt16, generation: UInt32) -> (key: [UInt8], nonce: [UInt8]) {
        let cacheKey = CacheKey(type: type.rawValue, toServer: toServer, generation: generation)
        var entry: (key: [UInt8], nonce: [UInt8])
        if let cached = cache[cacheKey] {
            entry = cached
        } else {
            var temp: [UInt8] = [toServer ? 0x31 : 0x30, type.rawValue]
            temp += withUnsafeBytes(of: generation.bigEndian, Array.init)
            temp += sharedIV
            let kn = Hash.sha256(temp)
            entry = (Array(kn[0..<16]), Array(kn[16..<32]))
            cache[cacheKey] = entry
        }
        entry.key[0] ^= UInt8(packetId >> 8)
        entry.key[1] ^= UInt8(packetId & 0xff)
        return entry
    }
}

/// The Init1 step-3 puzzle: y = x ^ (2 ^ level) mod n.
enum RSAPuzzle {
    static func solve(x: [UInt8], n: [UInt8], level: UInt32) throws -> [UInt8] {
        guard level <= 10_000_000 else { throw TS3Error.protocolViolation("RSA puzzle level \(level) too high") }
        // Fixed-size C arithmetic: the same loop with BigInt takes over a second in a debug build
        // at the usual level of 10 000, and the whole connection waits for it.
        if x.count == 64, n.count == 64 {
            var y = [UInt8](repeating: 0, count: 64)
            if ts_square_repeatedly_mod(x, n, level, &y) == 1 { return y }
        }
        return try solveWithBigInt(x: x, n: n, level: level)
    }

    /// For the moduli the fast path does not take (even ones; no real server sends those).
    static func solveWithBigInt(x: [UInt8], n: [UInt8], level: UInt32) throws -> [UInt8] {
        let modulus = BigUInt(Data(n))
        guard !modulus.isZero else { throw TS3Error.protocolViolation("RSA puzzle modulus is zero") }
        var y = BigUInt(Data(x)) % modulus
        for _ in 0..<level {
            y = (y * y) % modulus
        }
        let bytes = Array(y.serialize())
        return [UInt8](repeating: 0, count: max(0, 64 - bytes.count)) + bytes.suffix(64)
    }
}
