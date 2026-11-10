import AppKit
import ApplicationServices
import AVFoundation
import Observation
import TS3Audio
import TS3Kit

/// Glue between the protocol client, the voice engine and persisted settings.
@MainActor
@Observable
final class AppModel {
    let client = TS3Client()
    @ObservationIgnored let voice = VoiceEngine()

    var audioSettings: AudioSettings {
        didSet {
            Storage.audioSettings = audioSettings
            voice.apply(audioSettings)
            if let warning = voice.startWarning { audioError = warning }
            if audioSettings.activation != .pushToTalk { setPushToTalkPressed(false) }
        }
    }
    var hotkey: Hotkey {
        didSet { Storage.pushToTalkHotkey = hotkey }
    }
    var shortcuts: Shortcuts {
        didSet { Storage.shortcuts = shortcuts }
    }
    var bookmarks: [Bookmark] {
        didSet { Storage.bookmarks = bookmarks }
    }
    /// Local volume / mute per client unique id.
    var userAudio: [String: UserAudioPreference] {
        didSet {
            Storage.userAudio = userAudio
            pushSpeakerGains()
        }
    }
    var awayMessage: String {
        didSet { Storage.awayMessage = awayMessage }
    }
    var sheet: AppSheet?
    /// Set while waiting to reconnect after the connection was lost.
    var reconnect: PendingReconnect?
    var identity: Identity
    var inputLevel: Float = -100
    /// What is being played, in dBFS, refreshed about 10 times a second.
    var outputLevel: Float = -100
    /// Whether the activation gate (voice detection / push to talk) is open right now.
    var inputGateOpen = false
    /// True while our voice is actually being sent.
    var isTransmitting = false
    /// "Begin Test" in the capture settings: hear your processed microphone.
    var isTestingCapture = false {
        didSet { voice.setLoopback(isTestingCapture) }
    }
    /// Global push-to-talk and typing detection need Accessibility access.
    var accessibilityTrusted = AXIsProcessTrusted()
    /// While the hotkey recorder is listening, key presses must not trigger push to talk.
    @ObservationIgnored var isRecordingHotkey = false
    var audioError: String?
    var showConnectSheet = false

    /// Wanted state, applied on connect and kept in sync while connected.
    var micMuted = false
    var outputMuted = false
    var away = false

    /// What the server tree has selected; the info panel shows it (nil = your own channel).
    var treeSelection: TreeSelection?
    var collapsedChannels: Set<UInt64> = []

    @ObservationIgnored private var settingsAudioUsers = 0
    @ObservationIgnored private var keyMonitors: [Any] = []
    @ObservationIgnored private var pushToTalkPressed = false
    @ObservationIgnored private var shortcutsHeld: Set<Shortcuts.Action> = []
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private(set) lazy var soundPack = SoundPack(voice: voice)
    /// Spoken notifications ("Connected", "User joined your channel", …).
    var soundsEnabled = Storage.soundsEnabled {
        didSet {
            Storage.soundsEnabled = soundsEnabled
            soundPack.isEnabled = soundsEnabled
        }
    }

    // Reconnect bookkeeping
    @ObservationIgnored private var lastOptions: ConnectOptions?
    @ObservationIgnored private var lastChannelId: UInt64?
    /// Passwords typed for channels this session, so a reconnect can rejoin them.
    @ObservationIgnored private var channelPasswords: [UInt64: String] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var userDisconnected = false
    @ObservationIgnored private var startingConnection = false

    init() {
        if let saved = Storage.loadIdentity() {
            identity = saved
        } else {
            let fresh = Identity.generate(level: 8)
            Storage.saveIdentity(fresh)
            identity = fresh
        }
        audioSettings = Storage.audioSettings
        hotkey = Storage.pushToTalkHotkey
        shortcuts = Storage.shortcuts
        bookmarks = Storage.bookmarks
        userAudio = Storage.userAudio
        awayMessage = Storage.awayMessage
        voice.apply(audioSettings)
        wireUp()
        observeClients()
        installPushToTalkMonitors()
    }

    // MARK: - Wiring

