import Foundation
import Network
import os

/// A client version triple the server accepts (Versions.csv). Signs are issued by TeamSpeak.
public struct ClientVersion: Sendable {
    public let version: String
    public let platform: String
    public let sign: String

    public static let macOS = ClientVersion(
        version: "3.?.? [Build: 5680278000]",
        platform: "OS X",
        sign: "SttEnjoWE8jqIM6BOHSfiZP9DGjW0EP/ajU4bdKqgGMV4aYq/kzwVA9gxbmdIzV4lbaokvXBqrRjfBHrTVh8Cg=="
    )
}

public struct ConnectOptions: Sendable {
    public var host: String
    public var port: UInt16
    public var nickname: String
    public var serverPassword: String = ""
    public var defaultChannel: String = ""
    public var defaultChannelPassword: String = ""
    public var identity: Identity
    public var version: ClientVersion = .macOS
    public var inputMuted = false
    public var outputMuted = false

    public init(host: String, port: UInt16 = 9987, nickname: String, identity: Identity) {
        self.host = host
        self.port = port
        self.nickname = nickname
        self.identity = identity
    }
}

public enum ConnectionEvent: Sendable {
    /// The server accepted us (`initserver`); carries our client id.
    case connected(clientId: UInt16)
    case command(Command)
    case voice(clientId: UInt16, codec: UInt8, data: [UInt8], whisper: Bool)
    case closed(TS3Error?)
}

/// Low-level TS3 UDP connection: handshake, encryption, acks, resends, ordering, ping.
///
/// All mutable state lives on `queue`; public methods hop onto it.
public final class Connection: @unchecked Sendable {
    public let events: AsyncStream<ConnectionEvent>
    public var log: (@Sendable (String) -> Void)?
    /// When set, voice packets go here (on the connection queue) instead of `events`.
    /// Arguments: talking client id, codec, Opus data (empty = end of stream), whisper.
    public var voiceHandler: (@Sendable (UInt16, UInt8, [UInt8], Bool) -> Void)?

    private let options: ConnectOptions
    private let queue = DispatchQueue(label: "ts3.connection")
    private let continuation: AsyncStream<ConnectionEvent>.Continuation
    private let logger = Logger(subsystem: "TS3Kit", category: "connection")
    private var udp: NWConnection?

    private enum Phase { case idle, initHandshake, cryptoHandshake, awaitClientEkAck, awaitInitServer, connected, disconnecting, closed }
    private var phase = Phase.idle

    // Low-level handshake
    private var random0 = [UInt8]()
    private var alpha = [UInt8]()
    private var pendingInit: [UInt8]?
    private var pendingInitSent = Date.distantPast
    private var initAttempts = 0

    // Crypto
    private var crypto: SessionCrypto?
    private var clientId: UInt16 = 0
    public private(set) var voiceEncrypted = false

    // Packet ids, indexed by PacketType.rawValue
    private var outIds = [UInt16](repeating: 0, count: 9)
    private var outGenerations = [UInt32](repeating: 0, count: 9)
    private var inIds = [UInt16](repeating: 0, count: 9)
    private var inGenerations = [UInt32](repeating: 0, count: 9)

    // Reliable commands
    private struct OutKey: Hashable { let type: UInt8; let id: UInt16 }
    private struct Outgoing { let datagram: [UInt8]; let firstSent: Date; var lastSent: Date; var rto: TimeInterval }
    private var outbox: [OutKey: Outgoing] = [:]
    private var commandBuffers: [UInt8: [UInt16: Packet]] = [:]
    private struct Fragment { var compressed: Bool; var data: [UInt8] }
    private var fragments: [UInt8: Fragment] = [:]

    private var timer: DispatchSourceTimer?
    private var lastReceived = Date()
    private var lastPing = Date.distantPast
    private var clientInitCommandId: UInt16 = 0

    public init(options: ConnectOptions) {
        self.options = options
        (events, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self)
        outIds[Int(PacketType.command.rawValue)] = 1 // clientinitiv rides inside Init1 step 4
    }

