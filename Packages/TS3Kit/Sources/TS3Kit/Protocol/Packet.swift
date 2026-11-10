import Foundation

public enum TS3Error: Error, LocalizedError, Sendable {
    case protocolViolation(String)
    case timeout(String)
    case server(id: Int, message: String, extra: String?)
    case disconnected(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .protocolViolation(let m): "Protocol error: \(m)"
        case .timeout(let m): "Timed out: \(m)"
        case .server(let id, let message, let extra):
            "Server error \(id): \(message)" + (extra.map { " (\($0))" } ?? "")
        case .disconnected(let m): "Disconnected: \(m)"
        case .notConnected: "Not connected"
        }
    }
}

public enum PacketType: UInt8, Sendable, CaseIterable {
    case voice = 0, voiceWhisper, command, commandLow, ping, pong, ack, ackLow, init1
}

struct PacketFlags: OptionSet, Sendable {
    let rawValue: UInt8
    static let unencrypted = PacketFlags(rawValue: 0x80)
    static let compressed = PacketFlags(rawValue: 0x40)
    static let newProtocol = PacketFlags(rawValue: 0x20)
    static let fragmented = PacketFlags(rawValue: 0x10)
}

/// One UDP datagram (ts3protocol.md 1.1).
struct Packet {
    static let maxSize = 500
    static let c2sHeaderLength = 13
    static let s2cHeaderLength = 11

    var mac: [UInt8] = [UInt8](repeating: 0, count: 8)
    var packetId: UInt16
    var clientId: UInt16 = 0 // only present client -> server
    var type: PacketType
    var flags: PacketFlags
    var payload: [UInt8]

    /// The EAX header ("meta"): everything after the MAC.
    func meta(toServer: Bool) -> [UInt8] {
        var m: [UInt8] = [UInt8(packetId >> 8), UInt8(packetId & 0xff)]
        if toServer { m += [UInt8(clientId >> 8), UInt8(clientId & 0xff)] }
        m.append(flags.rawValue | type.rawValue)
        return m
    }

    func encodeToServer() -> [UInt8] { mac + meta(toServer: true) + payload }

    /// Parses a server -> client datagram.
    static func decodeFromServer(_ data: [UInt8]) -> Packet? {
        guard data.count >= s2cHeaderLength else { return nil }
        let typeByte = data[10]
        guard let type = PacketType(rawValue: typeByte & 0x0f) else { return nil }
        return Packet(
            mac: Array(data[0..<8]),
            packetId: UInt16(data[8]) << 8 | UInt16(data[9]),
            type: type,
            flags: PacketFlags(rawValue: typeByte & 0xf0),
            payload: Array(data[11...])
        )
    }
}

extension Array where Element == UInt8 {
    func readU16(_ at: Int) -> UInt16 { UInt16(self[at]) << 8 | UInt16(self[at + 1]) }
    func readU32(_ at: Int) -> UInt32 {
        UInt32(self[at]) << 24 | UInt32(self[at + 1]) << 16 | UInt32(self[at + 2]) << 8 | UInt32(self[at + 3])
    }
    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func u32(_ v: UInt32) -> [UInt8] { Swift.withUnsafeBytes(of: v.bigEndian, Array.init) }
}
