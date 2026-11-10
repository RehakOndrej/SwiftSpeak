@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

public enum ActivationMode: String, Codable, CaseIterable, Sendable {
    case continuous
    case voiceActivation
    case pushToTalk
}

public struct AudioSettings: Equatable, Sendable {
    // MARK: Capture
    public var inputDeviceUID: String?   // nil = system default
    public var inputGainDB: Float = 0
    public var activation: ActivationMode = .voiceActivation
    public var voiceActivationThresholdDB: Float = -45
    /// Keep sending this long after the push-to-talk key is released.
    public var pushToTalkReleaseDelayEnabled = true
    public var pushToTalkReleaseDelay: Double = 0.3
    /// Push to talk only sends while voice activation also hears you.
    public var pushToTalkUsesVoiceActivation = false
    /// Turns the microphone down for a moment after each keystroke.
    public var typingAttenuation = true
    public var noiseSuppression = true
    /// 0 (gentle) … 1 (aggressive).
    public var noiseSuppressionStrength: Float = 0.5
    /// Apple voice processing (echo cancellation). Uses the system default output device.
    public var echoCancellation = false
    /// Turn other voices down while you talk.
    public var ducking = false
    public var duckingDB: Float = 10

    // MARK: Playback
    public var outputDeviceUID: String?  // nil = system default
    public var voiceVolumeDB: Float = 0
    public var soundPackVolumeDB: Float = -10
    public var automaticVoiceLeveling = true
    public var ownMicClicks = false
    public var otherMicClicks = false
    public var comfortNoise = false
    public var comfortNoiseDB: Float = -60

    public init() {}
}

extension AudioSettings: Codable {
    private enum Keys: String, CodingKey {
        case inputDeviceUID, inputGainDB, activation, voiceActivationThresholdDB
        case pushToTalkReleaseDelayEnabled, pushToTalkReleaseDelay, pushToTalkUsesVoiceActivation
        case typingAttenuation, noiseSuppression, noiseSuppressionStrength, echoCancellation, ducking, duckingDB
        case outputDeviceUID, voiceVolumeDB, soundPackVolumeDB, automaticVoiceLeveling
        case ownMicClicks, otherMicClicks, comfortNoise, comfortNoiseDB
        case outputVolume // 0.1.0: linear output volume, replaced by voiceVolumeDB
    }

    /// Missing keys keep their defaults, so settings saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = AudioSettings()
        func value<T: Decodable>(_ key: Keys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        inputDeviceUID = try? c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        inputGainDB = value(.inputGainDB, d.inputGainDB)
        activation = value(.activation, d.activation)
        voiceActivationThresholdDB = value(.voiceActivationThresholdDB, d.voiceActivationThresholdDB)
        pushToTalkReleaseDelayEnabled = value(.pushToTalkReleaseDelayEnabled, d.pushToTalkReleaseDelayEnabled)
        pushToTalkReleaseDelay = value(.pushToTalkReleaseDelay, d.pushToTalkReleaseDelay)
        pushToTalkUsesVoiceActivation = value(.pushToTalkUsesVoiceActivation, d.pushToTalkUsesVoiceActivation)
        typingAttenuation = value(.typingAttenuation, d.typingAttenuation)
        noiseSuppression = value(.noiseSuppression, d.noiseSuppression)
        noiseSuppressionStrength = value(.noiseSuppressionStrength, d.noiseSuppressionStrength)
        echoCancellation = value(.echoCancellation, d.echoCancellation)
        ducking = value(.ducking, d.ducking)
        duckingDB = value(.duckingDB, d.duckingDB)
        outputDeviceUID = try? c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        if let db = try? c.decodeIfPresent(Float.self, forKey: .voiceVolumeDB) {
            voiceVolumeDB = db
        } else if let linear = try? c.decodeIfPresent(Float.self, forKey: .outputVolume) {
            voiceVolumeDB = max(-40, 20 * log10f(max(linear, 0.01)))
        }
        soundPackVolumeDB = value(.soundPackVolumeDB, d.soundPackVolumeDB)
        automaticVoiceLeveling = value(.automaticVoiceLeveling, d.automaticVoiceLeveling)
        ownMicClicks = value(.ownMicClicks, d.ownMicClicks)
        otherMicClicks = value(.otherMicClicks, d.otherMicClicks)
        comfortNoise = value(.comfortNoise, d.comfortNoise)
        comfortNoiseDB = value(.comfortNoiseDB, d.comfortNoiseDB)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(inputDeviceUID, forKey: .inputDeviceUID)
        try c.encode(inputGainDB, forKey: .inputGainDB)
        try c.encode(activation, forKey: .activation)
        try c.encode(voiceActivationThresholdDB, forKey: .voiceActivationThresholdDB)
        try c.encode(pushToTalkReleaseDelayEnabled, forKey: .pushToTalkReleaseDelayEnabled)
        try c.encode(pushToTalkReleaseDelay, forKey: .pushToTalkReleaseDelay)
        try c.encode(pushToTalkUsesVoiceActivation, forKey: .pushToTalkUsesVoiceActivation)
        try c.encode(typingAttenuation, forKey: .typingAttenuation)
        try c.encode(noiseSuppression, forKey: .noiseSuppression)
        try c.encode(noiseSuppressionStrength, forKey: .noiseSuppressionStrength)
        try c.encode(echoCancellation, forKey: .echoCancellation)
        try c.encode(ducking, forKey: .ducking)
        try c.encode(duckingDB, forKey: .duckingDB)
        try c.encodeIfPresent(outputDeviceUID, forKey: .outputDeviceUID)
        try c.encode(voiceVolumeDB, forKey: .voiceVolumeDB)
        try c.encode(soundPackVolumeDB, forKey: .soundPackVolumeDB)
        try c.encode(automaticVoiceLeveling, forKey: .automaticVoiceLeveling)
        try c.encode(ownMicClicks, forKey: .ownMicClicks)
        try c.encode(otherMicClicks, forKey: .otherMicClicks)
        try c.encode(comfortNoise, forKey: .comfortNoise)
        try c.encode(comfortNoiseDB, forKey: .comfortNoiseDB)
    }
}

