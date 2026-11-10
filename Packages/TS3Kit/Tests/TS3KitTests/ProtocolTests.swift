import CEd25519
import Foundation
import Testing
@testable import TS3Kit

// Vectors marked "tsclientlib" come from ReSpeak/tsclientlib's test suite (MIT OR Apache-2.0).

private func hex(_ s: String) -> [UInt8] {
    let clean = s.filter { !$0.isWhitespace }
    return stride(from: 0, to: clean.count, by: 2).map {
        let start = clean.index(clean.startIndex, offsetBy: $0)
        return UInt8(clean[start..<clean.index(start, offsetBy: 2)], radix: 16)!
    }
}

private let licenseBlob = "AQA1hUFJiiSs0wFXkYuPUJVcDa6XCrZTcsvkB0Ffzz4CmwIITRXgCqeTYAcAAAAgQW5vbnltb3VzAAC4R+5mos+UQ/KCbkpQLMI5WRp4wkQu8e5PZY4zU+/FlyAJwaE8CcJJ/A=="

@Suite struct CryptoTests {
    @Test func fakeKeyAckMatchesTsclientlib() {
        // OutAck(C2S, Command, 0) fake-encrypted.
        var packet = Packet(packetId: 0, clientId: 0, type: .ack, flags: [], payload: [0, 0])
        let r = EAX.encrypt(key: SessionCrypto.fakeKey, nonce: SessionCrypto.fakeNonce, header: packet.meta(toServer: true), plaintext: packet.payload)
        packet.payload = r.ciphertext
        packet.mac = r.tag
        #expect(packet.encodeToServer() == [0xa4, 0x7b, 0x47, 0x94, 0xdb, 0xa9, 0x6a, 0xc5, 0, 0, 0, 0, 0x06, 0xfe, 0x18])
    }

    @Test func eaxRoundTripAndTamperDetection() {
        let key = [UInt8].random(16), nonce = [UInt8].random(16), header: [UInt8] = [1, 2, 3]
        let plain = Array("clientupdate client_away=1".utf8)
        let r = EAX.encrypt(key: key, nonce: nonce, header: header, plaintext: plain)
        #expect(EAX.decrypt(key: key, nonce: nonce, header: header, ciphertext: r.ciphertext, tag: r.tag) == plain)
        var bad = r.ciphertext
        bad[0] ^= 1
        #expect(EAX.decrypt(key: key, nonce: nonce, header: header, ciphertext: bad, tag: r.tag) == nil)
    }

    @Test func cmacMatchesRFC4493() {
        // RFC 4493 example 2 (16-byte message).
        let aes = AES128Block(key: hex("2b7e151628aed2a6abf7158809cf4f3c"))
        #expect(EAX.cmac(aes, hex("6bc1bee22e409f96e93d7e117393172a")) == hex("070a16b46b4d4144f79bdd9dd04a287c"))
        #expect(EAX.cmac(aes, []) == hex("bb1d6929e95937287fa37d129b756746"))
    }

    @Test func licenseChainDerivesExpectedKey() throws {
        let chain = try LicenseChain([UInt8](base64: licenseBlob)!)
        let key = try chain.deriveServerKey()
        #expect(key == hex("40e950c461ba183a1eb7cbb19ac3d8d9c4d524db38f72d3d6675772ac59cc5c6"))
    }

