import Foundation

/// A channel as tracked from `channellist` and the channel notifications (Book.toml `Channel`).
public struct ChannelInfo: Identifiable, Hashable, Sendable {
    public let id: UInt64
    public var parentId: UInt64 = 0
    /// Id of the preceding sibling; 0 means first.
    public var order: UInt64 = 0
    public var name = ""
    public var topic = ""
    public var codec: UInt8 = 4
    public var codecQuality = 6
    public var maxClients = -1
    public var hasPassword = false
    public var isDefault = false
    public var isPermanent = false
    public var isSemiPermanent = false
    public var isUnencrypted = true
    public var neededTalkPower = 0
    /// Loaded on demand with `channelgetdescription`; nil until then.
    public var description: String?

    public var isTemporary: Bool { !isPermanent && !isSemiPermanent }
    public var isSpacer: Bool { name.hasPrefix("[") && name.contains("spacer") }

    mutating func apply(_ e: [String: String]) {
        if let v = e.uint64("cpid") { parentId = v }
        if let v = e.uint64("channel_order") { order = v }
        if let v = e.uint64("order") { order = v }
        if let v = e["channel_name"] { name = v }
        if let v = e["channel_topic"] { topic = v }
        if let v = e.int("channel_codec") { codec = UInt8(clamping: v) }
        if let v = e.int("channel_codec_quality") { codecQuality = v }
        if let v = e.int("channel_maxclients") { maxClients = v }
        if e.bool("channel_flag_maxclients_unlimited") == true { maxClients = -1 }
        if let v = e.bool("channel_flag_password") { hasPassword = v }
        if let v = e.bool("channel_flag_default") { isDefault = v }
        if let v = e.bool("channel_flag_permanent") { isPermanent = v }
        if let v = e.bool("channel_flag_semi_permanent") { isSemiPermanent = v }
        if let v = e.bool("channel_codec_is_unencrypted") { isUnencrypted = v }
        if let v = e.int("channel_needed_talk_power") { neededTalkPower = v }
        if let v = e["channel_description"] { description = v }
    }

    /// Human-readable codec name (Enums.toml `Codec`).
    public var codecName: String {
        switch codec {
        case 0: "Speex Narrowband"
        case 1: "Speex Wideband"
        case 2: "Speex Ultra-Wideband"
        case 3: "CELT Mono"
        case 4: "Opus Voice"
        case 5: "Opus Music"
        default: "Unknown (\(codec))"
        }
    }
}

/// A client as tracked from `notifycliententerview` and updates (Book.toml `Client`).
public struct ClientInfo: Identifiable, Hashable, Sendable {
    public let id: UInt16
    public var channelId: UInt64 = 0
    public var nickname = ""
    public var uid = ""
    public var databaseId: UInt64 = 0
    public var isQuery = false
    public var inputMuted = false
    public var outputMuted = false
    public var outputOnlyMuted = false
    public var inputHardware = true
    public var outputHardware = true
    public var isAway = false
    public var awayMessage = ""
    public var talkPower = 0
    public var isTalker = false
    public var isRecording = false
    public var isChannelCommander = false
    public var isPrioritySpeaker = false
    public var country = ""
    public var serverGroups: [UInt64] = []
    public var channelGroupId: UInt64 = 0
    public var description = ""
    public var version = ""
    public var platform = ""
    /// Start of this client's current connection: from `getconnectioninfo`, or when we saw them connect.
    public var connectedSince: Date?

    mutating func apply(_ e: [String: String]) {
        if let v = e.uint64("ctid") { channelId = v }
        if let v = e["client_nickname"] { nickname = v }
        if let v = e["client_unique_identifier"] { uid = v }
        if let v = e.uint64("client_database_id") { databaseId = v }
        if let v = e.int("client_type") { isQuery = v == 1 }
        if let v = e.bool("client_input_muted") { inputMuted = v }
        if let v = e.bool("client_output_muted") { outputMuted = v }
        if let v = e.bool("client_outputonly_muted") { outputOnlyMuted = v }
        if let v = e.bool("client_input_hardware") { inputHardware = v }
        if let v = e.bool("client_output_hardware") { outputHardware = v }
        if let v = e.bool("client_away") { isAway = v }
        if let v = e["client_away_message"] { awayMessage = v }
        if let v = e.int("client_talk_power") { talkPower = v }
        if let v = e.bool("client_is_talker") { isTalker = v }
        if let v = e.bool("client_is_recording") { isRecording = v }
        if let v = e.bool("client_is_channel_commander") { isChannelCommander = v }
        if let v = e.bool("client_is_priority_speaker") { isPrioritySpeaker = v }
        if let v = e["client_country"] { country = v }
        if let v = e["client_servergroups"] { serverGroups = v.split(separator: ",").compactMap { UInt64($0) } }
        if let v = e.uint64("client_channel_group_id") { channelGroupId = v }
        if let v = e["client_description"] { description = v }
        if let v = e["client_version"] { version = v }
        if let v = e["client_platform"] { platform = v }
    }
}

