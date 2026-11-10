import Foundation
import Observation
import Synchronization

/// High-level client: owns a `Connection`, keeps the server state (channels, clients, groups, chats)
/// up to date from notifications, and exposes the user actions.
@MainActor
@Observable
public final class TS3Client {
    public enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public private(set) var status = Status.disconnected
    public private(set) var server = ServerInfo()
    public private(set) var ownClientId: UInt16 = 0
    public private(set) var channels: [UInt64: ChannelInfo] = [:]
    public private(set) var clients: [UInt16: ClientInfo] = [:]
    public private(set) var serverGroups: [UInt64: GroupInfo] = [:]
    public private(set) var channelGroups: [UInt64: GroupInfo] = [:]
    public private(set) var talking: Set<UInt16> = []
    /// Whether the channel list has been fully received.
    public private(set) var isReady = false
    /// Smoothed round-trip time to the server; nil until measured.
    public private(set) var ping: Duration?
    /// Whether this connection got as far as being accepted by the server.
    public private(set) var wasConnected = false
    /// Why the server removed us (`reasonid`: 5 kicked, 6 banned, 7/11 shutdown); nil otherwise.
    public private(set) var removalReason: Int?

    /// Chat history per tab. The server tab also carries connection events.
    public private(set) var messages: [ChatTarget: [ChatMessage]] = [:]
    public private(set) var privateChats: [PrivateChat] = []
    public private(set) var unread: [ChatTarget: Int] = [:]
    /// The tab the user is looking at; messages arriving there don't count as unread.
    public var activeChat: ChatTarget = .server {
        didSet { unread[activeChat] = nil }
    }

    /// Receives voice on the connection's queue: (client id, codec, opus data; empty = end).
    @ObservationIgnored public nonisolated(unsafe) var voiceSink: (@Sendable (UInt16, UInt8, [UInt8]) -> Void)?
    /// Called when we enter a channel, with its codec and quality.
    @ObservationIgnored public var onOwnChannelChanged: ((ChannelInfo) -> Void)?
    /// Called when the connection is gone.
    @ObservationIgnored public var onDisconnected: (() -> Void)?
    /// A chat message or poke from someone else arrived: (message, tab it went to).
    @ObservationIgnored public var onIncomingMessage: ((ChatMessage, ChatTarget) -> Void)?
    /// Notable events, e.g. for sounds.
    @ObservationIgnored public var onEvent: ((ClientEvent) -> Void)?

    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var talkTimer: Task<Void, Never>?
    @ObservationIgnored private var nextReturnCode = 1
    @ObservationIgnored private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    /// Return codes of background requests whose errors are not worth showing.
    @ObservationIgnored private var silentCodes: Set<String> = []
    @ObservationIgnored private var requestedDetails: Set<UInt16> = []
    /// When the server accepted us; our own client's connection time.
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private let lastVoice = VoiceActivity()

    public init() {}

    // MARK: - Derived state

    public var ownClient: ClientInfo? { clients[ownClientId] }
    public var ownChannel: ChannelInfo? { ownClient.flatMap { channels[$0.channelId] } }
    public var isMicMuted: Bool { ownClient?.inputMuted ?? false }
    public var isOutputMuted: Bool { ownClient?.outputMuted ?? false }
    public var isAway: Bool { ownClient?.isAway ?? false }

    /// Children of `parentId` in display order (following each channel's `order` = preceding sibling).
    public func childChannels(of parentId: UInt64) -> [ChannelInfo] {
        let siblings = channels.values.filter { $0.parentId == parentId }
        var byPredecessor: [UInt64: ChannelInfo] = [:]
        for c in siblings { byPredecessor[c.order] = c }
        var result: [ChannelInfo] = []
        var seen = Set<UInt64>()
        var cursor: UInt64 = 0
        while let next = byPredecessor[cursor], !seen.contains(next.id) {
            result.append(next)
            seen.insert(next.id)
            cursor = next.id
        }
        // Anything not reachable via the order chain (inconsistent data) goes last.
        result += siblings.filter { !seen.contains($0.id) }.sorted { $0.id < $1.id }
        return result
    }

