import CommonCrypto
import Foundation

/// AES-128 single-block encryption (ECB on one block), used to build CTR and CMAC.
struct AES128Block {
    private let key: [UInt8]

    init(key: [UInt8]) {
        precondition(key.count == 16, "AES-128 key must be 16 bytes")
        self.key = key
    }

    func encrypt(_ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { keyPtr in
            block.withUnsafeBytes { inPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, 16, nil,
                        inPtr.baseAddress, 16,
                        outPtr.baseAddress, 16, &moved
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "AES block encryption failed: \(status)")
        return out
    }
}

/// AES-EAX with an 8-byte tag, as used by TeamSpeak for packet encryption.
/// EAX = CTR encryption + OMAC (CMAC) over nonce, header and ciphertext.
enum EAX {
    static let tagLength = 8

    static func encrypt(key: [UInt8], nonce: [UInt8], header: [UInt8], plaintext: [UInt8]) -> (ciphertext: [UInt8], tag: [UInt8]) {
        let aes = AES128Block(key: key)
        let n = omac(aes, tweak: 0, nonce)
        let h = omac(aes, tweak: 1, header)
        let ciphertext = ctr(aes, counter: n, plaintext)
        let c = omac(aes, tweak: 2, ciphertext)
        let tag = (0..<tagLength).map { n[$0] ^ h[$0] ^ c[$0] }
        return (ciphertext, tag)
    }

    /// Returns nil when the tag does not match.
    static func decrypt(key: [UInt8], nonce: [UInt8], header: [UInt8], ciphertext: [UInt8], tag: [UInt8]) -> [UInt8]? {
        let aes = AES128Block(key: key)
        let n = omac(aes, tweak: 0, nonce)
        let h = omac(aes, tweak: 1, header)
        let c = omac(aes, tweak: 2, ciphertext)
        var diff: UInt8 = 0
        for i in 0..<tagLength {
            diff |= (n[i] ^ h[i] ^ c[i]) ^ tag[i]
        }
        guard diff == 0 else { return nil }
        return ctr(aes, counter: n, ciphertext)
    }

    // MARK: - Building blocks

    private static func ctr(_ aes: AES128Block, counter start: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var counter = start
        var out = [UInt8](repeating: 0, count: data.count)
        var offset = 0
        while offset < data.count {
            let stream = aes.encrypt(counter)
            let end = min(offset + 16, data.count)
            for i in offset..<end {
                out[i] = data[i] ^ stream[i - offset]
            }
            offset = end
            // 128-bit big-endian increment.
            for i in stride(from: 15, through: 0, by: -1) {
                counter[i] &+= 1
                if counter[i] != 0 { break }
            }
        }
        return out
    }

    /// OMAC^t(M) = CMAC(K, [t]_16 || M)
    private static func omac(_ aes: AES128Block, tweak: UInt8, _ message: [UInt8]) -> [UInt8] {
        var prefixed = [UInt8](repeating: 0, count: 16)
        prefixed[15] = tweak
        prefixed.append(contentsOf: message)
        return cmac(aes, prefixed)
    }

    static func cmac(_ aes: AES128Block, _ message: [UInt8]) -> [UInt8] {
        let l = aes.encrypt([UInt8](repeating: 0, count: 16))
        let k1 = doubled(l)
        let k2 = doubled(k1)

        let blockCount = max(1, (message.count + 15) / 16)
        let lastComplete = !message.isEmpty && message.count % 16 == 0
        var x = [UInt8](repeating: 0, count: 16)

        for b in 0..<(blockCount - 1) {
            for i in 0..<16 { x[i] ^= message[b * 16 + i] }
            x = aes.encrypt(x)
        }
        var last = [UInt8](repeating: 0, count: 16)
        let lastStart = (blockCount - 1) * 16
        let remaining = message.count - lastStart
        if lastComplete {
            for i in 0..<16 { last[i] = message[lastStart + i] ^ k1[i] }
        } else {
            for i in 0..<remaining { last[i] = message[lastStart + i] }
            last[remaining] = 0x80
            for i in 0..<16 { last[i] ^= k2[i] }
        }
        for i in 0..<16 { x[i] ^= last[i] }
        return aes.encrypt(x)
    }

    private static func doubled(_ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var carry: UInt8 = 0
        for i in stride(from: 15, through: 0, by: -1) {
            out[i] = (block[i] << 1) | carry
            carry = block[i] >> 7
        }
        if carry != 0 { out[15] ^= 0x87 }
        return out
    }
}
