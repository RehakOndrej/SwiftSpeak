import Foundation
import Synchronization
import Testing
@testable import TS3Audio

private func rms(_ x: ArraySlice<Float>) -> Float {
    sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1)))
}

private func db(_ x: Float) -> Float { 20 * log10f(max(x, 1e-9)) }

/// Deterministic white noise in -1…1.
private func noise(_ count: Int, seed: UInt64 = 42) -> [Float] {
    var generator = seed
    return (0..<count).map { _ in
        generator = generator &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: generator) >> 11) / Float(1 << 52)
    }
}

@Suite struct NoiseSuppressorTests {
    @Test func keepsSampleCountForAnyChunking() {
        let ns = NoiseSuppressor()
        var total = 0
        for size in [1, 7, 480, 960, 1023, 4096, 333] {
            total += ns.process([Float](repeating: 0.1, count: size), strength: 0.5).count
        }
        #expect(total == 1 + 7 + 480 + 960 + 1023 + 4096 + 333)
    }

    @Test func removesSteadyNoise() {
        let ns = NoiseSuppressor()
        let input = noise(48_000 * 3).map { $0 * 0.05 }
        var out: [Float] = []
        for chunk in stride(from: 0, to: input.count, by: 960) {
            out += ns.process(Array(input[chunk..<min(chunk + 960, input.count)]), strength: 1)
        }
        let before = db(rms(input[96_000...]))
        let after = db(rms(out[96_000...]))
        #expect(before - after > 15, "noise only reduced by \(before - after) dB")
    }

    /// Speech-like: a tone that switches on and off every 200 ms over a quiet noise floor.
    /// (A constant tone is indistinguishable from hum and is meant to be removed.)
    @Test func keepsIntermittentToneOverQuietNoise() {
        let ns = NoiseSuppressor()
        let floor = noise(48_000 * 3).map { $0 * 0.005 }
        let burst = 9_600 // 200 ms
        func on(_ i: Int) -> Bool { (i / burst) % 2 == 0 }
        let input = (0..<floor.count).map { i in (on(i) ? sinf(2 * .pi * 440 * Float(i) / 48_000) * 0.3 : 0) + floor[i] }
        var out: [Float] = []
        for chunk in stride(from: 0, to: input.count, by: 960) {
            out += ns.process(Array(input[chunk..<min(chunk + 960, input.count)]), strength: 0.5)
        }
        // Output lags by one 1024-sample window; compare the middle of each "on" burst in the last second.
        let delay = 1024
        var inPower: Float = 0, outPower: Float = 0, onNoise: Float = 0, offNoise: Float = 0
        for start in stride(from: 96_000, to: input.count - burst, by: burst) {
            let mid = (start + 2_000)..<(start + burst - 2_000)
            if on(start) {
                inPower += mid.reduce(0) { $0 + input[$1] * input[$1] }
                outPower += mid.reduce(0) { $0 + out[$1 + delay] * out[$1 + delay] }
            } else {
                onNoise += mid.reduce(0) { $0 + input[$1] * input[$1] }
                offNoise += mid.reduce(0) { $0 + out[$1 + delay] * out[$1 + delay] }
            }
        }
        let toneLoss = 10 * log10f(inPower / outPower)
        let noiseCut = 10 * log10f(onNoise / max(offNoise, 1e-12))
        #expect(abs(toneLoss) < 1.5, "tone level changed by \(toneLoss) dB")
        #expect(noiseCut > 6, "noise between bursts only reduced by \(noiseCut) dB")
    }
}

@Suite struct AudioSettingsTests {
    @Test func loadsSettingsSavedBy010() throws {
        let json = #"{"inputGainDB":3,"outputVolume":0.5,"activation":"pushToTalk","voiceActivationThresholdDB":-40}"#
        let s = try JSONDecoder().decode(AudioSettings.self, from: Data(json.utf8))
        #expect(s.inputGainDB == 3)
        #expect(s.activation == .pushToTalk)
        #expect(abs(s.voiceVolumeDB - -6.02) < 0.05)
        #expect(s.noiseSuppression == AudioSettings().noiseSuppression)
    }