    /// Clients in a channel, highest talk power first, then by name (like the official client).
    public func clients(in channelId: UInt64) -> [ClientInfo] {
        clients.values
            .filter { $0.channelId == channelId && !$0.isQuery }
            .sorted {
                if $0.talkPower != $1.talkPower { return $0.talkPower > $1.talkPower }
                return $0.nickname.localizedCaseInsensitiveCompare($1.nickname) == .orderedAscending
            }
    }

    /// Server groups of a client, in the server's sort order.
    public func serverGroups(of client: ClientInfo) -> [GroupInfo] {
        client.serverGroups.compactMap { serverGroups[$0] }
            .sorted { ($0.sortId, $0.id) < ($1.sortId, $1.id) }
    }

    /// Nickname with group tags, e.g. `[Admin] Alice`, following each group's name mode.
    public func displayName(_ client: ClientInfo) -> String {
        var groups = serverGroups(of: client)
        if let channelGroup = channelGroups[client.channelGroupId] { groups.append(channelGroup) }
        let before = groups.filter { $0.nameMode == .before }.map { "[\($0.name)]" }
        let after = groups.filter { $0.nameMode == .after }.map { "[\($0.name)]" }
        return (before + [client.nickname] + after).joined(separator: " ")
    }

    public func client(uid: String) -> ClientInfo? {
        clients.values.first { $0.uid == uid }
    }

    // MARK: - Actions

    public func connect(_ options: ConnectOptions) {
        disconnectImmediately()
        status = .connecting
        isReady = false
        ping = nil
        wasConnected = false
        removalReason = nil
        messages[.channel] = nil
        unread[.channel] = nil
        if case .client = activeChat { activeChat = .server }
        for chat in privateChats { messages[.client(uid: chat.uid)] = nil; unread[.client(uid: chat.uid)] = nil }
        privateChats.removeAll()
        event("Connecting to \(server: "\(options.host):\(options.port)")…")
        let connection = Connection(options: options)
        let lastVoice = self.lastVoice
        let sinkOwner = self
        connection.voiceHandler = { clientId, codec, data, _ in
            lastVoice.map.withLock { $0[clientId] = data.isEmpty ? nil : Date() }
            sinkOwner.voiceSink?(clientId, codec, data)
        }
        connection.pingHandler = { [weak self] seconds in
            Task { @MainActor in self?.updatePing(seconds) }
        }
        self.connection = connection
        eventTask = Task { [weak self] in
            for await event in connection.events {
                self?.handle(event)
            }
        }
        startTalkTimer()
        connection.start()
    }

    public func disconnect(reason: String = "leaving") {
        guard let connection else { return }
        event("Disconnecting…")
        connection.disconnect(reason: reason)
    }

    public func join(channel: UInt64, password: String = "") async throws {
        var args: [(String, String?)] = [("clid", String(ownClientId)), ("cid", String(channel))]
        if !password.isEmpty { args.append(("cpw", ts3HashPassword(password))) }
        try await request(Command("clientmove", args))
    }

    public func setMicMuted(_ muted: Bool) async throws {
        try await updateSelf([("client_input_muted", muted ? "1" : "0")]) { $0.inputMuted = muted }
    }

    public func setOutputMuted(_ muted: Bool) async throws {
        try await updateSelf([("client_output_muted", muted ? "1" : "0")]) { $0.outputMuted = muted }
    }

    public func setAway(_ away: Bool, message: String = "") async throws {
        var args: [(String, String?)] = [("client_away", away ? "1" : "0")]
        if away { args.append(("client_away_message", message)) }
        try await updateSelf(args) {
            $0.isAway = away
            $0.awayMessage = away ? message : ""
        }
    }