    // MARK: - Public API

    public func start() {
        queue.async { [self] in
            guard phase == .idle else { return }
            let conn = NWConnection(
                host: NWEndpoint.Host(options.host),
                port: NWEndpoint.Port(rawValue: options.port) ?? 9987,
                using: .udp
            )
            udp = conn
            conn.stateUpdateHandler = { [weak self] state in self?.handleState(state) }
            conn.start(queue: queue)
            startTimer()
        }
    }

    /// Sends a command reliably (Command, or CommandLow when `low`).
    public func send(_ command: Command, low: Bool = false) {
        queue.async { [self] in
            guard phase == .connected || phase == .awaitInitServer else { return }
            sendCommand(command.encoded, type: low ? .commandLow : .command)
        }
    }

    /// Sends one voice frame. Empty `data` ends the voice stream.
    public func sendVoice(codec: UInt8, data: [UInt8]) {
        queue.async { [self] in
            guard phase == .connected else { return }
            let t = Int(PacketType.voice.rawValue)
            let vid = outIds[t]
            var packet = Packet(packetId: vid, clientId: clientId, type: .voice, flags: [], payload: .u16(vid) + [codec] + data)
            if !voiceEncrypted { packet.flags.insert(.unencrypted) }
            transmit(&packet)
        }
    }

    public func setVoiceEncryption(_ enabled: Bool) {
        queue.async { [self] in voiceEncrypted = enabled }
    }