/// Microphone → processing → Opus frames, and Opus frames → per-speaker jitter buffers → mixer → speakers.
///
/// Capture and playback normally run on separate AVAudioEngines so each can use its own device.
/// With echo cancellation on, both run on one engine with Apple's voice processing, which needs to
/// hear what is played to remove it from the microphone.
public final class VoiceEngine: @unchecked Sendable {
    /// Called with (codec, encoded 20 ms frame); an empty frame marks the end of a transmission.
    public var onEncodedFrame: (@Sendable (UInt8, [UInt8]) -> Void)? {
        get { frameSink.withLock { $0 } }
        set { frameSink.withLock { $0 = newValue } }
    }
    /// (level in dBFS after processing, whether the activation gate is open), about 10 times per second.
    public var onInputLevel: (@Sendable (Float, Bool) -> Void)?
    /// True while we are sending voice.
    public var onTransmittingChanged: (@Sendable (Bool) -> Void)?
    /// Non-fatal notes from starting audio, e.g. a device that could not be selected.
    public private(set) var startWarning: String?

    private struct CaptureState {
        var settings = AudioSettings()
        var codec: VoiceCodec = .opusVoice
        var quality = 6
        var encoder: OpusEncoderBox?
        var denoiser = NoiseSuppressor()
        var micMuted = false
        var transmitEnabled = false
        var pushToTalkPressed = false
        var pushToTalkReleasedAt = Date.distantPast
        var lastKeystroke = Date.distantPast
        var typingGain: Float = 1
        var loopback = false
        var pending: [Float] = []
        var transmitting = false
        var hangoverUntil = Date.distantPast
        var lastLevelReport = Date.distantPast
    }

    /// Decoded PCM waiting to be played.
    private struct PCMStream {
        var samples: [Float] = []
        var readIndex = 0
        var playing = false
        var ended = false
        var available: Int { samples.count - readIndex }

        mutating func append(_ pcm: [Float], maxBuffered: Int, prebuffer: Int) {
            samples += pcm
            if available > maxBuffered { readIndex = samples.count - prebuffer }
            if readIndex > OpusConstants.sampleRate {
                samples.removeFirst(readIndex)
                readIndex = 0
            }
        }
    }

    private struct SpeakerDecoder {
        let opus: OpusDecoderBox
        var levelingGain: Float = 1
    }

    private struct Effect {
        let samples: [Float]
        var index = 0
    }

    private struct PlaybackState {
        var streams: [UInt16: PCMStream] = [:]
        var loopback = PCMStream()
        var effects: [Effect] = []
        var muted = false
        var voiceGain: Float = 1
        var effectsGain: Float = 0.3
        var leveling = true
        var otherMicClicks = false
        var duckTarget: Float = 1
        var duck: Float = 1
        var comfortNoiseAmplitude: Float = 0
        var noiseSeed: UInt32 = 0x9E37_79B9
        /// Output metering since the last `takeOutputLevel()`.
        var meterPower: Float = 0
        var meterSamples = 0
    }