    public func setNickname(_ nickname: String) async throws {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ownClient?.nickname else { return }
        try await request(Command("clientupdate", [("client_nickname", trimmed)]))
    }

    // MARK: - Moderation (the server decides whether we may)

    /// Moves another client (or us) to a channel.
    public func move(client: UInt16, to channel: UInt64, password: String = "") async throws {
        var args: [(String, String?)] = [("clid", String(client)), ("cid", String(channel))]
        if !password.isEmpty { args.append(("cpw", ts3HashPassword(password))) }
        try await request(Command("clientmove", args))
    }

    public func poke(client: UInt16, message: String) async throws {
        try await request(Command("clientpoke", [("clid", String(client)), ("msg", message)]))
    }

    public func kickFromChannel(client: UInt16, reason: String) async throws {
        try await request(Command("clientkick", [("clid", String(client)), ("reasonid", "4"), ("reasonmsg", reason)]))
    }

    public func kickFromServer(client: UInt16, reason: String) async throws {
        try await request(Command("clientkick", [("clid", String(client)), ("reasonid", "5"), ("reasonmsg", reason)]))
    }

    /// Bans a client; `duration` nil means permanently.
    public func ban(client: UInt16, duration: Duration?, reason: String) async throws {
        let seconds = duration.map { String($0.components.seconds) } ?? "0"
        try await request(Command("banclient", [("clid", String(client)), ("time", seconds), ("banreason", reason)]))
    }

