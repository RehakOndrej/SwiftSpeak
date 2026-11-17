import AppKit
import SwiftUI
import TS3Audio
import TS3Kit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Capture", systemImage: "mic") { CaptureSettingsView() }
            Tab("Playback", systemImage: "speaker.wave.2") { PlaybackSettingsView() }
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutSettingsView() }
            Tab("Identity", systemImage: "person.badge.key") { IdentitySettingsView() }
        }
        .frame(width: 560)
        // Audio runs while the window is open, whichever tab is shown (meter, test, test sound).
        .onAppear { model.settingsAppeared() }
        .onDisappear { model.settingsDisappeared() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccessibility()
        }
    }
}

// MARK: - Capture

private struct CaptureSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var inputs: [AudioDevice] = []
    /// Looked up when the tab opens, not on every redraw (device queries can stall while a headset reconfigures).
    @State private var substitute: AudioDevice?

    var body: some View {
        @Bindable var model = model
        let settings = model.audioSettings
        let usesVoiceDetection = settings.activation == .voiceActivation
            || (settings.activation == .pushToTalk && settings.pushToTalkUsesVoiceActivation)

        Form {
            Section {
                Picker("Capture device", selection: $model.audioSettings.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(inputs) { Text($0.name).tag(Optional($0.uid)) }
                }
                if settings.inputDeviceUID == nil {
                    Toggle(isOn: $model.audioSettings.avoidBluetoothMicrophone) {
                        Text("Keep Bluetooth headphones in high quality")
                        Text(bluetoothNote)
                    }
                }
                DecibelSlider(title: "Microphone gain", value: $model.audioSettings.inputGainDB, range: -20...20)
            }

            Section("Activation") {
                Picker("Activation", selection: $model.audioSettings.activation) {
                    Text("Push to talk").tag(ActivationMode.pushToTalk)
                    Text("Continuous transmission").tag(ActivationMode.continuous)
                    Text("Voice activity detection").tag(ActivationMode.voiceActivation)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if settings.activation == .pushToTalk {
                    LabeledContent("Hotkey") {
                        HotkeyRecorder(hotkey: Binding(get: { model.hotkey }, set: { if let key = $0 { model.hotkey = key } }),
                                       canClear: false)
                    }
                    Toggle("Release delay", isOn: $model.audioSettings.pushToTalkReleaseDelayEnabled)
                    if settings.pushToTalkReleaseDelayEnabled {
                        LabeledContent("Delay") {
                            Stepper(value: $model.audioSettings.pushToTalkReleaseDelay, in: 0.1...2, step: 0.1) {
                                Text(String(format: "%.1f s", settings.pushToTalkReleaseDelay)).monospacedDigit()
                            }
                        }
                    }
                    Toggle(isOn: $model.audioSettings.pushToTalkUsesVoiceActivation) {
                        Text("Add voice activity detection")
                        Text("Only send while the key is held and you are actually speaking.")
                    }
                    if !model.accessibilityTrusted {
                        AccessibilityNote()
                    }
                }

                if usesVoiceDetection {
                    DecibelSlider(title: "Threshold", value: $model.audioSettings.voiceActivationThresholdDB,
                                  range: -70...(-10), step: 1, signed: false)
                }

                LabeledContent("Level") {
                    HStack(spacing: 10) {
                        LevelMeter(level: model.inputLevel, threshold: usesVoiceDetection ? settings.voiceActivationThresholdDB : nil)
                        Circle()
                            .fill(model.inputGateOpen ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 10, height: 10)
                            .help(model.inputGateOpen ? "Your voice would be sent" : "Your voice would not be sent")
                            .accessibilityLabel(model.inputGateOpen ? "Transmitting" : "Not transmitting")
                    }
                }

                LabeledContent {
                    Button(model.isTestingCapture ? "Stop Test" : "Begin Test") { model.isTestingCapture.toggle() }
                } label: {
                    Text("Test")
                    Text("Hear yourself as others will. Use headphones to avoid feedback.")
                }
            }

            Section("Digital signal processing") {
                Toggle(isOn: $model.audioSettings.typingAttenuation) {
                    Text("Typing attenuation")
                    Text("Turns the microphone down briefly while you type. Typing in other apps is only noticed with Accessibility access.")
                }
                Toggle(isOn: $model.audioSettings.noiseSuppression) {
                    Text("Remove background noise")
                    Text("Removes steady noise such as fans, hum and hiss.")
                }
                if settings.noiseSuppression {
                    LabeledContent("Strength") {
                        HStack {
                            Text("min").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $model.audioSettings.noiseSuppressionStrength, in: 0...1)
                            Text("max").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(isOn: $model.audioSettings.echoCancellation) {
                    Text("Echo cancellation")
                    Text("Removes your speakers' sound from the microphone. Uses Apple voice processing, which plays through the system default output device.")
                }
                Toggle(isOn: $model.audioSettings.ducking) {
                    Text("Echo reduction (ducking)")
                    Text("Turns other voices down while you talk.")
                }
                if settings.ducking {
                    LabeledContent("Reduce playback volume by") {
                        Stepper(value: $model.audioSettings.duckingDB, in: 1...40, step: 1) {
                            Text("\(Int(settings.duckingDB)) dB").monospacedDigit()
                        }
                    }
                }
            }

            if let error = model.audioError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .onAppear {
            inputs = AudioDevices.inputs()
            substitute = VoiceEngine.substitutedInput(for: model.audioSettings)
        }
    }

    private var bluetoothNote: String {
        if model.audioSettings.avoidBluetoothMicrophone, let substitute {
            return "Using \(substitute.name) now: a Bluetooth headset's microphone switches it to low-quality call audio."
        }
        return "When the default microphone is a Bluetooth headset, use the Mac's built-in microphone instead. Using the headset's microphone switches it to low-quality call audio."
    }
}

private struct AccessibilityNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Keyboard hotkeys only work while SwiftSpeak is in front. Allow Accessibility access to use them from other apps.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Spacer()
            Button("Allow…") { model.requestAccessibility() }
        }
    }
}