    private let capture = Mutex(CaptureState())
    private let playback = Mutex(PlaybackState())
    /// Only touched from `receive` (the network queue), never from the render thread.
    private let decoders = Mutex<[UInt16: SpeakerDecoder]>([:])
    private let frameSink = Mutex<(@Sendable (UInt8, [UInt8]) -> Void)?>(nil)
    private var engines: [AVAudioEngine] = []
    private let engineLock = NSLock()

    private let opusFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private static let prebufferSamples = OpusConstants.frameSamples * 2   // 40 ms
    private static let maxBufferedSamples = OpusConstants.sampleRate / 2   // 500 ms
    private static let clickOn = tone(frequency: 2_400, duration: 0.012, amplitude: 0.35)
    private static let clickOff = tone(frequency: 1_700, duration: 0.012, amplitude: 0.3)

    public init() {}

    // MARK: - Configuration

    public func apply(_ settings: AudioSettings) {
        let restartNeeded = capture.withLock { state -> Bool in
            let old = state.settings
            state.settings = settings
            return old.inputDeviceUID != settings.inputDeviceUID
                || old.outputDeviceUID != settings.outputDeviceUID
                || old.echoCancellation != settings.echoCancellation
        }
        playback.withLock { state in
            state.voiceGain = Self.gain(settings.voiceVolumeDB)
            state.effectsGain = Self.gain(settings.soundPackVolumeDB)
            state.leveling = settings.automaticVoiceLeveling
            state.otherMicClicks = settings.otherMicClicks
            state.comfortNoiseAmplitude = settings.comfortNoise ? Self.gain(settings.comfortNoiseDB) : 0
        }
        if restartNeeded { restart() }
    }

    /// Codec and quality of the channel we are in; voice must be encoded with it.
    public func setCodec(_ codec: VoiceCodec, quality: Int) {
        capture.withLock { state in
            guard state.codec != codec || state.quality != quality || state.encoder == nil else { return }
            state.codec = codec
            state.quality = quality
            state.encoder = OpusEncoderBox(codec: codec, quality: quality)
        }
    }

    public func setMicMuted(_ muted: Bool) { capture.withLock { $0.micMuted = muted } }

    public func setPushToTalk(pressed: Bool) {
        capture.withLock { state in
            if state.pushToTalkPressed && !pressed { state.pushToTalkReleasedAt = Date() }
            state.pushToTalkPressed = pressed
        }
    }

    /// Whether captured voice may be sent at all (connected and in a channel).
    public func setTransmitEnabled(_ enabled: Bool) { capture.withLock { $0.transmitEnabled = enabled } }

    /// Tells typing attenuation that a key was just pressed.
    public func noteKeystroke() { capture.withLock { $0.lastKeystroke = Date() } }

    /// "Begin Test": plays your processed microphone back to you, gated like real transmission.
    public func setLoopback(_ enabled: Bool) {
        capture.withLock { $0.loopback = enabled }
        if !enabled { playback.withLock { $0.loopback = PCMStream() } }
    }

    public func setOutputMuted(_ muted: Bool) {
        playback.withLock { state in
            state.muted = muted
            if muted { state.streams.removeAll() }
        }
    }

    /// Plays a short sound (48 kHz mono) at the sound pack volume.
    public func playEffect(_ samples: [Float]) {
        playback.withLock { state in
            state.effects.removeAll { $0.index >= $0.samples.count }
            if state.effects.count < 16 { state.effects.append(Effect(samples: samples)) }
        }
    }

    public func playTestSound() {
        let a = Self.tone(frequency: 880, duration: 0.18, amplitude: 0.5)
        let b = Self.tone(frequency: 1_320, duration: 0.3, amplitude: 0.5)
        playEffect(a + [Float](repeating: 0, count: 2_400) + b)
    }

    // MARK: - Lifecycle

    public func start() throws {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard engines.isEmpty else { return }
        startWarning = nil
        let settings = capture.withLock { $0.settings }
        do {
            if settings.echoCancellation {
                try startDuplex(settings)
            } else {
                try startOutput(settings)
                try startInput(settings)
            }
        } catch {
            stopEngines()
            throw error
        }
        if capture.withLock({ $0.encoder == nil }) {
            setCodec(.opusVoice, quality: 6)
        }
    }

