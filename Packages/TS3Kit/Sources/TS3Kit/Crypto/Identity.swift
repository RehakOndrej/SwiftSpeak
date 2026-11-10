import CryptoKit
import Foundation

/// A TeamSpeak identity: a P-256 key pair plus the hashcash key offset.
public struct Identity: Sendable, Codable, Equatable {
    public let privateKeyRaw: Data
    public private(set) var keyOffset: UInt64

    private var privateKey: P256.Signing.PrivateKey {
        // The raw representation is validated in init, so this cannot fail.
        try! P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
    }

    public init(privateKeyRaw: Data, keyOffset: UInt64) throws {
        _ = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        self.privateKeyRaw = privateKeyRaw
        self.keyOffset = keyOffset
    }

    /// Creates a new identity and mines the hashcash offset up to `level`.
    public static func generate(level: UInt8 = 8) -> Identity {
        let key = P256.Signing.PrivateKey()
        var identity = try! Identity(privateKeyRaw: key.rawRepresentation, keyOffset: 0)
        identity.improveSecurityLevel(to: level)
        return identity
    }

    /// base64 of the LibTomCrypt DER public key ("omega").
    public var publicKeyString: String { tomcryptPublicKey.base64 }

    /// The unique id the server shows for this identity: base64(sha1(omega)).
    public var uid: String { Hash.sha1(Array(publicKeyString.utf8)).base64 }

    public var securityLevel: UInt8 { Self.hashcashLevel(omega: publicKeyString, offset: keyOffset) }

    public mutating func improveSecurityLevel(to level: UInt8) {
        let omega = publicKeyString
        var offset = keyOffset
        while Self.hashcashLevel(omega: omega, offset: offset) < level {
            offset += 1
        }
        keyOffset = offset
    }

    static func hashcashLevel(omega: String, offset: UInt64) -> UInt8 {
        let digest = Hash.sha1(Array((omega + String(offset)).utf8))
        var level: UInt8 = 0
        for byte in digest {
            if byte == 0 {
                level += 8
            } else {
                level += UInt8(byte.trailingZeroBitCount)
                break
            }
        }
        return level
    }

    /// SEQUENCE { BIT STRING (1 bit: 0), INTEGER 32, INTEGER x, INTEGER y }
    var tomcryptPublicKey: [UInt8] {
        let x963 = Array(privateKey.publicKey.x963Representation) // 04 || x || y
        let x = Array(x963[1..<33])
        let y = Array(x963[33..<65])
        return DER.sequence([
            DER.bitString(bitCount: 1, value: [0x00]),
            DER.integer([32]),
            DER.integer(x),
            DER.integer(y),
        ])
    }

    /// ECDSA P-256/SHA-256 signature, DER encoded.
    func sign(_ data: [UInt8]) throws -> [UInt8] {
        Array(try privateKey.signature(for: data).derRepresentation)
    }
}

/// Server identity key parsed from `omega`.
struct ServerKey {
    let key: P256.Signing.PublicKey

    init(tomcrypt: [UInt8]) throws {
        let items = try DER.parseSequence(tomcrypt)
        guard items.count >= 4,
              case .integer(let xRaw) = items[2],
              case .integer(let yRaw) = items[3] else {
            throw TS3Error.protocolViolation("Server key (omega) has an unexpected layout")
        }
        let x = DER.fixedWidth(xRaw, 32)
        let y = DER.fixedWidth(yRaw, 32)
        key = try P256.Signing.PublicKey(x963Representation: [0x04] + x + y)
    }

    func verify(signatureDER: [UInt8], data: [UInt8]) -> Bool {
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureDER) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// Minimal DER encoding/decoding for the LibTomCrypt key format.
enum DER {
    enum Item {
        case integer([UInt8])
        case bitString([UInt8])
        case other(tag: UInt8, [UInt8])
    }

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }

    static func bitString(bitCount: Int, value: [UInt8]) -> [UInt8] {
        let unused = UInt8((8 - bitCount % 8) % 8)
        return tlv(0x03, [unused] + value)
    }

    /// Unsigned big-endian magnitude to a DER INTEGER (minimal, positive).
    static func integer(_ magnitude: [UInt8]) -> [UInt8] {
        var bytes = Array(magnitude.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func fixedWidth(_ integer: [UInt8], _ width: Int) -> [UInt8] {
        let trimmed = Array(integer.drop(while: { $0 == 0 }))
        return [UInt8](repeating: 0, count: max(0, width - trimmed.count)) + trimmed.suffix(width)
    }

    static func parseSequence(_ data: [UInt8]) throws -> [Item] {
        var reader = Reader(data)
        let (tag, content) = try reader.next()
        guard tag == 0x30 else { throw TS3Error.protocolViolation("DER: expected SEQUENCE") }
        var inner = Reader(content)
        var items: [Item] = []
        while !inner.isAtEnd {
            let (t, c) = try inner.next()
            switch t {
            case 0x02: items.append(.integer(c))
            case 0x03: items.append(.bitString(c))
            default: items.append(.other(tag: t, c))
            }
        }
        return items
    }

    private struct Reader {
        let data: [UInt8]
        var pos = 0
        init(_ data: [UInt8]) { self.data = data }
        var isAtEnd: Bool { pos >= data.count }

        mutating func next() throws -> (UInt8, [UInt8]) {
            guard pos + 2 <= data.count else { throw TS3Error.protocolViolation("DER: truncated") }
            let tag = data[pos]
            var len = Int(data[pos + 1])
            pos += 2
            if len & 0x80 != 0 {
                let count = len & 0x7f
                guard count <= 4, pos + count <= data.count else { throw TS3Error.protocolViolation("DER: bad length") }
                len = 0
                for _ in 0..<count {
                    len = (len << 8) | Int(data[pos])
                    pos += 1
                }
            }
            guard pos + len <= data.count else { throw TS3Error.protocolViolation("DER: truncated content") }
            let content = Array(data[pos..<pos + len])
            pos += len
            return (tag, content)
        }
    }
}