    /// Sends a chat message. The server echoes it back, which is what adds it to the history.
    public func send(text: String, to target: ChatTarget) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var args: [(String, String?)]
        switch target {
        case .server:
            args = [("targetmode", "3")]
        case .channel:
            args = [("targetmode", "2")]
        case .client(let uid):
            guard let other = client(uid: uid) else {
                add(ChatMessage(event: "\(client: privateChats.first { $0.uid == uid }?.nickname ?? "They") is not on the server", tone: .negative, kind: .error), to: target)
                return
            }
            args = [("targetmode", "1"), ("target", String(other.id))]
        }
        args.append(("msg", Self.linkifyURLs(trimmed)))
        try await request(Command("sendtextmessage", args))
    }

    /// Opens (or reuses) the private chat tab with a client.
    @discardableResult
    public func openPrivateChat(with client: ClientInfo) -> ChatTarget {
        ensurePrivateChat(uid: client.uid, nickname: client.nickname, clientId: client.id)
        return .client(uid: client.uid)
    }

    public func closePrivateChat(uid: String) {
        privateChats.removeAll { $0.uid == uid }
        messages[.client(uid: uid)] = nil
        unread[.client(uid: uid)] = nil
        if activeChat == .client(uid: uid) { activeChat = .server }
    }

    /// Fetches a channel's description once; it then stays in `channels[id].description`.
    public func loadDescription(of channelId: UInt64) {
        guard channels[channelId]?.description == nil else { return }
        sendSilently(Command("channelgetdescription", [("cid", String(channelId))]))
    }

    /// Fetches version, platform, connection time and other details of a client once per connection.
    public func loadDetails(of clientId: UInt16) {
        guard clients[clientId] != nil, !requestedDetails.contains(clientId) else { return }
        requestedDetails.insert(clientId)
        sendSilently(Command("clientgetvariables", [("clid", String(clientId))]))
        // Answered with `notifyconnectioninfo`; servers may deny it without the view permission.
        sendSilently(Command("getconnectioninfo", [("clid", String(clientId))]))
    }

    /// Thread-safe handle for sending voice from audio threads.
    public var voiceSender: (@Sendable (UInt8, [UInt8]) -> Void)? {
        guard let connection else { return nil }
        return { codec, data in connection.sendVoice(codec: codec, data: data) }
    }

    // MARK: - Requests with return codes

    private func updateSelf(_ args: [(String, String?)], optimistic: (inout ClientInfo) -> Void) async throws {
        if var me = clients[ownClientId] {
            optimistic(&me)
            clients[ownClientId] = me
        }
        try await request(Command("clientupdate", args))
    }

    private func takeReturnCode() -> String {
        defer { nextReturnCode += 1 }
        return String(nextReturnCode)
    }

    private func request(_ command: Command) async throws {
        guard let connection, status == .connected else { throw TS3Error.notConnected }
        let code = takeReturnCode()
        let encoded = command.encoded + " return_code=\(code)"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pending[code] = cont
            connection.send(Command.raw(encoded))
        }
    }

    private func sendSilently(_ command: Command) {
        guard let connection, status == .connected else { return }
        let code = takeReturnCode()
        silentCodes.insert(code)
        connection.send(Command.raw(command.encoded + " return_code=\(code)"))
    }

    // MARK: - Events

    private func handle(_ event: ConnectionEvent) {
        switch event {
        case .connected(let id):
            ownClientId = id
            connectedAt = Date()
            wasConnected = true
            status = .connected
        case .command(let command):
            handle(command)
        case .voice(let clientId, let codec, let data, _):
            voiceSink?(clientId, codec, data)
        case .closed(let error):
            if let error {
                status = .failed(error.localizedDescription)
                add(ChatMessage(event: "\(error.localizedDescription)", tone: .negative, kind: .error), to: .server)
                if wasConnected { onEvent?(.connectionLost) }
            } else {
                status = .disconnected
                self.event("Disconnected")
                // A kick or ban already had its own sound.
                if wasConnected && removalReason == nil { onEvent?(.disconnected) }
            }
            resetState()
        }
    }

    private func handle(_ c: Command) {
        switch c.name {
        case "initserver":
            let a = c.first
            server.name = a["virtualserver_name"] ?? ""
            server.welcomeMessage = a["virtualserver_welcomemessage"] ?? ""
            server.platform = a["virtualserver_platform"] ?? ""
            server.version = a["virtualserver_version"] ?? ""
            server.codecEncryptionMode = a.int("virtualserver_codec_encryption_mode") ?? 0
            server.maxClients = a.int("virtualserver_maxclients") ?? 0
            server.hostMessage = a["virtualserver_hostmessage"] ?? ""
            event("Connected to server \(server: server.name)", tone: .positive)
            onEvent?(.connected)
            if !server.welcomeMessage.isEmpty {
                var welcome = ChatMessage(kind: .message, text: server.welcomeMessage)
                welcome.tone = .positive
                add(welcome, to: .server, countsAsUnread: false)
            }
        case "notifyserveredited":
            if let n = c.first["virtualserver_name"] { server.name = n }
        case "channellist":
            for e in c.entries {
                guard let id = e.uint64("cid") else { continue }
                var ch = channels[id] ?? ChannelInfo(id: id)
                ch.apply(e)
                channels[id] = ch
            }
        case "channellistfinished":
            isReady = true
            connection?.send(Command("channelsubscribeall"))
            ownChannelChanged()
            // Servers normally push the group lists right after the channel list; ask if they didn't.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.status == .connected else { return }
                if self.serverGroups.isEmpty { self.sendSilently(Command("servergrouplist")) }
                if self.channelGroups.isEmpty { self.sendSilently(Command("channelgrouplist")) }
            }
        case "notifychannelcreated", "notifychanneledited", "notifychannelmoved":
            for e in c.entries {
                guard let id = e.uint64("cid") else { continue }
                var ch = channels[id] ?? ChannelInfo(id: id)
                ch.apply(e)
                channels[id] = ch
                if id == ownClient?.channelId { ownChannelChanged() }
            }
        case "notifychanneldescriptionchanged":
            for e in c.entries {
                guard let id = e.uint64("cid"), channels[id]?.description != nil else { continue }
                channels[id]?.description = nil
                loadDescription(of: id)
            }
        case "notifychanneldeleted":
            for e in c.entries { if let id = e.uint64("cid") { channels[id] = nil } }
        case "notifyservergrouplist":
            for e in c.entries {
                guard let id = e.uint64("sgid") else { continue }
                serverGroups[id] = GroupInfo(id: id, e)
            }
        case "notifychannelgrouplist":
            for e in c.entries {
                guard let id = e.uint64("cgid") else { continue }
                channelGroups[id] = GroupInfo(id: id, e)
            }
        case "notifyservergroupclientadded", "notifyservergroupclientdeleted":
            let added = c.name == "notifyservergroupclientadded"
            for e in c.entries {
                guard let id = clientId(e["clid"]), let sgid = e.uint64("sgid") else { continue }
                clients[id]?.serverGroups.removeAll { $0 == sgid }
                if added { clients[id]?.serverGroups.append(sgid) }
                let group = e["name"] ?? serverGroups[sgid]?.name ?? "?"
                let who = clients[id]?.nickname ?? "?"
                if id == ownClientId && isReady && byUser(e) {
                    onEvent?(added ? .serverGroupAssigned : .serverGroupRevoked)
                }
                event(added ? "Server group \(group: group) was assigned to \(client: who)\(by(e))"
                            : "Server group \(group: group) was removed from \(client: who)\(by(e))")
            }
        case "notifyclientchannelgroupchanged":
            for e in c.entries {
                guard let id = clientId(e["clid"]), let cgid = e.uint64("cgid") else { continue }
                clients[id]?.channelGroupId = cgid
                if isReady, let who = clients[id]?.nickname {
                    if id == ownClientId && byUser(e) { onEvent?(.channelGroupChanged) }
                    event("Channel group \(group: channelGroups[cgid]?.name ?? "?") was assigned to \(client: who)\(by(e))")
                }
            }
        case "notifycliententerview":
            for e in c.entries {
                guard let id = clientId(e["clid"]) else { continue }
                var cl = clients[id] ?? ClientInfo(id: id)
                cl.apply(e)
                if cl.connectedSince == nil {
                    if id == ownClientId {
                        cl.connectedSince = connectedAt
                    } else if isReady && (e.int("reasonid") ?? 0) == 0 {
                        cl.connectedSince = Date() // connected just now, while we watched
                    }
                }
                clients[id] = cl
                if let index = privateChats.firstIndex(where: { $0.uid == cl.uid }) {
                    privateChats[index].clientId = id
                    privateChats[index].nickname = cl.nickname
                    add(ChatMessage(event: "\(client: cl.nickname) is back on the server", tone: .positive), to: .client(uid: cl.uid), countsAsUnread: false)
                }
                if id == ownClientId {
                    ownChannelChanged()
                } else if isReady && !cl.isQuery && (e.int("reasonid") ?? 0) == 0 {
                    event("\(client: cl.nickname) connected to channel \(channel: channelName(cl.channelId))")
                    if cl.channelId == ownClient?.channelId {
                        onEvent?(.userConnected)
                        add(ChatMessage(event: "\(client: cl.nickname) connected"), to: .channel, countsAsUnread: false)
                    }
                }
            }
        case "notifyclientleftview":
            for e in c.entries {
                guard let id = clientId(e["clid"]) else { continue }
                let reason = e.int("reasonid") ?? 8
                let message = e["reasonmsg"].flatMap { $0.isEmpty ? nil : $0 }
                if id == ownClientId {
                    removalReason = reason
                    switch reason {
                    case 5: onEvent?(.youWereKickedFromServer)
                    case 6: onEvent?(.youWereBanned)
                    default: onEvent?(.disconnected)
                    }
                    switch reason {
                    case 5: event("You were kicked from the server\(by(e))\(suffix(message))", tone: .negative)
                    case 6: event("You were banned from the server\(by(e))\(suffix(message))", tone: .negative)
                    case 7, 11: event("The server shut down\(suffix(message))", tone: .negative)
                    default: event("Removed from the server\(suffix(message))", tone: .negative)
                    }
                    // The server is done with us; close now instead of waiting for the timeout.
                    connection?.disconnect(reason: "")
                    continue
                }
                requestedDetails.remove(id)
                guard let cl = clients.removeValue(forKey: id) else { continue }
                if let index = privateChats.firstIndex(where: { $0.uid == cl.uid }) {
                    privateChats[index].clientId = nil
                    add(ChatMessage(event: "\(client: cl.nickname) left the server"), to: .client(uid: cl.uid), countsAsUnread: false)
                }
                guard isReady, !cl.isQuery, reason != 2 else { continue }
                let who = cl.nickname
                switch reason {
                case 3: event("\(client: who) timed out (lost connection)", tone: .negative)
                case 5: event("\(client: who) was kicked from the server\(by(e))\(suffix(message))", tone: .negative)
                case 6: event("\(client: who) was banned\(by(e))\(suffix(message))", tone: .negative)
                default: event("\(client: who) disconnected\(suffix(message))")
                }
                if cl.channelId == ownClient?.channelId {
                    add(ChatMessage(event: "\(client: who) left the server"), to: .channel, countsAsUnread: false)
                    switch reason {
                    case 3: onEvent?(.userLostConnection)
                    case 5: onEvent?(.userKickedFromServer)
                    case 6: onEvent?(.userBanned)
                    default: onEvent?(.userDisconnected)
                    }
                }
            }
        case "notifyclientmoved":
            for e in c.entries {
                guard let id = clientId(e["clid"]), let to = e.uint64("ctid") else { continue }
                let from = clients[id]?.channelId
                clients[id]?.channelId = to
                let target = channelName(to)
                let source = from.map(channelName) ?? "?"
                let reason = e.int("reasonid") ?? 0
                let isSelf = id == ownClientId
                guard let who = isSelf ? "You" : clients[id]?.nickname, isSelf || !(clients[id]?.isQuery ?? true) else { continue }
                let subject: EventText = isSelf ? "You" : "\(client: who)"
                switch reason {
                case 1: event("\(subject) \(isSelf ? "were" : "was") moved from \(channel: source) to \(channel: target)\(by(e))")
                case 4: event("\(subject) \(isSelf ? "were" : "was") kicked from channel \(channel: source)\(by(e))\(suffix(e["reasonmsg"]))", tone: .negative)
                default: event("\(subject) switched from channel \(channel: source) to \(channel: target)")
                }
                if isSelf {
                    ownChannelChanged()
                    add(ChatMessage(event: "You are now in \(channel: target)"), to: .channel, countsAsUnread: false)
                    switch reason {
                    case 1: onEvent?(.youWereMoved)
                    case 4: onEvent?(.youWereKickedFromChannel)
                    default: onEvent?(.channelSwitched)
                    }
                } else if to == ownClient?.channelId {
                    add(ChatMessage(event: "\(client: who) joined the channel"), to: .channel, countsAsUnread: false)
                    onEvent?(reason == 0 ? .userJoinedChannel : .userMovedIn)
                } else if from == ownClient?.channelId {
                    add(ChatMessage(event: "\(client: who) left to \(channel: target)"), to: .channel, countsAsUnread: false)
                    switch reason {
                    case 1: onEvent?(.userMovedOut)
                    case 4: onEvent?(.userKickedFromChannel)
                    default: onEvent?(.userLeftChannel)
                    }
                }
            }
        case "notifyconnectioninfo":
            for e in c.entries {
                guard let id = clientId(e["clid"]), let ms = e.uint64("connection_connected_time") else { continue }
                clients[id]?.connectedSince = Date().addingTimeInterval(-Double(ms) / 1000)
            }
        case "notifyclientupdated":
            for e in c.entries {
                guard let id = clientId(e["clid"]) else { continue }
                let before = clients[id]
                clients[id]?.apply(e)
                if isReady, let before, let after = clients[id] {
                    if id == ownClientId, before.isTalker != after.isTalker {
                        onEvent?(after.isTalker ? .talkPowerGranted : .talkPowerRevoked)
                    } else if id != ownClientId, after.channelId == ownClient?.channelId, before.isRecording != after.isRecording {
                        onEvent?(after.isRecording ? .userStartedRecording : .userStoppedRecording)
                    }
                }
                if let cl = clients[id], let index = privateChats.firstIndex(where: { $0.uid == cl.uid }) {
                    privateChats[index].nickname = cl.nickname
                }
            }
        case "notifytextmessage":
            handleTextMessage(c.first)
        case "notifyclientpoke":
            let a = c.first
            var poke = ChatMessage(kind: .poke, sender: a["invokername"] ?? "?", text: a["msg"] ?? "")
            poke.tone = .negative
            add(poke, to: .server)
            onIncomingMessage?(poke, .server)
            onEvent?(.youWerePoked)
        case "error":
            let a = c.first
            let id = a.int("id") ?? 0
            let code = a["return_code"] ?? ""
            if silentCodes.remove(code) != nil { return }
            if let cont = pending.removeValue(forKey: code) {
                if id == 0 {
                    cont.resume()
                } else {
                    let error = TS3Error.server(id: id, message: a["msg"] ?? "", extra: a["extra_msg"])
                    onEvent?(id == 2568 ? .insufficientPermissions : .error)
                    add(ChatMessage(event: "\(error.localizedDescription)", tone: .negative, kind: .error), to: .server)
                    cont.resume(throwing: error)
                }
            } else if id != 0 {
                add(ChatMessage(event: "Server error \(String(id)): \(a["msg"] ?? "")", tone: .negative, kind: .error), to: .server)
            }
        default:
            break
        }
    }

    private func handleTextMessage(_ a: [String: String]) {
        let invokerId = clientId(a["invokerid"]) ?? 0
        let isOwn = invokerId == ownClientId
        let name = a["invokername"] ?? clients[invokerId]?.nickname ?? "?"
        let message = ChatMessage(kind: .message, sender: name, isOwn: isOwn, text: a["msg"] ?? "")
        switch a.int("targetmode") ?? 0 {
        case 1:
            // Our own private messages come back with `target` = the recipient.
            let otherId = isOwn ? (clientId(a["target"]) ?? 0) : invokerId
            guard let other = clients[otherId] else { return }
            ensurePrivateChat(uid: other.uid, nickname: other.nickname, clientId: other.id)
            add(message, to: .client(uid: other.uid))
            if !isOwn { onIncomingMessage?(message, .client(uid: other.uid)) }
            onEvent?(isOwn ? .messageSent : .messageReceived)
        case 2:
            add(message, to: .channel)
            if !isOwn { onIncomingMessage?(message, .channel) }
            onEvent?(isOwn ? .messageSent : .messageReceived)
        default:
            add(message, to: .server)
            if !isOwn { onIncomingMessage?(message, .server) }
            onEvent?(isOwn ? .messageSent : .messageReceived)
        }
    }

    private func ownChannelChanged() {
        guard let ch = ownChannel else { return }
        let mode = server.codecEncryptionMode
        connection?.setVoiceEncryption(mode == 2 || (mode == 0 && !ch.isUnencrypted))
        onOwnChannelChanged?(ch)
    }

    // MARK: - Chat helpers

    private func ensurePrivateChat(uid: String, nickname: String, clientId: UInt16) {
        if let index = privateChats.firstIndex(where: { $0.uid == uid }) {
            privateChats[index].nickname = nickname
            privateChats[index].clientId = clientId
        } else {
            privateChats.append(PrivateChat(uid: uid, nickname: nickname, clientId: clientId))
        }
    }

    private func add(_ message: ChatMessage, to target: ChatTarget, countsAsUnread: Bool = true) {
        var list = messages[target] ?? []
        list.append(message)
        if list.count > 1000 { list.removeFirst(list.count - 1000) }
        messages[target] = list
        if countsAsUnread, !message.isOwn, message.kind != .event, target != activeChat {
            unread[target, default: 0] += 1
        }
    }

    private func event(_ text: EventText, tone: ChatMessage.Tone = .neutral) {
        add(ChatMessage(event: text, tone: tone), to: .server, countsAsUnread: tone == .negative && isReady)
    }

    /// " by <invoker>", or " by <server>" when the server itself did it.
    private func by(_ e: [String: String]) -> EventText {
        guard let name = e["invokername"], !name.isEmpty else { return "" }
        return (e.int("invokerid") ?? 0) == 0 && name == server.name ? " by \(server: name)" : " by \(client: name)"
    }

    /// Group changes made by a person (the official pack is silent for the server's automatic ones).
    private func byUser(_ e: [String: String]) -> Bool {
        (e.int("invokerid") ?? 0) != 0
    }

    private func suffix(_ message: String?) -> EventText {
        guard let message, !message.isEmpty else { return "" }
        return " (\(message))"
    }

    private func channelName(_ id: UInt64) -> String {
        channels[id]?.name ?? "?"
    }

    private func clientId(_ value: String?) -> UInt16? {
        value.flatMap { UInt16($0) }
    }

    /// Wraps bare URLs in `[URL]` so other TeamSpeak clients make them clickable.
    static func linkifyURLs(_ text: String) -> String {
        guard !text.localizedCaseInsensitiveContains("[url"),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        var result = text
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "[URL]\(ns.substring(with: match.range))[/URL]")
        }
        return result
    }

    // MARK: - Helpers

    private func updatePing(_ seconds: TimeInterval) {
        guard status == .connected else { return }
        let previous = ping.map { Double($0.components.attoseconds) / 1e18 + Double($0.components.seconds) } ?? seconds
        let smoothed = previous * 0.7 + seconds * 0.3
        let rounded = Duration.milliseconds(Int((smoothed * 1000).rounded()))
        if rounded != ping { ping = rounded }
    }

    private func startTalkTimer() {
        talkTimer?.cancel()
        let lastVoice = self.lastVoice
        talkTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                let now = Date()
                let active = lastVoice.map.withLock { map -> Set<UInt16> in
                    map = map.filter { now.timeIntervalSince($0.value) < 0.35 }
                    return Set(map.keys)
                }
                guard let self else { return }
                if self.talking != active { self.talking = active }
            }
        }
    }

    /// Marks our own client as talking (we don't receive our own voice).
    public func setSelfTalking(_ talking: Bool) {
        if talking {
            lastVoice.map.withLock { $0[ownClientId] = .distantFuture }
        } else {
            lastVoice.map.withLock { _ = $0.removeValue(forKey: ownClientId) }
        }
    }

    private func disconnectImmediately() {
        connection?.disconnect()
        resetState()
    }

    private func resetState() {
        eventTask?.cancel()
        talkTimer?.cancel()
        connection = nil
        for cont in pending.values { cont.resume(throwing: TS3Error.notConnected) }
        pending.removeAll()
        silentCodes.removeAll()
        requestedDetails.removeAll()
        channels.removeAll()
        clients.removeAll()
        serverGroups.removeAll()
        channelGroups.removeAll()
        talking.removeAll()
        lastVoice.map.withLock { $0.removeAll() }
        for index in privateChats.indices { privateChats[index].clientId = nil }
        isReady = false
        ownClientId = 0
        onDisconnected?()
    }
}

/// Last voice packet time per client, written from the network queue.
final class VoiceActivity: Sendable {
    let map = Mutex<[UInt16: Date]>([:])
}