public struct ServerInfo: Sendable, Equatable {
    public var name = ""
    public var welcomeMessage = ""
    public var platform = ""
    public var version = ""
    /// 0 = per channel, 1 = globally off, 2 = globally on (Enums.toml `CodecEncryptionMode`).
    public var codecEncryptionMode = 0
    public var maxClients = 0
    public var hostMessage = ""
}

/// A server or channel group (`notifyservergrouplist` / `notifychannelgrouplist`).
public struct GroupInfo: Identifiable, Hashable, Sendable {
    public enum NameMode: Int, Sendable { case none = 0, before = 1, after = 2 }
    public let id: UInt64
    public var name = ""
    public var sortId = 0
    public var nameMode = NameMode.none

    init(id: UInt64, _ e: [String: String]) {
        self.id = id
        name = e["name"] ?? ""
        sortId = e.int("sortid") ?? 0
        nameMode = NameMode(rawValue: e.int("namemode") ?? 0) ?? .none
    }
}

/// Which chat tab a message belongs to (Enums.toml `TextMessageTargetMode`).
public enum ChatTarget: Hashable, Sendable {
    case server
    case channel
    /// Private chat, keyed by the other client's unique id so it survives reconnects of that client.
    case client(uid: String)
}

public struct ChatMessage: Identifiable, Sendable {
    public enum Kind: Sendable { case message, event, error, poke }
    /// How an event should feel: good news (connected), bad news (kicked, lost) or neither.
    public enum Tone: Sendable { case neutral, positive, negative }
    public let id = UUID()
    public let date = Date()
    public let kind: Kind
    public var tone = Tone.neutral
    public var sender = ""
    public var isOwn = false
    /// Chat text (BBCode) for messages and pokes.
    public let text: String
    /// Structured text for events, so names and channels can be styled.
    public var parts: [EventText.Part] = []

    public init(kind: Kind, sender: String = "", isOwn: Bool = false, text: String) {
        self.kind = kind
        self.sender = sender
        self.isOwn = isOwn
        self.text = text
    }

    public init(event: EventText, tone: Tone = .neutral, kind: Kind = .event) {
        self.kind = kind
        self.tone = tone
        self.parts = event.parts
        self.text = event.plain
    }
}

/// Event text with marked-up names: `"\(client: nick) joined \(channel: name)"`.
public struct EventText: ExpressibleByStringInterpolation, Sendable {
    public enum Part: Hashable, Sendable {
        case text(String)
        case client(String)
        case channel(String)
        case group(String)
        case server(String)

        public var string: String {
            switch self {
            case .text(let s), .client(let s), .channel(let s), .group(let s), .server(let s): s
            }
        }
    }

    public var parts: [Part]
    public var plain: String { parts.map(\.string).joined() }

    public init(stringLiteral value: String) { parts = [.text(value)] }
    public init(stringInterpolation: StringInterpolation) { parts = stringInterpolation.parts }

    public struct StringInterpolation: StringInterpolationProtocol {
        var parts: [Part] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { if !literal.isEmpty { parts.append(.text(literal)) } }
        public mutating func appendInterpolation(_ text: String) { parts.append(.text(text)) }
        public mutating func appendInterpolation(client: String) { parts.append(.client(client)) }
        public mutating func appendInterpolation(channel: String) { parts.append(.channel(channel)) }
        public mutating func appendInterpolation(group: String) { parts.append(.group(group)) }
        public mutating func appendInterpolation(server: String) { parts.append(.server(server)) }
        public mutating func appendInterpolation(_ event: EventText) { parts += event.parts }
    }
}

public struct PrivateChat: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public let uid: String
    public var nickname: String
    /// Current client id, nil while the other side is not on the server.
    public var clientId: UInt16?
}

/// Things worth a sound (the official client's sound pack events, minus those this client has no feature for).
/// "User" events only fire for other people in your channel.
public enum ClientEvent: String, CaseIterable, Sendable {
    // Connection
    case connected, disconnected, connectionLost
    // You
    case channelSwitched, youWereMoved, youWereKickedFromChannel, youWereKickedFromServer, youWereBanned, youWerePoked
    case talkPowerGranted, talkPowerRevoked, serverGroupAssigned, serverGroupRevoked, channelGroupChanged
    case insufficientPermissions, error
    // Other users in your channel
    case userConnected, userDisconnected, userLostConnection
    case userJoinedChannel, userLeftChannel, userMovedIn, userMovedOut
    case userKickedFromChannel, userKickedFromServer, userBanned
    case userStartedRecording, userStoppedRecording
    // Chat
    case messageReceived, messageSent
}