    @Test func roundTrips() throws {
        var s = AudioSettings()
        s.inputDeviceUID = "mic"
        s.ducking = true
        s.duckingDB = 14
        s.comfortNoiseDB = -55
        let back = try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite struct VoiceEnginePlaybackTests {
    /// Notification sounds must play without the microphone (e.g. while disconnected).
    @Test(.enabled(if: AudioDevices.defaultOutput() != nil, "needs an output device"))
    func playsEffectWithPlaybackOnly() async throws {
        let engine = VoiceEngine()
        var settings = AudioSettings()
        settings.soundPackVolumeDB = -60 // inaudible
        engine.apply(settings)
        try await engine.startPlayback()
        #expect(engine.isRunning)
        #expect(!engine.isCapturing)
        _ = engine.takeOutputLevel()
        engine.playEffect([Float](repeating: 0.5, count: 48_000 / 4))
        #expect(engine.isPlayingEffects)
        try await Task.sleep(for: .milliseconds(200))
        let level = engine.takeOutputLevel()
        engine.stop()
        #expect(level > -90, "output level \(level) dBFS: the effect never reached the speakers")
        #expect(!engine.isRunning)
    }
}

extension VoiceEnginePlaybackTests {
    /// Regression: only the first sound of a session was heard.
    @Test(.enabled(if: AudioDevices.defaultOutput() != nil, "needs an output device"))
    func playsSecondEffectAfterFirstFinished() async throws {
        let engine = VoiceEngine()
        var settings = AudioSettings()
        settings.soundPackVolumeDB = -60
        engine.apply(settings)
        try await engine.startPlayback()
        engine.playEffect([Float](repeating: 0.5, count: 4_800)) // 100 ms
        try await Task.sleep(for: .milliseconds(400))
        #expect(!engine.isPlayingEffects)
        _ = engine.takeOutputLevel()
        let quiet = engine.takeOutputLevel()
        engine.playEffect([Float](repeating: 0.5, count: 24_000))
        try await Task.sleep(for: .milliseconds(200))
        let level = engine.takeOutputLevel()
        engine.stop()
        #expect(level > -90, "second sound: output \(level) dBFS (before: \(quiet))")
    }
}

extension VoiceEnginePlaybackTests {
    /// Regression: after a device reconfiguration (AirPods switching mode) playback stayed dead.
    @Test(.enabled(if: AudioDevices.defaultOutput() != nil, "needs an output device"))
    func playbackSurvivesConfigurationChange() async throws {
        let engine = VoiceEngine()
        var settings = AudioSettings()
        settings.soundPackVolumeDB = -60
        engine.apply(settings)
        try await engine.startPlayback()
        engine.configurationChanged(.output)
        engine.configurationChanged(.output) // bursts are coalesced
        try await Task.sleep(for: .milliseconds(1_400)) // settle time 0.8 s + rebuild
        #expect(engine.isRunning)
        #expect(!engine.isCapturing, "rebuilding playback must not open the microphone")
        _ = engine.takeOutputLevel()
        engine.playEffect([Float](repeating: 0.5, count: 24_000))
        try await Task.sleep(for: .milliseconds(200))
        let level = engine.takeOutputLevel()
        engine.stop()
        #expect(level > -90, "after rebuild: output \(level) dBFS")
    }
}

@Suite struct VoiceEngineCallbackTests {
    /// Regression: each read of `onEncodedFrame` nested the stored closure one level deeper, and
    /// after ten minutes of microphone buffers calling it overflowed the stack (a crash, so this
    /// test fails by crashing).
    @Test func readingTheFrameSinkManyTimesDoesNotNestIt() {
        let engine = VoiceEngine()
        let calls = Mutex(0)
        engine.onEncodedFrame = { _, _ in calls.withLock { $0 += 1 } }
        for _ in 0..<300_000 { _ = engine.onEncodedFrame }
        engine.onEncodedFrame?(4, [])
        #expect(calls.withLock { $0 } == 1)
    }
}

@Suite struct BluetoothMicrophoneTests {
    @Test func substitutesBuiltInMicOnlyForBluetoothSystemDefault() {
        var settings = AudioSettings()
        settings.inputDeviceUID = "chosen-explicitly"
        #expect(VoiceEngine.substitutedInput(for: settings) == nil)
        settings.inputDeviceUID = nil
        settings.avoidBluetoothMicrophone = false
        #expect(VoiceEngine.substitutedInput(for: settings) == nil)
        settings.avoidBluetoothMicrophone = true
        let defaultIsBluetooth = AudioDevices.defaultInput().map(AudioDevices.isBluetooth) ?? false
        let expected = defaultIsBluetooth ? AudioDevices.builtInInput() : nil
        let actual = VoiceEngine.substitutedInput(for: settings)
        print("default input is Bluetooth: \(defaultIsBluetooth); substitute: \(actual?.name ?? "none")")
        #expect(actual == expected)
    }
}