/// Click, then press a key (with modifiers), modifiers alone, or an extra mouse button.
private struct HotkeyRecorder: View {
    @Environment(AppModel.self) private var model
    @Binding var hotkey: Hotkey?
    var canClear = true
    @State private var recording = false
    @State private var monitor: Any?
    @State private var peakModifiers: NSEvent.ModifierFlags = []

    var body: some View {
        HStack {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Press keys or a mouse button…" : (hotkey?.display ?? "Not set"))
                    .frame(minWidth: 180)
            }
            if recording {
                Button("Cancel", action: stop)
            } else if canClear && hotkey != nil {
                Button {
                    hotkey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        peakModifiers = []
        model.isRecordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        model.isRecordingHotkey = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(Hotkey.relevantModifiers)
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 && modifiers.isEmpty { // Esc cancels
                stop()
            } else {
                hotkey = Hotkey(trigger: .key(code: event.keyCode, name: Hotkey.keyName(event)), modifiers: modifiers)
                stop()
            }
            return true
        case .flagsChanged:
            // Modifiers alone: remember the combination, take it once they are all released.
            if !modifiers.isEmpty {
                peakModifiers.formUnion(modifiers)
            } else if !peakModifiers.isEmpty {
                hotkey = Hotkey(trigger: .modifiersOnly, modifiers: peakModifiers)
                stop()
            }
            return false
        case .otherMouseDown:
            hotkey = Hotkey(trigger: .mouseButton(event.buttonNumber), modifiers: modifiers)
            stop()
            return true
        default:
            return false
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(Shortcuts.Action.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HotkeyRecorder(hotkey: $model.shortcuts[dynamicMember: action.keyPath])
                    }
                }
            } footer: {
                Text("These work in any app once SwiftSpeak has Accessibility access; extra mouse buttons work without it. Push to talk is set in Capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.accessibilityTrusted {
                Section { AccessibilityNote() }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}

// MARK: - Playback

private struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var outputs: [AudioDevice] = []

    var body: some View {
        @Bindable var model = model
        let settings = model.audioSettings

        Form {
            Section {
                Picker("Playback device", selection: $model.audioSettings.outputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(outputs) { Text($0.name).tag(Optional($0.uid)) }
                }
                .disabled(settings.echoCancellation)
                if settings.echoCancellation {
                    Text("Echo cancellation is on, so sound plays through the system default output device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Volume") {
                DecibelSlider(title: "Voice volume adjustment", value: $model.audioSettings.voiceVolumeDB, range: -30...20)
                DecibelSlider(title: "Sound pack volume", value: $model.audioSettings.soundPackVolumeDB, range: -40...0)
                LabeledContent("Test") {
                    Button("Play Test Sound") { model.voice.playTestSound() }
                }
            }

            SoundPackSection()

            Section("Options") {
                Toggle(isOn: $model.audioSettings.automaticVoiceLeveling) {
                    Text("Automatic voice volume leveling")
                    Text("Brings quiet and loud speakers to a similar volume.")
                }
                Toggle("Own client plays mic clicks", isOn: $model.audioSettings.ownMicClicks)
                Toggle("Other clients play mic clicks", isOn: $model.audioSettings.otherMicClicks)
                Toggle(isOn: $model.audioSettings.comfortNoise) {
                    Text("Comfort noise")
                    Text("A faint hiss so silence between speakers doesn't sound like a dropped connection.")
                }
                if settings.comfortNoise {
                    DecibelSlider(title: "Comfort noise level", value: $model.audioSettings.comfortNoiseDB,
                                  range: -80...(-40), step: 1, signed: false)
                }
            }

            if let error = model.audioError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .onAppear { outputs = AudioDevices.outputs() }
    }
}

private struct SoundPackSection: View {
    @Environment(AppModel.self) private var model
    @State private var available = 0

    var body: some View {
        @Bindable var model = model
        Section("Sound pack") {
            Toggle(isOn: $model.soundsEnabled) {
                Text("Spoken notifications")
                Text("\"Connected\", \"User joined your channel\" and so on, at the sound pack volume.")
            }
            LabeledContent("Sounds found") {
                HStack {
                    Text("\(available) of \(SoundPack.allNames.count)").monospacedDigit()
                    Button("Reload") {
                        model.soundPack.reload()
                        available = model.soundPack.availableCount
                    }
                    Button("Open Sounds Folder") { model.soundPack.revealFolder() }
                }
            }
        }
        .onAppear { available = model.soundPack.availableCount }
    }
}

// MARK: - Shared controls

private struct DecibelSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float = 0.5
    var signed = true

    var body: some View {
        LabeledContent(title) {
            HStack {
                // No `step:`: on macOS it draws one tick mark per step. Snap in the binding instead.
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                Text(String(format: signed ? "%+.1f dB" : "%.0f dB", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }
}

// MARK: - Identity

private struct IdentitySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRegenerate = false

    var body: some View {
        Form {
            Section("Your identity") {
                LabeledContent("Unique ID") {
                    Text(model.identity.uid)
                        .textSelection(.enabled)
                        .font(.body.monospaced())
                }
                LabeledContent("Security level", value: "\(model.identity.securityLevel)")
            }
            Section {
                Button("Generate new identity…", role: .destructive) { confirmRegenerate = true }
            } footer: {
                Text("Servers recognise you by this identity. A new one loses any groups or permissions given to the current one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Replace your identity?", isPresented: $confirmRegenerate) {
            Button("Generate new identity", role: .destructive) { model.regenerateIdentity() }
        } message: {
            Text("Servers will treat you as a new user.")
        }
    }
}