    private func wireUp() {
        let voice = self.voice
        client.voiceSink = { clientId, codec, data in
            voice.receive(clientId: clientId, codec: codec, data: data)
        }
        voice.onInputLevel = { [weak self] level, open in
            Task { @MainActor in
                self?.inputLevel = level
                self?.inputGateOpen = open
            }
        }
        voice.onTransmittingChanged = { [weak self] transmitting in
            Task { @MainActor in
                self?.isTransmitting = transmitting
                self?.client.setSelfTalking(transmitting)
            }
        }
        // Meters for the audio panel; levels drop to silence while audio is off.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                let running = self.voice.isRunning
                let output = running ? self.voice.takeOutputLevel() : -100
                if abs(output - self.outputLevel) > 0.5 { self.outputLevel = output }
                if !running {
                    if self.inputLevel != -100 { self.inputLevel = -100 }
                    if self.inputGateOpen { self.inputGateOpen = false }
                }
            }
        }
        client.onOwnChannelChanged = { [weak self] channel in
            guard let self else { return }
            self.lastChannelId = channel.id
            let codec: VoiceCodec = channel.codec == VoiceCodec.opusMusic.rawValue ? .opusMusic : .opusVoice
            self.voice.setCodec(codec, quality: channel.codecQuality)
            let supported = channel.codec == 4 || channel.codec == 5
            self.voice.setTransmitEnabled(supported)
            if !supported {
                self.audioError = "This channel uses a legacy codec (Speex/CELT). You can listen to Opus users only and cannot talk here."
            } else if self.audioError?.hasPrefix("This channel") == true {
                self.audioError = nil
            }
        }
        client.onDisconnected = { [weak self] in
            guard let self else { return }
            self.treeSelection = nil
            self.voice.setTransmitEnabled(false)
            if self.shouldReconnect {
                self.scheduleReconnect()
            } else {
                self.stopAudioWhenIdle()
            }
        }
        soundPack.isEnabled = soundsEnabled
        client.onEvent = { [weak self] event in
            self?.soundPack.play(event)
        }
        client.onIncomingMessage = { [weak self] message, target in
            self?.notifier.notify(message, target: target)
        }
        notifier.onOpen = { [weak self] target in
            guard let self else { return }
            if case .client(let uid) = target, !self.client.privateChats.contains(where: { $0.uid == uid }) { return }
            self.client.activeChat = target
        }
    }

    // MARK: - Connection

    func connect(host: String, port: UInt16, nickname: String, password: String, defaultChannel: String) {
        Storage.lastServer = .init(host: host, port: port, nickname: nickname, defaultChannel: defaultChannel)
        Storage.setServerPassword(password, host: host, port: port)

        var options = ConnectOptions(host: host, port: port, nickname: nickname, identity: identity)
        options.serverPassword = password
        options.defaultChannel = defaultChannel
        cancelReconnect()
        reconnectAttempt = 0
        lastChannelId = nil
        channelPasswords.removeAll()
        start(options)
    }

    func connect(_ bookmark: Bookmark) {
        connect(host: bookmark.host, port: bookmark.port, nickname: bookmark.nickname,
                password: Storage.serverPassword(host: bookmark.host, port: bookmark.port),
                defaultChannel: bookmark.defaultChannel)
    }

    private func start(_ options: ConnectOptions) {
        var options = options
        options.inputMuted = micMuted
        options.outputMuted = outputMuted
        lastOptions = options
        userDisconnected = false
        startingConnection = true
        client.connect(options)
        startingConnection = false
        voice.setMicMuted(micMuted)
        voice.setOutputMuted(outputMuted)

        Task {
            await startAudio()
            // Wait for the server to accept us, then hook up voice sending and away state.
            while client.status == .connecting { try? await Task.sleep(for: .milliseconds(100)) }
            guard client.status == .connected, let sender = client.voiceSender else { return }
            reconnectAttempt = 0
            voice.onEncodedFrame = { codec, data in sender(codec, data) }
            if away { try? await client.setAway(true, message: awayMessage) }
        }
    }

    func disconnect() {
        userDisconnected = true
        cancelReconnect()
        client.disconnect()
        stopAudioWhenIdle()
    }

    // MARK: - Reconnect

    struct PendingReconnect: Equatable {
        let at: Date
        let attempt: Int
    }

    /// Only after a connection that worked was lost: not on failed first attempts, not after
    /// leaving on purpose, not after a kick or ban. A server shutdown does count.
    private var shouldReconnect: Bool {
        // A retry that fails (server still down) keeps the series going, up to ~12 minutes.
        let inSeries = reconnectAttempt > 0 && reconnectAttempt < Self.maxReconnectAttempts
        guard !startingConnection, !userDisconnected, client.wasConnected || inSeries, lastOptions != nil else { return false }
        if let reason = client.removalReason { return reason == 7 || reason == 11 }
        if case .failed = client.status { return true }
        return false
    }

    private static let maxReconnectAttempts = 15

    private func scheduleReconnect() {
        guard var options = lastOptions else { return }
        if let channel = lastChannelId {
            options.defaultChannel = "/\(channel)"
            options.defaultChannelPassword = channelPasswords[channel] ?? ""
        }
        reconnectAttempt += 1
        let delay = min(60, 2 << min(reconnectAttempt - 1, 5)) // 2, 4, 8, 16, 32, 60 s
        let pending = PendingReconnect(at: Date().addingTimeInterval(TimeInterval(delay)), attempt: reconnectAttempt)
        reconnect = pending
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.reconnect == pending else { return }
            self.reconnect = nil
            self.start(options)
        }
    }

    func reconnectNow() {
        guard reconnect != nil, var options = lastOptions else { return }
        cancelReconnect()
        if let channel = lastChannelId {
            options.defaultChannel = "/\(channel)"
            options.defaultChannelPassword = channelPasswords[channel] ?? ""
        }
        start(options)
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if reconnect != nil {
            reconnect = nil
            stopAudioWhenIdle()
        }
    }

    // MARK: - Bookmarks

    /// Saves (or updates the bookmark for the same host and port).
    func saveBookmark(_ bookmark: Bookmark, password: String) {
        Storage.setServerPassword(password, host: bookmark.host, port: bookmark.port)
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id || ($0.host == bookmark.host && $0.port == bookmark.port) }) {
            var updated = bookmark
            updated.id = bookmarks[index].id
            bookmarks[index] = updated
        } else {
            bookmarks.append(bookmark)
        }
    }

    func deleteBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
    }

    /// For ⌘Q: says goodbye to the server so others see "disconnected", not a timeout.
    /// Returns once the connection is closed, or after `timeout`.
    func disconnectBeforeQuit(timeout: Duration = .seconds(2)) async {
        userDisconnected = true
        cancelReconnect()
        guard client.status == .connected || client.status == .connecting else { return }
        client.disconnect(reason: "Quit")
        let deadline = ContinuousClock.now + timeout
        while (client.status == .connected || client.status == .connecting) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func startAudio() async {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            audioError = "Microphone access is denied. Allow it in System Settings → Privacy & Security → Microphone."
            do { try voice.start() } catch { audioError = error.localizedDescription }
            return
        }
        guard !voice.isRunning else { return }
        do {
            try voice.start()
            audioError = voice.startWarning
        } catch {
            audioError = "Audio failed to start: \(error.localizedDescription)"
        }
    }

    /// The settings window shows a live input meter and test sounds, so it needs audio running.
    func settingsAppeared() {
        settingsAudioUsers += 1
        refreshAccessibility()
        Task { await startAudio() }
    }

    func settingsDisappeared() {
        settingsAudioUsers = max(0, settingsAudioUsers - 1)
        guard settingsAudioUsers == 0 else { return }
        isTestingCapture = false
        stopAudioWhenIdle()
    }

    /// Stops audio once nothing needs it, letting a sound that's still playing ("Disconnected") finish first.
    private func stopAudioWhenIdle() {
        Task { [weak self] in
            for _ in 0..<40 { // at most 4 s
                guard let self, self.voice.isPlayingEffects else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, self.client.status != .connected, self.client.status != .connecting,
                  self.settingsAudioUsers == 0, self.reconnect == nil else { return }
            self.voice.stop()
        }
    }

    func refreshAccessibility() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    func requestAccessibility() {
        accessibilityTrusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: - Self state

    func toggleMic() {
        // Unmuting by hand while away keeps it unmuted on return.
        micMutedBeforeAway = nil
        setMicMuted(!micMuted)
        soundPack.play(micMuted ? .micMuted : .micActivated)
    }

    private func setMicMuted(_ muted: Bool) {
        guard micMuted != muted else { return }
        micMuted = muted
        voice.setMicMuted(muted)
        sync { try await $0.setMicMuted(muted) }
    }

    func toggleOutput() {
        outputMuted.toggle()
        voice.setOutputMuted(outputMuted)
        soundPack.play(outputMuted ? .soundMuted : .soundResumed)
        sync { try await $0.setOutputMuted(self.outputMuted) }
    }

    /// Mic state from before going away, restored on the way back.
    @ObservationIgnored private var micMutedBeforeAway: Bool?

    /// Away mutes the microphone; coming back restores whatever it was before.
    func setAway(_ away: Bool) {
        guard away != self.away else { return }
        self.away = away
        if away {
            micMutedBeforeAway = micMuted
            setMicMuted(true)
        } else if let before = micMutedBeforeAway {
            micMutedBeforeAway = nil
            setMicMuted(before)
        }
        soundPack.play(away ? .awayActivated : .awayDeactivated)
        let message = awayMessage
        sync { try await $0.setAway(away, message: message) }
    }

    func toggleAway() { setAway(!away) }

    /// From the profile sheet: new nickname (applied now if connected) and away message.
    func updateProfile(nickname: String, awayMessage: String) {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var last = Storage.lastServer
            last.nickname = trimmed
            Storage.lastServer = last
            lastOptions?.nickname = trimmed
            sync { try await $0.setNickname(trimmed) }
        }
        let messageChanged = awayMessage != self.awayMessage
        self.awayMessage = awayMessage
        if away && messageChanged {
            sync { try await $0.setAway(true, message: awayMessage) }
        }
    }

    // MARK: - Per-user volume

    func audioPreference(for uid: String) -> UserAudioPreference {
        userAudio[uid] ?? UserAudioPreference()
    }

    func setLocalVolume(_ db: Float, for uid: String) {
        var pref = audioPreference(for: uid)
        pref.volumeDB = db
        userAudio[uid] = pref.isDefault ? nil : pref
    }

    func toggleLocalMute(for uid: String) {
        var pref = audioPreference(for: uid)
        pref.mutedLocally.toggle()
        userAudio[uid] = pref.isDefault ? nil : pref
    }

    /// Re-applies local volumes whenever the client list changes (ids are per connection, preferences per uid).
    private func observeClients() {
        withObservationTracking {
            _ = client.clients
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.pushSpeakerGains()
                self?.observeClients()
            }
        }
        pushSpeakerGains()
    }

    private func pushSpeakerGains() {
        var gains: [UInt16: Float] = [:]
        for (id, c) in client.clients {
            if let pref = userAudio[c.uid], !pref.isDefault { gains[id] = pref.gain }
        }
        voice.setSpeakerGains(gains)
    }

    // MARK: - Moderation

    func move(clientId: UInt16, to channel: ChannelInfo) {
        if clientId == client.ownClientId {
            join(channel)
        } else {
            sync { try await $0.move(client: clientId, to: channel.id) }
        }
    }

    func perform(_ action: ModerationAction, on clientId: UInt16, text: String, banDuration: Duration?) {
        switch action {
        case .poke: sync { try await $0.poke(client: clientId, message: text) }
        case .kickFromChannel: sync { try await $0.kickFromChannel(client: clientId, reason: text) }
        case .kickFromServer: sync { try await $0.kickFromServer(client: clientId, reason: text) }
        case .ban: sync { try await $0.ban(client: clientId, duration: banDuration, reason: text) }
        }
    }

    // MARK: - Chat

    func openPrivateChat(with client: ClientInfo) {
        guard client.id != self.client.ownClientId else { return }
        self.client.activeChat = self.client.openPrivateChat(with: client)
    }

    func sendChat(_ text: String) {
        let target = client.activeChat
        sync { try await $0.send(text: text, to: target) }
    }

    func join(_ channel: ChannelInfo, password: String = "") {
        if !password.isEmpty { channelPasswords[channel.id] = password }
        sync { try await $0.join(channel: channel.id, password: password) }
    }

    private func sync(_ action: @escaping (TS3Client) async throws -> Void) {
        guard client.status == .connected else { return }
        Task { try? await action(client) } // errors are already shown in the log
    }

    func regenerateIdentity() {
        let fresh = Identity.generate(level: 8)
        Storage.saveIdentity(fresh)
        identity = fresh
    }

    // MARK: - Push to talk and typing detection

    private func installPushToTalkMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleInputEvent(event) ?? false }
            return consumed ? nil : event
        }) {
            keyMonitors.append(local)
        }
        // Other apps' key events only arrive with Accessibility access; mouse buttons work without it.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleInputEvent(event) }
        }) {
            keyMonitors.append(global)
        }
    }

    /// Returns true when the event is a hotkey of ours and should not reach the app.
    private func handleInputEvent(_ event: NSEvent) -> Bool {
        guard !isRecordingHotkey else { return false }
        if handleShortcut(event) { return true }
        let isHotkeyEvent = hotkey.isOwnKeyEvent(event)
        if event.type == .keyDown, !event.isARepeat, !isHotkeyEvent || audioSettings.activation != .pushToTalk {
            voice.noteKeystroke()
        }
        guard audioSettings.activation == .pushToTalk else { return false }
        if let pressed = hotkey.pressedState(for: event, currentlyPressed: pushToTalkPressed) {
            setPushToTalkPressed(pressed)
        }
        return isHotkeyEvent
    }

    /// Global toggle shortcuts fire once per press. Returns true if the event belongs to one.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        var consumed = false
        for action in Shortcuts.Action.allCases {
            guard let key = shortcuts[keyPath: action.keyPath] else { continue }
            let held = shortcutsHeld.contains(action)
            guard let pressed = key.pressedState(for: event, currentlyPressed: held) else { continue }
            if pressed && !held {
                shortcutsHeld.insert(action)
                switch action {
                case .toggleMicrophone: toggleMic()
                case .toggleSpeakers: toggleOutput()
                case .toggleAway: toggleAway()
                }
            } else if !pressed {
                shortcutsHeld.remove(action)
            }
            if key.isOwnKeyEvent(event) { consumed = true }
        }
        return consumed
    }

    private func setPushToTalkPressed(_ pressed: Bool) {
        guard pressed != pushToTalkPressed else { return }
        pushToTalkPressed = pressed
        voice.setPushToTalk(pressed: pressed)
    }
}

/// A row in the server tree.
enum TreeSelection: Hashable {
    case server
    case channel(UInt64)
    case client(UInt16)
}