    @Test func sharedIVMatchesTsclientlib() throws {
        let serverKey = try LicenseChain([UInt8](base64: licenseBlob)!).deriveServerKey()
        let ek = Ed25519.reduce(hex("b04ea1d95c7264df0de8b36baa7ca15f7571f51fa054b55127088edd963d6e79"))
        let crypto = try SessionCrypto(
            alpha: [UInt8](base64: "Jkxq1wIvvhzaCA==")!,
            beta: [UInt8](base64: "wU5T/MM6toW6Wge9th7VlTlzVZ9JDWypw2P9migfc25pjGP2Tj7Hm6rJpmKeHRr08Ch7BEAR")!,
            ephemeralPrivate: ek,
            serverEphemeral: serverKey
        )
        #expect(crypto.sharedIV == hex("""
            7e34c4df0a5dbbacc92fd1a7d2486c2ea2f417978525 45cfc89219012b2d52842b2bdd98ffc972952123
            f3f66ada55d9d84a37e33b2d23fe38fd14ae06670916
            """))
    }

    @Test func ephemeralKeyExchangeIsSymmetric() throws {
        let a = Ed25519.randomScalar(), b = Ed25519.randomScalar()
        let ab = try Ed25519.multiply(a, Ed25519.basePointMultiply(b))
        let ba = try Ed25519.multiply(b, Ed25519.basePointMultiply(a))
        #expect(ab == ba)
    }

    @Test func identityKeyRoundTripsThroughTomcryptAndSigns() throws {
        let identity = Identity.generate(level: 8)
        #expect(identity.securityLevel >= 8)
        let server = try ServerKey(tomcrypt: identity.tomcryptPublicKey)
        let data = Array("proof".utf8)
        #expect(server.verify(signatureDER: try identity.sign(data), data: data))
        #expect(identity.uid.count == 28)
    }

    @Test func rsaPuzzleSquaresLevelTimes() throws {
        // 2^(2^3) mod 1000003 = 256
        let x = [UInt8](repeating: 0, count: 63) + [2]
        let n = [UInt8](repeating: 0, count: 61) + [0x0f, 0x42, 0x43]
        let y = try RSAPuzzle.solve(x: x, n: n, level: 3)
        #expect(y.count == 64)
        #expect(Array(y.suffix(2)) == [0x01, 0x00])
    }

    /// The fast path must agree with plain big-number arithmetic, including for x ≥ n and small n.
    @Test func rsaPuzzleFastPathMatchesBigInt() throws {
        var generator: UInt64 = 99
        func bytes(_ count: Int) -> [UInt8] {
            (0..<count).map { _ in
                generator = generator &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: generator >> 33)
            }
        }
        for round in 0..<40 {
            var n = bytes(64)
            n[63] |= 1 // odd, as RSA moduli are
            if round % 4 == 1 { n[0] = 0xFF; n[1] = 0xFF }                   // top bits set
            if round % 4 == 2 { n.replaceSubrange(0..<40, with: [UInt8](repeating: 0, count: 40)) } // short modulus
            var x = bytes(64)
            if round % 4 == 3 { x = [UInt8](repeating: 0xFF, count: 64) }    // larger than n
            let level = UInt32(round * 7)
            #expect(try RSAPuzzle.solve(x: x, n: n, level: level) == RSAPuzzle.solveWithBigInt(x: x, n: n, level: level), "round \(round)")
        }
        // Even modulus: handled by the fallback.
        let even = bytes(63) + [0x10]
        #expect(try RSAPuzzle.solve(x: bytes(64), n: even, level: 5).count == 64)
    }

    @Test func rsaPuzzleAtTheUsualLevelIsQuick() throws {
        let start = Date()
        _ = try RSAPuzzle.solve(x: [UInt8](repeating: 0xAB, count: 64), n: [UInt8](repeating: 0xC7, count: 64), level: 10_000)
        #expect(Date().timeIntervalSince(start) < 0.25)
    }
}

@Suite struct CommandTests {
    @Test func escapeRoundTrip() {
        let s = "a b|c/d\\e\nf\tg"
        #expect(Command.unescape(Command.escape(s)) == s)
        #expect(Command.escape("Hello World|/") == "Hello\\sWorld\\p\\/")
    }

    @Test func encodesBareKeysForEmptyValues() {
        let c = Command("clientmove", [("clid", "5"), ("cid", "12"), ("cpw", nil)])
        #expect(c.encoded == "clientmove clid=5 cid=12 cpw")
    }

    @Test func parsesMultiEntryNotificationsWithSharedKeys() {
        let c = Command.parse("notifyclientmoved ctid=7 reasonid=0 clid=3|clid=4")
        #expect(c.name == "notifyclientmoved")
        #expect(c.entries.count == 2)
        #expect(c.entries[1]["ctid"] == "7")
        #expect(c.entries[1]["clid"] == "4")
    }

    @Test func parsesInitServer() {
        let c = Command.parse("initserver virtualserver_name=TeamSpeak\\s]I[\\sServer virtualserver_hostmessage aclid=2 pv=7")
        #expect(c.first["virtualserver_name"] == "TeamSpeak ]I[ Server")
        #expect(c.first["virtualserver_hostmessage"] == "")
        #expect(c.first.int("aclid") == 2)
    }

    @Test func parsesErrorWithoutName() {
        let c = Command.parse("error id=0 msg=ok return_code=5")
        #expect(c.name == "error")
        #expect(c.first["return_code"] == "5")
    }
}

@Suite struct QuickLZTests {
    @Test func decompressesLevel1ServerCommand() throws {
        let data = try QuickLZ.decompress([UInt8](base64: QuickLZFixture.compressed)!)
        #expect(data == [UInt8](base64: QuickLZFixture.expected)!)
    }

    @Test func decompressesStoredBlock() throws {
        let stored: [UInt8] = [0x44, 8, 5] + Array("hello".utf8)
        #expect(try QuickLZ.decompress(stored) == Array("hello".utf8))
    }
}

@Suite struct PacketTests {
    @Test func decodesServerHeader() {
        let p = Packet.decodeFromServer([1, 2, 3, 4, 5, 6, 7, 8, 0x00, 0x2a, 0x82, 0xaa])
        #expect(p?.packetId == 42)
        #expect(p?.type == .command)
        #expect(p?.flags == [.unencrypted])
        #expect(p?.payload == [0xaa])
    }

    @Test func clientMetaIncludesClientId() {
        let p = Packet(packetId: 1, clientId: 2, type: .command, flags: [.newProtocol], payload: [])
        #expect(p.meta(toServer: true) == [0, 1, 0, 2, 0x22])
    }
}
