import SwiftUI
import TS3Kit

struct MainView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("layout.chatSplit") private var topFraction = 0.62
    @AppStorage("layout.treeSplit") private var treeFraction = 0.5
    @AppStorage("layout.audioPanel") private var showAudioPanel = true

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let error = model.audioError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.orange.opacity(0.1))
            }
            SplitPane(axis: .vertical, fraction: $topFraction, minFirst: 200, minSecond: 170) {
                content
            } second: {
                ChatPanel()
            }
            if showAudioPanel {
                AudioPanel()
            }
            StatusBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showConnectSheet) {
            ConnectView()
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .profile: ProfileSheet()
            case .moderation(let action, let clientId): ModerationSheet(action: action, clientId: clientId)
            }
        }
        .onAppear {
            if model.client.status == .disconnected { model.showConnectSheet = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.client.status {
        case .connected where model.client.isReady:
            SplitPane(axis: .horizontal, fraction: $treeFraction, minFirst: 220, minSecond: 240) {
                ServerTreeView()
            } second: {
                InfoPanel()
            }
        case .connecting, .connected:
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disconnected, .failed:
            ContentUnavailableView {
                Label("Not connected", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                VStack(spacing: 6) {
                    if case .failed(let message) = model.client.status {
                        Text(message)
                    } else if model.reconnect == nil {
                        Text("Connect to a TeamSpeak 3 server to see its channels.")
                    }
                    if let pending = model.reconnect {
                        ReconnectCountdown(pending: pending)
                    }
                }
            } actions: {
                if model.reconnect != nil {
                    HStack {
                        Button("Reconnect Now") { model.reconnectNow() }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { model.cancelReconnect() }
                    }
                } else {
                    Button("Connect…") { model.showConnectSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if model.client.status == .connected || model.client.status == .connecting {
                Button { model.disconnect() } label: {
                    Label("Disconnect", systemImage: "bolt.horizontal.circle.fill")
                }
                .help("Disconnect")
            } else {
                Button { model.showConnectSheet = true } label: {
                    Label("Connect", systemImage: "bolt.horizontal.circle")
                }
                .help("Connect to a server")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { model.micMuted }, set: { _ in model.toggleMic() })) {
                ToolbarToggleLabel(title: model.micMuted ? "Microphone muted" : "Microphone on",
                                   systemImage: model.micMuted ? "mic.slash.fill" : "mic.fill")
            }
            .help(model.micMuted ? "Unmute microphone (⇧⌘M)" : "Mute microphone (⇧⌘M)")

            Toggle(isOn: Binding(get: { model.outputMuted }, set: { _ in model.toggleOutput() })) {
                ToolbarToggleLabel(title: model.outputMuted ? "Speakers muted" : "Speakers on",
                                   systemImage: model.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help(model.outputMuted ? "Unmute speakers (⇧⌘S)" : "Mute speakers (⇧⌘S)")

            Toggle(isOn: Binding(get: { model.away }, set: { _ in model.toggleAway() })) {
                ToolbarToggleLabel(title: model.away ? "Away" : "Available",
                                   systemImage: model.away ? "moon.zzz.fill" : "moon.zzz")
            }
            .help(model.away ? "Back (⇧⌘A)" : "Set away (⇧⌘A)")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Audio and identity settings")
        }
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .lineLimit(1)
            if let pending = model.reconnect {
                ReconnectCountdown(pending: pending)
            }
            Spacer()
            if model.client.status == .connected, let ping = model.client.ping {
                let ms = Int(ping.components.seconds * 1000 + ping.components.attoseconds / 1_000_000_000_000_000)
                Text("\(ms) ms")
                    .monospacedDigit()
                    .foregroundStyle(ms < 100 ? Color.secondary : (ms < 250 ? Color.orange : Color.red))
                    .help("Round-trip time to the server")
            }
            if let me = model.client.ownClient {
                Text("Connected as \(me.nickname)")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var color: Color {
        if model.reconnect != nil { return .yellow }
        switch model.client.status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var text: String {
        switch model.client.status {
        case .connected: model.client.server.name
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        case .failed(let m): "Failed: \(m)"
        }
    }
}

/// Toolbar label whose icon keeps one width, so toggling between symbols of different
/// widths (e.g. `mic.fill` ↔ `mic.slash.fill`) doesn't resize the button and shift the toolbar.
private struct ToolbarToggleLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
        }
    }
}

/// "Reconnecting in 8 s (attempt 3)…", ticking.
private struct ReconnectCountdown: View {
    let pending: AppModel.PendingReconnect

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(pending.at.timeIntervalSince(context.date).rounded(.up)))
            Text(pending.attempt > 1 ? "Reconnecting in \(seconds) s (attempt \(pending.attempt))…" : "Reconnecting in \(seconds) s…")
                .monospacedDigit()
        }
    }
}
