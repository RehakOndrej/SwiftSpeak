import CEd25519
import Foundation

/// Ed25519 group operations used by the TS3 ≥ 3.1 key exchange.
enum Ed25519 {
    /// TeamSpeak's fixed root key for the license chain.
    static let rootKey: [UInt8] = [
        0xcd, 0x0d, 0xe2, 0xae, 0xd4, 0x63, 0x45, 0x50, 0x9a, 0x7e, 0x3c, 0xfd, 0x8f, 0x68, 0xb3, 0xdc,
        0x75, 0x55, 0xb2, 0x9d, 0xcc, 0xec, 0x73, 0xcd, 0x18, 0x75, 0x0f, 0x99, 0x38, 0x12, 0x40, 0x8a,
    ]

    static func reduce(_ scalar: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        if scalar.count == 64 {
            ts_ed_sc_reduce64(&out, scalar)
        } else {
            ts_ed_sc_reduce32(&out, scalar)
        }
        return out
    }

    static func basePointMultiply(_ scalar: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        ts_ed_scalarmult_base(&out, scalar)
        return out
    }

    static func multiply(_ scalar: [UInt8], _ point: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        guard ts_ed_scalarmult(&out, scalar, point) == 0 else {
            throw TS3Error.protocolViolation("Invalid Ed25519 point")
        }
        return out
    }

    static func multiplyAdd(_ scalar: [UInt8], _ point: [UInt8], _ addend: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        guard ts_ed_scalarmult_add(&out, scalar, point, addend) == 0 else {
            throw TS3Error.protocolViolation("Invalid Ed25519 point in license chain")
        }
        return out
    }

    /// A fresh ephemeral private scalar (reduced mod l).
    static func randomScalar() -> [UInt8] { reduce([UInt8].random(64)) }
}

/// The server license sent in `initivexpand2 l=…` (see ts3protocol.md 3.2.2.2).
struct LicenseChain {
    struct Block {
        let type: UInt8
        let bytes: [UInt8] // the whole block including the leading key-type byte
        var publicKey: [UInt8] { Array(bytes[1..<33]) }
    }

    let blocks: [Block]

    private static let minBlockLength = 42

    init(_ data: [UInt8]) throws {
        guard let version = data.first, version == 0 || version == 1 else {
            throw TS3Error.protocolViolation("Unsupported license version")
        }
        var offset = 1
        var blocks: [Block] = []
        while offset < data.count {
            guard blocks.count < 8 else { throw TS3Error.protocolViolation("License has too many blocks") }
            let rest = Array(data[offset...])
            guard rest.count >= Self.minBlockLength, rest[0] == 0 else {
                throw TS3Error.protocolViolation("License block too short or wrong key kind")
            }
            let type = rest[33]
            let content = Array(rest[Self.minBlockLength...])
            let extra: Int
            switch type {
            case 0: // Intermediate: 4 unknown bytes + issuer string
                extra = 4 + (try Self.cString(content, from: 4))
            case 1, 3: // Website / Code: issuer string
                extra = try Self.cString(content, from: 0)
            case 2: // TS3 server: type(1) + max clients(4) + issuer string
                extra = 5 + (try Self.cString(content, from: 5))
            case 8: // TS5 server: type(1) + count(1) + properties
                guard content.count >= 2 else { throw TS3Error.protocolViolation("TS5 license too short") }
                var pos = 2
                for _ in 0..<Int(content[1]) {
                    guard pos < content.count else { throw TS3Error.protocolViolation("TS5 license property missing") }
                    pos += 1 + Int(content[pos])
                }
                extra = pos
            case 32: // Ephemeral
                extra = 0
            default:
                throw TS3Error.protocolViolation("Unknown license block type \(type)")
            }
            let length = Self.minBlockLength + extra
            guard length <= rest.count else { throw TS3Error.protocolViolation("License block overruns data") }
            blocks.append(Block(type: type, bytes: Array(rest[0..<length])))
            offset += length
        }
        self.blocks = blocks
    }

    /// Length of a NUL-terminated string starting at `from`, including the terminator.
    private static func cString(_ data: [UInt8], from: Int) throws -> Int {
        guard from <= data.count, let nul = data[from...].firstIndex(of: 0) else {
            throw TS3Error.protocolViolation("License string not terminated")
        }
        return nul - from + 1
    }

    /// next_key = block_key * clamp(sha512(block[1..])[0..32]) + parent, starting at the root.
    func deriveServerKey(root: [UInt8] = Ed25519.rootKey) throws -> [UInt8] {
        var key = root
        for block in blocks {
            var hash = Array(Hash.sha512(Array(block.bytes[1...]))[0..<32])
            hash[0] &= 248
            hash[31] &= 63
            hash[31] |= 64
            key = try Ed25519.multiplyAdd(Ed25519.reduce(hash), block.publicKey, key)
        }
        return key
    }
}
