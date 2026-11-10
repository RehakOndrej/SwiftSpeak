import SwiftUI
import TS3Audio

/// Strip above the status bar: microphone and speaker at a glance, each with mute, a live meter and a slider.
struct AudioPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let settings = model.audioSettings
        let usesVoiceDetection = settings.activation == .voiceActivation
            || (settings.activation == .pushToTalk && settings.pushToTalkUsesVoiceActivation)

        HStack(spacing: 20) {
            AudioChannelStrip(
                icon: micIcon,
                iconColor: model.micMuted ? .red : (model.isTransmitting ? .green : .secondary),
                muteHelp: model.micMuted ? "Unmute microphone (⇧⌘M)" : "Mute microphone (⇧⌘M)",
                toggleMute: model.toggleMic,
                level: model.inputLevel,
                threshold: usesVoiceDetection ? settings.voiceActivationThresholdDB : nil,
                dimmed: model.micMuted,
                meterHelp: "Microphone level after processing",
                sliderTitle: "Microphone gain",
                value: $model.audioSettings.inputGainDB,
                range: -20...20
            )
            Divider().frame(height: 16)
            AudioChannelStrip(
                icon: model.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                iconColor: model.outputMuted ? .red : .secondary,
                muteHelp: model.outputMuted ? "Unmute speakers (⇧⌘S)" : "Mute speakers (⇧⌘S)",
                toggleMute: model.toggleOutput,
                level: model.outputLevel,
                threshold: nil,
                dimmed: model.outputMuted,
                meterHelp: "Playback level",
                sliderTitle: "Voice volume",
                value: $model.audioSettings.voiceVolumeDB,
                range: -30...20
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var micIcon: String {
        if model.micMuted { return "mic.slash.fill" }
        return model.isTransmitting ? "mic.fill" : "mic"
    }
}

private struct AudioChannelStrip: View {
    let icon: String
    let iconColor: Color
    let muteHelp: String
    let toggleMute: () -> Void
    let level: Float
    let threshold: Float?
    let dimmed: Bool
    let meterHelp: String
    let sliderTitle: String
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleMute) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(muteHelp)

            LevelMeter(level: level, threshold: threshold)
                .opacity(dimmed ? 0.35 : 1)
                .frame(minWidth: 60)
                .help(meterHelp)

            // No `step:`: on macOS that draws one tick mark per step. Snap to whole dB in the binding instead.
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
                .controlSize(.mini)
                .frame(width: 90)
                .help(sliderTitle)
                .accessibilityLabel(sliderTitle)

            Text(decibels)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    /// "+3 dB", "0 dB", "−6 dB" (never "−0").
    private var decibels: String {
        let db = Int(value.rounded())
        return db == 0 ? "0 dB" : String(format: "%+d dB", db)
    }
}

/// Horizontal level meter from −70 to 0 dBFS, with an optional voice-activation threshold mark.
struct LevelMeter: View {
    let level: Float
    let threshold: Float?
    private let floor: Float = -70

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(max(0, min(1, (level - floor) / -floor)))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 0.08), value: fraction)
                if let threshold {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: geo.size.width * CGFloat((threshold - floor) / -floor) - 1)
                }
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Level \(Int(level)) dB")
    }

    private var color: Color {
        if let threshold, level < threshold { return .gray }
        return level > -6 ? .red : .green
    }
}
