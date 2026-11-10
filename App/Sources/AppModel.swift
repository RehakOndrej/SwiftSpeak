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
        voice.apply(audioSettings)
        wireUp()
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
            if self.settingsAudioUsers == 0 { self.voice.stop() }
        }
    }

    // MARK: - Connection

    func connect(host: String, port: UInt16, nickname: String, password: String, defaultChannel: String) {
        Storage.lastServer = .init(host: host, port: port, nickname: nickname, defaultChannel: defaultChannel)
        Storage.setServerPassword(password, host: host, port: port)

        var options = ConnectOptions(host: host, port: port, nickname: nickname, identity: identity)
        options.serverPassword = password
        options.defaultChannel = defaultChannel
        options.inputMuted = micMuted
        options.outputMuted = outputMuted
        client.connect(options)
        voice.setMicMuted(micMuted)
        voice.setOutputMuted(outputMuted)

        Task {
            await startAudio()
            // Wait for the server to accept us, then hook up voice sending and away state.
            while client.status == .connecting { try? await Task.sleep(for: .milliseconds(100)) }
            guard client.status == .connected, let sender = client.voiceSender else { return }
            voice.onEncodedFrame = { codec, data in sender(codec, data) }
            if away { try? await client.setAway(true) }
        }
    }

    func disconnect() { client.disconnect() }

    /// For ⌘Q: says goodbye to the server so others see "disconnected", not a timeout.
    /// Returns once the connection is closed, or after `timeout`.
    func disconnectBeforeQuit(timeout: Duration = .seconds(2)) async {
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
        if client.status != .connected && client.status != .connecting { voice.stop() }
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
        sync { try await $0.setAway(away) }
    }

    func toggleAway() { setAway(!away) }

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

    /// Returns true when the event is the push-to-talk key and should not reach the app.
    private func handleInputEvent(_ event: NSEvent) -> Bool {
        let isHotkeyEvent = hotkey.isOwnKeyEvent(event)
        if event.type == .keyDown, !event.isARepeat, !isHotkeyEvent || audioSettings.activation != .pushToTalk {
            voice.noteKeystroke()
        }
        guard audioSettings.activation == .pushToTalk, !isRecordingHotkey else { return false }
        if let pressed = hotkey.pressedState(for: event, currentlyPressed: pushToTalkPressed) {
            setPushToTalkPressed(pressed)
        }
        return isHotkeyEvent
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
