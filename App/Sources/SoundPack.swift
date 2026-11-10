@preconcurrency import AVFoundation
import AppKit
import TS3Audio
import TS3Kit

/// Spoken notifications: one sound file per event, played at the sound pack volume on the playback device.
///
/// Files are looked up by name (`connected.mp3`, `user_switched_tocurrentchannel.wav`, …) first in
/// `~/Library/Application Support/TS3 Client/Sounds`, then in the app bundle (the default pack).
/// Events without a file are silent.
@MainActor
final class SoundPack {
    /// Events the app itself causes (the rest are `ClientEvent`s from the server).
    enum LocalEvent: String, CaseIterable {
        case micMuted = "mic_muted", micActivated = "mic_activated"
        case soundMuted = "sound_muted", soundResumed = "sound_resumed"
        case awayActivated = "away_activated", awayDeactivated = "away_deactivated"
    }

    static let folder = URL.applicationSupportDirectory.appending(path: "TS3 Client/Sounds", directoryHint: .isDirectory)
    static let fileExtensions = ["mp3", "wav", "m4a", "aiff", "aif", "caf"]
    static let allNames: [String] = ClientEvent.allCases.map(\.soundName) + LocalEvent.allCases.map(\.rawValue)

    var isEnabled = true
    /// Called after the pack had to start the speakers itself (audio was off), so they can be stopped later.
    var onStartedPlayback: (() -> Void)?
    private let voice: VoiceEngine
    /// Decoded sounds by name; an empty array means "no file".
    private var cache: [String: [Float]] = [:]

    init(voice: VoiceEngine) {
        self.voice = voice
    }

    func play(_ event: ClientEvent) { play(name: event.soundName) }
    func play(_ event: LocalEvent) { play(name: event.rawValue) }

    func play(name: String) {
        guard isEnabled else { return }
        let samples = sound(named: name)
        guard !samples.isEmpty else { return }
        if voice.isRunning {
            voice.playEffect(samples)
            return
        }
        // Disconnected or not started yet: bring up the speakers only (never the microphone).
        // The engine starts on its own queue, so this doesn't block the UI.
        let voice = self.voice
        Task {
            guard (try? await voice.startPlayback()) != nil else { return }
            voice.playEffect(samples)
            onStartedPlayback?()
        }
    }

    /// Forget decoded sounds, e.g. after files in the folder changed.
    func reload() { cache.removeAll() }

    /// How many of the known event names have a file.
    var availableCount: Int {
        Self.allNames.filter { Self.url(for: $0) != nil }.count
    }

    /// Creates the folder (with a list of file names) and shows it in Finder.
    func revealFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let list = Self.folder.appending(path: "File names.txt")
        if !fm.fileExists(atPath: list.path(percentEncoded: false)) {
            let text = """
            Put one sound per event here, named exactly as below, with any of these extensions:
            \(Self.fileExtensions.joined(separator: ", ")). Missing files are simply silent.
            Files here take priority over the sounds that come with the app.

            \(Self.allNames.joined(separator: "\n"))

            """
            try? text.write(to: list, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([list])
    }

    // MARK: - Loading

    private func sound(named name: String) -> [Float] {
        if let cached = cache[name] { return cached }
        let samples = Self.url(for: name).flatMap(Self.decode) ?? []
        cache[name] = samples
        return samples
    }

    private static func url(for name: String) -> URL? {
        let fm = FileManager.default
        for ext in fileExtensions {
            let url = folder.appending(path: "\(name).\(ext)")
            if fm.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        // The bundled default pack (App/Resources/Sounds) sits directly in the app's resources.
        for ext in fileExtensions {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        }
        return nil
    }

    /// Any audio file → 48 kHz mono float, the voice engine's format.
    private static func decode(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        guard file.length > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 48_000 / inFormat.sampleRate) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let data = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}

extension ClientEvent {
    /// File name (without extension), following the official sound pack's naming.
    var soundName: String {
        switch self {
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .connectionLost: "connection_lost"
        case .channelSwitched: "channel_switched"
        case .youWereMoved: "you_were_moved"
        case .youWereKickedFromChannel: "you_kicked_channel"
        case .youWereKickedFromServer: "you_kicked_server"
        case .youWereBanned: "you_were_banned"
        case .youWerePoked: "you_were_poked"
        case .talkPowerGranted: "talkpower_granted"
        case .talkPowerRevoked: "talkpower_revoked"
        case .serverGroupAssigned: "servergroup_assigned"
        case .serverGroupRevoked: "servergroup_revoked"
        case .channelGroupChanged: "channelgroup_changed"
        case .insufficientPermissions: "insufficient_permissions"
        case .error: "error"
        case .userConnected: "user_connected_currentchannel"
        case .userDisconnected: "user_disconnected_currentchannel"
        case .userLostConnection: "user_connectionlost_currentchannel"
        case .userJoinedChannel: "user_switched_tocurrentchannel"
        case .userLeftChannel: "user_switched_awayfromcurrentchannel"
        case .userMovedIn: "user_moved_tocurrentchannel"
        case .userMovedOut: "user_moved_awayfromcurrentchannel"
        case .userKickedFromChannel: "user_kicked_channel_awayfromcurrentchannel"
        case .userKickedFromServer: "user_kicked_server_currentchannel"
        case .userBanned: "user_banned_server_currentchannel"
        case .userStartedRecording: "user_recording_started"
        case .userStoppedRecording: "user_recording_stopped"
        case .messageReceived: "chat_message_inbound"
        case .messageSent: "chat_message_outbound"
        }
    }
}