    public func stop() {
        engineLock.lock()
        stopEngines()
        engineLock.unlock()
        playback.withLock { state in
            state.streams.removeAll()
            state.loopback = PCMStream()
            state.effects.removeAll()
        }
        decoders.withLock { $0.removeAll() }
        capture.withLock { $0.denoiser.reset() }
        endTransmission()
    }

    public var isRunning: Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        return !engines.isEmpty
    }

    private func restart() {
        guard isRunning else { return }
        stop()
        do {
            try start()
        } catch {
            startWarning = "Audio failed to restart: \(error.localizedDescription)"
        }
    }

    private func stopEngines() {
        for engine in engines {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engines.removeAll()
    }

    private func startOutput(_ settings: AudioSettings) throws {
        let engine = AVAudioEngine()
        if let device = AudioDevices.device(uid: settings.outputDeviceUID, inputs: false) {
            try setDevice(device, on: engine.outputNode)
        }
        attachPlayback(to: engine)
        try engine.start()
        engines.append(engine)
    }

    private func startInput(_ settings: AudioSettings) throws {
        let engine = AVAudioEngine()
        if let device = AudioDevices.device(uid: settings.inputDeviceUID, inputs: true) {
            try setDevice(device, on: engine.inputNode)
        }
        try installCaptureTap(on: engine)
        try engine.start()
        engines.append(engine)
    }

    /// One engine with Apple voice processing: echo cancellation needs input and output together.
    private func startDuplex(_ settings: AudioSettings) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingAGCEnabled = false // our own gain and leveling apply
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        if let device = AudioDevices.device(uid: settings.inputDeviceUID, inputs: true) {
            do {
                try setDevice(device, on: input)
            } catch {
                startWarning = "Echo cancellation is using the system default microphone."
            }
        }
        attachPlayback(to: engine)
        try installCaptureTap(on: engine)
        try engine.start()
        engines.append(engine)
    }

    private func attachPlayback(to engine: AVAudioEngine) {
        let source = AVAudioSourceNode(format: opusFormat) { [weak self] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frameCount)
            out.initialize(repeating: 0, count: n)
            self?.mix(into: out, count: n)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: opusFormat)
    }

    private func installCaptureTap(on engine: AVAudioEngine) throws {
        let hwFormat = engine.inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "TS3Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No usable input device"])
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: opusFormat) else {
            throw NSError(domain: "TS3Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot convert from \(hwFormat)"])
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.handleCaptured(buffer, converter: converter)
        }
    }

    private func setDevice(_ device: AudioDeviceID, on node: AVAudioIONode) throws {
        guard let unit = node.audioUnit else { return }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not select audio device (\(status))"])
        }
    }

    // MARK: - Capture

    private func handleCaptured(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = opusFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: opusFormat, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = converted.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))

        var frames: [[UInt8]] = []
        var monitor: [Float] = []
        var codec = VoiceCodec.opusVoice.rawValue
        var report: (level: Float, open: Bool)?
        var transmitChange: Bool?
        var settings = AudioSettings()
        capture.withLock { state in
            settings = state.settings
            codec = state.codec.rawValue
            if settings.noiseSuppression {
                state.pending += state.denoiser.process(samples, strength: settings.noiseSuppressionStrength)
            } else {
                state.denoiser.reset()
                state.pending += samples
            }
            let gain = Self.gain(settings.inputGainDB)
            let frameCount = OpusConstants.frameSamples

            while state.pending.count >= frameCount {
                var frame = Array(state.pending[0..<frameCount])
                state.pending.removeFirst(frameCount)
                let now = Date()

                // Typing attenuation: −20 dB for a moment after each keystroke, ramped to avoid clicks.
                let typing = settings.typingAttenuation && now.timeIntervalSince(state.lastKeystroke) < 0.25
                let typingStart = state.typingGain
                let typingEnd: Float = typing ? 0.1 : 1
                var sum: Float = 0
                for i in frame.indices {
                    let ramp = typingStart + (typingEnd - typingStart) * Float(i) / Float(frameCount)
                    frame[i] = max(-1, min(1, frame[i] * gain * ramp))
                    sum += frame[i] * frame[i]
                }
                state.typingGain = typingEnd
                let db = 10 * log10f(max(sum / Float(frameCount), 1e-10))

                if db >= settings.voiceActivationThresholdDB {
                    state.hangoverUntil = now.addingTimeInterval(0.4)
                }
                let voiceDetected = now < state.hangoverUntil
                let wantsToSpeak: Bool
                switch settings.activation {
                case .continuous:
                    wantsToSpeak = true
                case .voiceActivation:
                    wantsToSpeak = voiceDetected
                case .pushToTalk:
                    let held = state.pushToTalkPressed
                        || (settings.pushToTalkReleaseDelayEnabled
                            && now.timeIntervalSince(state.pushToTalkReleasedAt) < settings.pushToTalkReleaseDelay)
                    wantsToSpeak = held && (!settings.pushToTalkUsesVoiceActivation || voiceDetected)
                }

                if now.timeIntervalSince(state.lastLevelReport) > 0.1 {
                    state.lastLevelReport = now
                    report = (db, wantsToSpeak)
                }
                if state.loopback {
                    monitor += wantsToSpeak ? frame : [Float](repeating: 0, count: frameCount)
                }

                let sending = wantsToSpeak && state.transmitEnabled && !state.micMuted
                if sending, let packet = state.encoder?.encode(frame) {
                    frames.append(packet)
                } else if !sending && state.transmitting {
                    frames.append([]) // end of stream
                }
                if sending != state.transmitting {
                    state.transmitting = sending
                    transmitChange = sending
                }
            }
        }

        if let report { onInputLevel?(report.level, report.open) }
        if let sink = onEncodedFrame {
            for f in frames { sink(codec, f) }
        }
        if !monitor.isEmpty {
            playback.withLock { $0.loopback.append(monitor, maxBuffered: Self.maxBufferedSamples / 2, prebuffer: Self.prebufferSamples) }
        }
        if let transmitChange {
            transmittingChanged(transmitChange, settings: settings)
        }
    }

    private func transmittingChanged(_ transmitting: Bool, settings: AudioSettings) {
        playback.withLock { $0.duckTarget = transmitting && settings.ducking ? Self.gain(-settings.duckingDB) : 1 }
        if settings.ownMicClicks { playEffect(transmitting ? Self.clickOn : Self.clickOff) }
        onTransmittingChanged?(transmitting)
    }

    private func endTransmission() {
        let (wasTransmitting, codec, settings) = capture.withLock { state -> (Bool, UInt8, AudioSettings) in
            defer { state.transmitting = false; state.pending.removeAll() }
            return (state.transmitting, state.codec.rawValue, state.settings)
        }
        if wasTransmitting {
            onEncodedFrame?(codec, [])
            transmittingChanged(false, settings: settings)
        }
    }

    // MARK: - Playback

    /// Feeds one received voice packet. Empty data marks the end of that speaker's stream.
    public func receive(clientId: UInt16, codec: UInt8, data: [UInt8]) {
        guard codec == VoiceCodec.opusVoice.rawValue || codec == VoiceCodec.opusMusic.rawValue else { return }
        let (muted, leveling) = playback.withLock { ($0.muted, $0.leveling) }
        guard !muted else { return }

        if data.isEmpty {
            playback.withLock { state in
                guard state.streams[clientId] != nil, state.streams[clientId]?.ended == false else { return }
                state.streams[clientId]?.ended = true
                if state.otherMicClicks { state.effects.append(Effect(samples: Self.clickOff)) }
            }
            return
        }

        // Decode outside the playback lock so the render thread never waits on Opus.
        let pcm = decoders.withLock { decoders -> [Float] in
            if decoders[clientId] == nil {
                guard let opus = OpusDecoderBox() else { return [] }
                decoders[clientId] = SpeakerDecoder(opus: opus)
            }
            var pcm = decoders[clientId]!.opus.decode(data)
            if leveling, !pcm.isEmpty {
                var gain = decoders[clientId]!.levelingGain
                Self.level(&pcm, gain: &gain)
                decoders[clientId]!.levelingGain = gain
            }
            return pcm
        }
        guard !pcm.isEmpty else { return }

        playback.withLock { state in
            let starting = state.streams[clientId].map { $0.ended || (!$0.playing && $0.available == 0) } ?? true
            var stream = state.streams.removeValue(forKey: clientId) ?? PCMStream()
            stream.ended = false
            stream.append(pcm, maxBuffered: Self.maxBufferedSamples, prebuffer: Self.prebufferSamples)
            state.streams[clientId] = stream
            if starting && state.otherMicClicks {
                state.effects.removeAll { $0.index >= $0.samples.count }
                state.effects.append(Effect(samples: Self.clickOn))
            }
            // Drop finished speakers here rather than on the render thread.
            for (id, s) in state.streams where s.ended && s.available == 0 {
                state.streams[id] = nil
            }
        }
    }

    public func removeSpeaker(_ clientId: UInt16) {
        playback.withLock { _ = $0.streams.removeValue(forKey: clientId) }
        decoders.withLock { _ = $0.removeValue(forKey: clientId) }
    }

    /// Automatic voice leveling: nudges each speaker toward about −23 dBFS RMS, within ±12 dB.
    private static func level(_ pcm: inout [Float], gain: inout Float) {
        var sum: Float = 0
        for s in pcm { sum += s * s }
        let db = 10 * log10f(max(sum / Float(pcm.count), 1e-10))
        if db > -50 { // only adapt on speech, not on silence
            let desired = max(0.25, min(4, powf(10, (-23 - db) / 20)))
            gain += (desired - gain) * 0.1
        }
        for i in pcm.indices { pcm[i] *= gain }
    }

    /// Render thread: no allocation, no decoding, only short lock hold.
    private func mix(into out: UnsafeMutablePointer<Float>, count: Int) {
        playback.withLock { state in
            for i in state.streams.values.indices {
                Self.read(&state.streams.values[i], into: out, count: count, gain: state.voiceGain)
            }

            // Ducking applies to other voices only, smoothed over ~20 ms.
            var duck = state.duck
            let target = state.duckTarget
            if duck != target || target != 1 {
                for i in 0..<count {
                    duck += (target - duck) * 0.001
                    out[i] *= duck
                }
                state.duck = abs(duck - target) < 0.0005 ? target : duck
            }

            Self.read(&state.loopback, into: out, count: count, gain: state.voiceGain)

            let effectsGain = state.effectsGain
            for e in state.effects.indices where state.effects[e].index < state.effects[e].samples.count {
                let start = state.effects[e].index
                let n = min(count, state.effects[e].samples.count - start)
                state.effects[e].samples.withUnsafeBufferPointer { s in
                    for i in 0..<n { out[i] += s[start + i] * effectsGain }
                }
                state.effects[e].index += n
            }

            let noise = state.comfortNoiseAmplitude
            if noise > 0 {
                var x = state.noiseSeed
                for i in 0..<count {
                    x ^= x << 13; x ^= x >> 17; x ^= x << 5
                    out[i] += (Float(x) / Float(UInt32.max) * 2 - 1) * noise
                }
                state.noiseSeed = x
            }

            var power: Float = 0
            for i in 0..<count {
                out[i] = max(-1, min(1, out[i]))
                power += out[i] * out[i]
            }
            state.meterPower += power
            state.meterSamples += count
        }
    }

    /// RMS level in dBFS of everything played since the last call (−100 when nothing played).
    public func takeOutputLevel() -> Float {
        playback.withLock { state in
            defer { state.meterPower = 0; state.meterSamples = 0 }
            guard state.meterSamples > 0 else { return -100 }
            return 10 * log10f(max(state.meterPower / Float(state.meterSamples), 1e-10))
        }
    }

    private static func read(_ stream: inout PCMStream, into out: UnsafeMutablePointer<Float>, count: Int, gain: Float) {
        if !stream.playing && (stream.available >= prebufferSamples || (stream.ended && stream.available > 0)) {
            stream.playing = true
        }
        guard stream.playing else { return }
        let n = min(count, stream.available)
        let start = stream.readIndex
        stream.samples.withUnsafeBufferPointer { s in
            for i in 0..<n { out[i] += s[start + i] * gain }
        }
        stream.readIndex += n
        if stream.available == 0 { stream.playing = false }
    }

    // MARK: - Helpers

    private static func gain(_ db: Float) -> Float { powf(10, db / 20) }

    /// A short sine blip with a fast fade-out, at 48 kHz.
    static func tone(frequency: Float, duration: Double, amplitude: Float) -> [Float] {
        let n = Int(duration * Double(OpusConstants.sampleRate))
        let rate = Float(OpusConstants.sampleRate)
        return (0..<n).map { i in
            let t = Float(i) / rate
            let attack = min(1, Float(i) / 48)              // 1 ms fade-in
            let decay = expf(-5 * Float(i) / Float(n))      // fade to ~1 %
            return sinf(2 * .pi * frequency * t) * amplitude * attack * decay
        }
    }
}
