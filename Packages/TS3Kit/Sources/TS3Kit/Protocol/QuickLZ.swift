import Foundation

/// QuickLZ decompression (levels 1 and 3), needed for compressed server commands.
///
/// Port of the decompressor in Flakebi's `quicklz` Rust crate (MIT OR Apache-2.0),
/// https://github.com/ReSpeak/quicklz. Only decompression is implemented:
/// the client never has to compress, it can always send uncompressed fragments.
enum QuickLZ {
    struct CorruptData: Error {
        let reason: String
    }

    private static let hashtableSize = 4096

    static func decompress(_ input: [UInt8], maxSize: Int = 1 << 20) throws -> [UInt8] {
        var pos = 0
        func readU8() throws -> UInt32 {
            guard pos < input.count else { throw CorruptData(reason: "unexpected end of data") }
            defer { pos += 1 }
            return UInt32(input[pos])
        }
        func readU32LE() throws -> UInt32 {
            guard pos + 4 <= input.count else { throw CorruptData(reason: "unexpected end of data") }
            defer { pos += 4 }
            return UInt32(input[pos]) | UInt32(input[pos + 1]) << 8 | UInt32(input[pos + 2]) << 16 | UInt32(input[pos + 3]) << 24
        }

        let flags = try readU8()
        let level = (flags >> 2) & 0b11
        guard level == 1 || level == 3 else { throw CorruptData(reason: "unsupported level \(level)") }
        let headerLength: UInt32 = flags & 2 == 2 ? 9 : 3
        let compressedSize: UInt32
        let decompressedSize: Int
        if headerLength == 3 {
            compressedSize = try readU8()
            decompressedSize = Int(try readU8())
        } else {
            compressedSize = try readU32LE()
            decompressedSize = Int(try readU32LE())
        }
        guard decompressedSize <= maxSize else { throw CorruptData(reason: "too large (\(decompressedSize))") }
        guard compressedSize >= headerLength else { throw CorruptData(reason: "invalid compressed size") }

        var out: [UInt8] = []
        out.reserveCapacity(decompressedSize)

        if flags & 1 != 1 {
            guard Int(compressedSize - headerLength) == decompressedSize, pos + decompressedSize <= input.count else {
                throw CorruptData(reason: "stored size mismatch")
            }
            return Array(input[pos..<pos + decompressedSize])
        }

        var hashtable = [UInt32](repeating: 0, count: hashtableSize)
        var nextHashed = 0
        var control: UInt32 = 1

        func hash(_ i: Int) -> Int {
            let v = UInt32(out[i]) | UInt32(out[i + 1]) << 8 | UInt32(out[i + 2]) << 16
            return Int(((v >> 12) ^ v) & 0xfff)
        }
        func updateHashtable(from start: Int, to end: Int) {
            guard start < end else { return }
            for i in start..<end { hashtable[hash(i)] = UInt32(i) }
        }
        func copyFromHistory(start: Int, length: Int) throws {
            guard start < out.count else { throw CorruptData(reason: "reference outside output") }
            for i in 0..<length { out.append(out[start + i]) }
        }

        while true {
            if control == 1 {
                control = try readU32LE()
            }
            if control & 1 == 1 {
                control >>= 1
                let next = try readU8()
                if level == 1 {
                    var matchLength = Int(next & 0xf)
                    let h = Int((next >> 4) | (try readU8() << 4))
                    if matchLength != 0 {
                        matchLength += 2
                    } else {
                        matchLength = Int(try readU8())
                    }
                    guard matchLength >= 3 else { throw CorruptData(reason: "match too short") }
                    guard out.count + matchLength <= decompressedSize else { throw CorruptData(reason: "size exceeded") }
                    try copyFromHistory(start: Int(hashtable[h]), length: matchLength)
                    updateHashtable(from: nextHashed, to: out.count + 1 - matchLength)
                    nextHashed = out.count
                } else {
                    let offset: UInt32
                    let matchLength: UInt32
                    if next & 0b11 == 0 {
                        matchLength = 3
                        offset = next >> 2
                    } else if next & 0b11 == 0b01 {
                        matchLength = 3
                        offset = (next >> 2) | (try readU8() << 6)
                    } else if next & 0b11 == 0b10 {
                        matchLength = 3 + ((next >> 2) & 0xf)
                        offset = (next >> 6) | (try readU8() << 2)
                    } else if next & 0x7f == 0b11 {
                        let n2 = try readU8(), n3 = try readU8(), n4 = try readU8()
                        matchLength = 3 + ((next >> 7) | ((n2 & 0x7f) << 1))
                        offset = (n2 >> 7) | (n3 << 1) | (n4 << 9)
                    } else {
                        matchLength = 2 + ((next >> 2) & 0x1f)
                        let a = try readU8(), b = try readU8()
                        offset = (next >> 7) | (a << 1) | (b << 9)
                    }
                    guard Int(offset) <= out.count else { throw CorruptData(reason: "offset too large") }
                    guard out.count + Int(matchLength) <= decompressedSize else { throw CorruptData(reason: "size exceeded") }
                    try copyFromHistory(start: out.count - Int(offset), length: Int(matchLength))
                }
            } else if out.count >= max(decompressedSize, 10) - 10 {
                while out.count < decompressedSize {
                    if control == 1 {
                        _ = try readU32LE()
                    }
                    control >>= 1
                    out.append(UInt8(try readU8()))
                }
                break
            } else {
                guard out.count + 1 <= decompressedSize else { throw CorruptData(reason: "size exceeded") }
                out.append(UInt8(try readU8()))
                control >>= 1
                if level == 1 {
                    let end = max(out.count - 2, 0)
                    updateHashtable(from: nextHashed, to: end)
                    nextHashed = max(nextHashed, end)
                }
            }
        }
        return out
    }
}