    /// Sends `clientdisconnect` and closes once it is acknowledged (or after a short grace period).
    public func disconnect(reason: String = "leaving") {
        queue.async { [self] in
            guard phase == .connected || phase == .awaitInitServer else {
                close(nil)
                return
            }
            phase = .disconnecting
            sendCommand(Command("clientdisconnect", [("reasonid", "8"), ("reasonmsg", reason)]).encoded, type: .command)
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.close(nil) }
        }
    }

    // MARK: - Network

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            debug("UDP ready")
            receiveLoop()
            sendInit0()
        case .failed(let error):
            close(.disconnected("Network failed: \(error.localizedDescription)"))
        case .waiting(let error):
            debug("UDP waiting: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func receiveLoop() {
        udp?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                self.handleDatagram(Array(data))
            }
            if let error {
                self.close(.disconnected("Receive failed: \(error.localizedDescription)"))
                return
            }
            if self.phase != .closed { self.receiveLoop() }
        }
    }

    private func sendDatagram(_ bytes: [UInt8]) {
        udp?.send(content: Data(bytes), completion: .idempotent)
    }

    private func close(_ error: TS3Error?) {
        guard phase != .closed else { return }
        phase = .closed
        timer?.cancel()
        timer = nil
        udp?.cancel()
        udp = nil
        if let error { debug("closed: \(error.localizedDescription)") }
        continuation.yield(.closed(error))
        continuation.finish()
    }

    private func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        log?(message)
    }

    // MARK: - Timers: init/command resend, ping, timeout

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Date()
        if let datagram = pendingInit, now.timeIntervalSince(pendingInitSent) > 1 {
            initAttempts += 1
            if initAttempts > 15 {
                close(.timeout("No answer from server during handshake"))
                return
            }
            sendDatagram(datagram)
            pendingInitSent = now
        }
        for (key, var item) in outbox where now.timeIntervalSince(item.lastSent) > item.rto {
            if now.timeIntervalSince(item.firstSent) > 30 {
                close(.timeout("Server stopped acknowledging packets"))
                return
            }
            sendDatagram(item.datagram)
            item.lastSent = now
            item.rto = min(item.rto * 2, 4)
            outbox[key] = item
        }
        if phase == .connected || phase == .disconnecting {
            if now.timeIntervalSince(lastPing) >= 1 {
                lastPing = now
                var ping = Packet(packetId: 0, clientId: clientId, type: .ping, flags: [.unencrypted], payload: [])
                transmit(&ping)
            }
            if now.timeIntervalSince(lastReceived) > 30 {
                close(.timeout("No packets from server for 30 s"))
            }
        }
    }

    // MARK: - Low-level handshake (ts3protocol.md 2)

    private var versionTimestamp: [UInt8] {
        .u32(UInt32(Date().timeIntervalSince1970) - 1_356_998_400)
    }

    private func sendInit(_ payload: [UInt8]) {
        let packet = Packet(mac: Array("TS3INIT1".utf8), packetId: 101, clientId: 0, type: .init1, flags: [.unencrypted], payload: payload)
        let datagram = packet.encodeToServer()
        pendingInit = datagram
        pendingInitSent = Date()
        initAttempts = 0
        sendDatagram(datagram)
    }

    private func sendInit0() {
        phase = .initHandshake
        random0 = .random(4)
        sendInit(versionTimestamp + [0] + .u32(UInt32(Date().timeIntervalSince1970)) + random0 + [UInt8](repeating: 0, count: 8))
        debug("→ init0")
    }

    private func handleInit(_ payload: [UInt8]) {
        guard phase == .initHandshake, let step = payload.first else { return }
        switch step {
        case 1 where payload.count >= 21:
            debug("← init1")
            sendInit(versionTimestamp + [2] + Array(payload[1..<17]) + Array(payload[17..<21]))
        case 3 where payload.count >= 233:
            debug("← init3")
            let x = Array(payload[1..<65])
            let n = Array(payload[65..<129])
            let level = payload.readU32(129)
            let random2 = Array(payload[133..<233])
            do {
                let start = Date()
                let y = try RSAPuzzle.solve(x: x, n: n, level: level)
                debug("puzzle level \(level) solved in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                alpha = .random(10)
                var ip = ""
                if case .hostPort(let host, _) = udp?.currentPath?.remoteEndpoint {
                    switch host {
                    case .ipv4(let a): ip = "\(a)"
                    case .ipv6(let a): ip = "\(a)"
                    default: break
                    }
                }
                let initiv = "clientinitiv alpha=\(alpha.base64) omega=\(options.identity.publicKeyString) ot=1 ip" + (ip.isEmpty ? "" : "=\(Command.escape(ip))")
                sendInit(versionTimestamp + [4] + x + n + .u32(level) + random2 + y + Array(initiv.utf8))
                debug("→ init4")
            } catch {
                close(error as? TS3Error ?? .protocolViolation("\(error)"))
            }
        case 127:
            debug("← init127, restarting handshake")
            sendInit0()
        default:
            debug("unexpected init step \(step)")
        }
    }

    // MARK: - High-level handshake (ts3protocol.md 3)

    private func handleInitIvExpand2(_ args: [String: String]) {
        guard phase == .cryptoHandshake || phase == .initHandshake else { return }
        pendingInit = nil
        do {
            guard args["ot"] == "1" else { throw TS3Error.protocolViolation("Server too old (no ot=1)") }
            guard let l = args["l"].flatMap({ [UInt8](base64: $0) }),
                  let beta = args["beta"].flatMap({ [UInt8](base64: $0) }), beta.count == 54,
                  let omega = args["omega"].flatMap({ [UInt8](base64: $0) }),
                  let proof = args["proof"].flatMap({ [UInt8](base64: $0) }) else {
                throw TS3Error.protocolViolation("initivexpand2 is missing arguments")
            }
            let serverKey = try ServerKey(tomcrypt: omega)
            guard serverKey.verify(signatureDER: proof, data: l) else {
                throw TS3Error.protocolViolation("Server license signature is invalid")
            }
            var root = Ed25519.rootKey
            if let r = args["root"].flatMap({ [UInt8](base64: $0) }), r.count == 32 { root = r }
            let serverEphemeral = try LicenseChain(l).deriveServerKey(root: root)

            let ephemeralPrivate = Ed25519.randomScalar()
            let ephemeralPublic = Ed25519.basePointMultiply(ephemeralPrivate)
            crypto = try SessionCrypto(alpha: alpha, beta: beta, ephemeralPrivate: ephemeralPrivate, serverEphemeral: serverEphemeral)

            let ekProof = try options.identity.sign(ephemeralPublic + beta)
            phase = .awaitClientEkAck
            sendCommand("clientek ek=\(Command.escape(ephemeralPublic.base64)) proof=\(Command.escape(ekProof.base64))", type: .command)
            debug("→ clientek")
        } catch {
            close(error as? TS3Error ?? .protocolViolation("\(error)"))
        }
    }

    private func sendClientInit() {
        let o = options
        let hwid = Hash.sha256(Array(o.identity.uid.utf8)).hex
        let defaultChannel = o.defaultChannel
        let cmd = Command("clientinit", [
            ("client_nickname", o.nickname),
            ("client_version", o.version.version),
            ("client_platform", o.version.platform),
            ("client_input_hardware", "1"),
            ("client_output_hardware", "1"),
            ("client_input_muted", o.inputMuted ? "1" : "0"),
            ("client_output_muted", o.outputMuted ? "1" : "0"),
            ("client_default_channel", defaultChannel),
            ("client_default_channel_password", ts3HashPassword(o.defaultChannelPassword)),
            ("client_server_password", ts3HashPassword(o.serverPassword)),
            ("client_meta_data", nil),
            ("client_version_sign", o.version.sign),
            ("client_key_offset", String(o.identity.keyOffset)),
            ("client_nickname_phonetic", nil),
            ("client_default_token", nil),
            ("hwid", "\(hwid.prefix(32)),\(hwid.suffix(32))"),
        ])
        phase = .awaitInitServer
        clientInitCommandId = outIds[Int(PacketType.command.rawValue)]
        sendCommand(cmd.encoded, type: .command)
        debug("→ clientinit")
    }

    // MARK: - Sending

    private func sendCommand(_ text: String, type: PacketType) {
        let data = Array(text.utf8)
        let maxPayload = Packet.maxSize - Packet.c2sHeaderLength
        var chunks: [[UInt8]] = []
        var offset = 0
        repeat {
            let end = min(offset + maxPayload, data.count)
            chunks.append(Array(data[offset..<end]))
            offset = end
        } while offset < data.count
        for (i, chunk) in chunks.enumerated() {
            var flags: PacketFlags = [.newProtocol]
            if chunks.count > 1 && (i == 0 || i == chunks.count - 1) { flags.insert(.fragmented) }
            var packet = Packet(packetId: 0, clientId: clientId, type: type, flags: flags, payload: chunk)
            let fake = crypto == nil || (phase == .awaitClientEkAck && text.hasPrefix("clientek"))
            transmit(&packet, fakeEncrypt: fake)
        }
    }

    private func sendAck(for type: PacketType, id: UInt16) {
        let ackType: PacketType = type == .command ? .ack : (type == .commandLow ? .ackLow : .pong)
        var packet = Packet(packetId: 0, clientId: clientId, type: ackType, flags: ackType == .pong ? [.unencrypted] : [], payload: .u16(id))
        let t = Int(ackType.rawValue)
        let fake = crypto == nil || (ackType == .ack && outIds[t] == 0 && outGenerations[t] == 0)
        transmit(&packet, fakeEncrypt: fake)
    }

    /// Assigns the packet id, encrypts and sends. Commands are queued for resend.
    private func transmit(_ packet: inout Packet, fakeEncrypt: Bool = false) {
        let t = Int(packet.type.rawValue)
        let id = outIds[t]
        let generation = outGenerations[t]
        packet.packetId = id
        packet.clientId = clientId
        outIds[t] = id &+ 1
        if outIds[t] == 0 { outGenerations[t] &+= 1 }

        if packet.flags.contains(.unencrypted) {
            packet.mac = crypto?.sharedMac ?? [UInt8](repeating: 0, count: 8)
        } else {
            let (key, nonce): ([UInt8], [UInt8])
            if fakeEncrypt || crypto == nil {
                (key, nonce) = (SessionCrypto.fakeKey, SessionCrypto.fakeNonce)
            } else {
                (key, nonce) = crypto!.keyNonce(type: packet.type, toServer: true, packetId: id, generation: generation)
            }
            let result = EAX.encrypt(key: key, nonce: nonce, header: packet.meta(toServer: true), plaintext: packet.payload)
            packet.payload = result.ciphertext
            packet.mac = result.tag
        }
        let datagram = packet.encodeToServer()
        if packet.type == .command || packet.type == .commandLow {
            let now = Date()
            outbox[OutKey(type: packet.type.rawValue, id: id)] = Outgoing(datagram: datagram, firstSent: now, lastSent: now, rto: 0.5)
        }
        sendDatagram(datagram)
    }

    // MARK: - Receiving

    private func handleDatagram(_ data: [UInt8]) {
        guard var packet = Packet.decodeFromServer(data) else { return }
        if packet.type == .init1 {
            handleInit(packet.payload)
            return
        }

        let t = Int(packet.type.rawValue)
        let id = packet.packetId
        let next = inIds[t]
        let inWindow = id &- next < 0x8000
        let generation: UInt32 = inWindow
            ? (id >= next ? inGenerations[t] : inGenerations[t] &+ 1)
            : (id < next ? inGenerations[t] : inGenerations[t] &- 1)

        if !packet.flags.contains(.unencrypted) {
            let header = packet.meta(toServer: false)
            func attempt(_ key: [UInt8], _ nonce: [UInt8]) -> [UInt8]? {
                EAX.decrypt(key: key, nonce: nonce, header: header, ciphertext: packet.payload, tag: packet.mac)
            }
            var plain: [UInt8]?
            if crypto == nil || (packet.type == .ack && id <= 1) || (packet.type == .command && id == 0 && generation == 0) {
                plain = attempt(SessionCrypto.fakeKey, SessionCrypto.fakeNonce)
            }
            if plain == nil, crypto != nil {
                let (key, nonce) = crypto!.keyNonce(type: packet.type, toServer: false, packetId: id, generation: generation)
                plain = attempt(key, nonce)
            }
            guard let plain else {
                debug("dropping \(packet.type) \(id): MAC mismatch")
                return
            }
            packet.payload = plain
        } else if packet.type == .command || packet.type == .commandLow {
            return // commands must be encrypted
        }

        switch packet.type {
        case .command, .commandLow:
            sendAck(for: packet.type, id: id)
            guard inWindow else { return } // duplicate of something already processed
            commandBuffers[packet.type.rawValue, default: [:]][id] = packet
            drainCommands(packet.type)
        case .ack, .ackLow:
            guard packet.payload.count >= 2 else { return }
            let acked = packet.payload.readU16(0)
            let forType: PacketType = packet.type == .ack ? .command : .commandLow
            if outbox.removeValue(forKey: OutKey(type: forType.rawValue, id: acked)) != nil {
                if phase == .awaitClientEkAck && forType == .command && acked == 1 {
                    sendClientInit()
                } else if phase == .disconnecting && outbox.isEmpty {
                    close(nil)
                }
            }
        case .ping:
            advanceIncoming(t, id: id, generation: generation, inWindow: inWindow)
            sendAck(for: .ping, id: id)
        case .pong:
            advanceIncoming(t, id: id, generation: generation, inWindow: inWindow)
        case .voice, .voiceWhisper:
            advanceIncoming(t, id: id, generation: generation, inWindow: inWindow)
            let p = packet.payload
            guard p.count >= 5 else { return }
            let whisper = packet.type == .voiceWhisper
            if let voiceHandler {
                voiceHandler(p.readU16(2), p[4], Array(p[5...]), whisper)
            } else {
                continuation.yield(.voice(clientId: p.readU16(2), codec: p[4], data: Array(p[5...]), whisper: whisper))
            }
        case .init1:
            break
        }
    }

    private func advanceIncoming(_ t: Int, id: UInt16, generation: UInt32, inWindow: Bool) {
        guard inWindow else { return }
        inIds[t] = id &+ 1
        inGenerations[t] = inIds[t] == 0 ? generation &+ 1 : generation
    }

    private func drainCommands(_ type: PacketType) {
        let t = Int(type.rawValue)
        while let packet = commandBuffers[type.rawValue]?.removeValue(forKey: inIds[t]) {
            inIds[t] &+= 1
            if inIds[t] == 0 { inGenerations[t] &+= 1 }

            let fragmented = packet.flags.contains(.fragmented)
            if var fragment = fragments[type.rawValue] {
                fragment.data += packet.payload
                if fragmented {
                    fragments[type.rawValue] = nil
                    completeCommand(fragment.data, compressed: fragment.compressed)
                } else {
                    fragments[type.rawValue] = fragment
                }
            } else if fragmented {
                fragments[type.rawValue] = Fragment(compressed: packet.flags.contains(.compressed), data: packet.payload)
            } else {
                completeCommand(packet.payload, compressed: packet.flags.contains(.compressed))
            }
        }
    }

    private func completeCommand(_ data: [UInt8], compressed: Bool) {
        var bytes = data
        if compressed {
            do {
                bytes = try QuickLZ.decompress(data)
            } catch {
                debug("QuickLZ failed: \(error)")
                return
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let command = Command.parse(text)
        switch command.name {
        case "initivexpand2":
            debug("← initivexpand2")
            phase = .cryptoHandshake
            handleInitIvExpand2(command.first)
            return
        case "initivexpand":
            close(.protocolViolation("Server uses the pre-3.1 handshake, which is not supported"))
            return
        case "initserver":
            outbox.removeValue(forKey: OutKey(type: PacketType.command.rawValue, id: clientInitCommandId))
            clientId = UInt16(command.first.int("aclid") ?? 0)
            phase = .connected
            debug("← initserver, client id \(clientId)")
            continuation.yield(.connected(clientId: clientId))
        case "notifyconnectioninforequest":
            sendCommand(setConnectionInfo().encoded, type: .command)
            return
        case "error" where phase == .awaitInitServer:
            let a = command.first
            if a.int("id") != 0 {
                close(.server(id: a.int("id") ?? -1, message: a["msg"] ?? "", extra: a["extra_msg"]))
                return
            }
        default:
            break
        }
        continuation.yield(.command(command))
    }

    private func setConnectionInfo() -> Command {
        Command("setconnectioninfo", [
            ("connection_ping", "0"), ("connection_ping_deviation", "0"),
            ("connection_packets_sent_speech", "0"), ("connection_packets_sent_keepalive", "0"),
            ("connection_packets_sent_control", "0"), ("connection_bytes_sent_speech", "0"),
            ("connection_bytes_sent_keepalive", "0"), ("connection_bytes_sent_control", "0"),
            ("connection_packets_received_speech", "0"), ("connection_packets_received_keepalive", "0"),
            ("connection_packets_received_control", "0"), ("connection_bytes_received_speech", "0"),
            ("connection_bytes_received_keepalive", "0"), ("connection_bytes_received_control", "0"),
            ("connection_server2client_packetloss_speech", "0"), ("connection_server2client_packetloss_keepalive", "0"),
            ("connection_server2client_packetloss_control", "0"), ("connection_server2client_packetloss_total", "0"),
            ("connection_bandwidth_sent_last_second_speech", "0"), ("connection_bandwidth_sent_last_second_keepalive", "0"),
            ("connection_bandwidth_sent_last_second_control", "0"), ("connection_bandwidth_sent_last_minute_speech", "0"),
            ("connection_bandwidth_sent_last_minute_keepalive", "0"), ("connection_bandwidth_sent_last_minute_control", "0"),
            ("connection_bandwidth_received_last_second_speech", "0"), ("connection_bandwidth_received_last_second_keepalive", "0"),
            ("connection_bandwidth_received_last_second_control", "0"), ("connection_bandwidth_received_last_minute_speech", "0"),
            ("connection_bandwidth_received_last_minute_keepalive", "0"), ("connection_bandwidth_received_last_minute_control", "0"),
        ])
    }
}
