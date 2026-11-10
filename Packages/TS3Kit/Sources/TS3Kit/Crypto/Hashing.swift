import CryptoKit
import Foundation

enum Hash {
    static func sha1(_ data: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: data)) }
    static func sha256(_ data: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: data)) }
    static func sha512(_ data: [UInt8]) -> [UInt8] { Array(SHA512.hash(data: data)) }
}

extension Array where Element == UInt8 {
    var base64: String { Data(self).base64EncodedString() }

    init?(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return nil }
        self = Array(data)
    }

    static func random(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// TeamSpeak hashes every password it sends: base64(sha1(password)).
public func ts3HashPassword(_ password: String) -> String {
    password.isEmpty ? "" : Hash.sha1(Array(password.utf8)).base64
}
