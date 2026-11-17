import SwiftUI
import TS3Kit

/// The server's channel tree with the clients in each channel, flattened into indented rows.
struct ServerTreeView: View {
    @Environment(AppModel.self) private var model
    @State private var passwordPrompt: ChannelInfo?
    @State private var channelPassword = ""

    enum Row: Identifiable, Hashable {
        case server(String)
        case channel(ChannelInfo, depth: Int, expandable: Bool)
        case client(ClientInfo, depth: Int)

        var id: TreeSelection {
            switch self {
            case .server: .server
            case .channel(let c, _, _): .channel(c.id)
            case .client(let c, _): .client(c.id)
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        List(rows, selection: $model.treeSelection) { row in
            rowView(row)
                .tag(row.id)
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: TreeSelection.self) { ids in
            switch ids.first {
            case .channel(let id):
                if let channel = model.client.channels[id], !channel.isSpacer {
                    Button("Join \(channel.name)") { join(channel) }
                        .disabled(channel.id == model.client.ownClient?.channelId)
                }
            case .client(let id):
                if let client = model.client.clients[id], id != model.client.ownClientId {
                    clientMenu(client)
                }
            default:
                EmptyView()
            }
        } primaryAction: { ids in
            switch ids.first {
            case .channel(let id): if let channel = model.client.channels[id] { join(channel) }
            case .client(let id): if let client = model.client.clients[id] { model.openPrivateChat(with: client) }
            default: break
            }
        }
        .alert("Channel password", isPresented: Binding(get: { passwordPrompt != nil }, set: { if !$0 { passwordPrompt = nil } })) {
            SecureField("Password", text: $channelPassword)
            Button("Join") {
                if let channel = passwordPrompt { model.join(channel, password: channelPassword) }
                channelPassword = ""
            }
            Button("Cancel", role: .cancel) { channelPassword = "" }
        } message: {
            Text("\(passwordPrompt?.name ?? "This channel") needs a password.")
        }
    }

    @ViewBuilder private func clientMenu(_ client: ClientInfo) -> some View {
        let muted = model.audioPreference(for: client.uid).mutedLocally
        Button("Send Private Message") { model.openPrivateChat(with: client) }
        Button("Poke…") { model.sheet = .moderation(.poke, clientId: client.id) }
        Divider()
        Button(muted ? "Unmute Locally" : "Mute Locally") { model.toggleLocalMute(for: client.uid) }
        Divider()
        if let ownChannel = model.client.ownChannel, client.channelId != ownChannel.id {
            Button("Move to Your Channel") { model.move(clientId: client.id, to: ownChannel) }
        }
        Button("Kick from Channel…") { model.sheet = .moderation(.kickFromChannel, clientId: client.id) }
        Button("Kick from Server…") { model.sheet = .moderation(.kickFromServer, clientId: client.id) }
        Button("Ban…") { model.sheet = .moderation(.ban, clientId: client.id) }
    }

    /// Drag payload for a client row.
    private static let dragPrefix = "swiftspeak:"

    private func drop(_ items: [String], on channel: ChannelInfo) -> Bool {
        guard !channel.isSpacer,
              let item = items.first, item.hasPrefix(Self.dragPrefix),
              let id = UInt16(item.dropFirst(Self.dragPrefix.count)),
              let client = model.client.clients[id], client.channelId != channel.id else { return false }
        if id == model.client.ownClientId {
            join(channel) // asks for the password if needed
        } else {
            model.move(clientId: id, to: channel)
        }
        return true
    }

    private var rows: [Row] {
        let client = model.client
        var result: [Row] = [.server(client.server.name)]
        func walk(_ parent: UInt64, _ depth: Int) {
            for channel in client.childChannels(of: parent) {
                let members = client.clients(in: channel.id)
                let children = client.childChannels(of: channel.id)
                result.append(.channel(channel, depth: depth, expandable: !members.isEmpty || !children.isEmpty))
                guard !model.collapsedChannels.contains(channel.id) else { continue }
                for member in members {
                    result.append(.client(member, depth: depth + 1))
                }
                walk(channel.id, depth + 1)
            }
        }
        walk(0, 1)
        return result
    }

    private func join(_ channel: ChannelInfo) {
        guard channel.id != model.client.ownClient?.channelId, !channel.isSpacer else { return }
        if channel.hasPassword {
            passwordPrompt = channel
        } else {
            model.join(channel)
        }
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case .server(let name):
            HStack(spacing: 6) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text(name.isEmpty ? "Server" : name).fontWeight(.semibold).lineLimit(1)
            }
        case .channel(let channel, let depth, let expandable):
            HStack(spacing: 2) {
                disclosure(channel.id, visible: expandable)
                ChannelRow(channel: channel, isCurrent: channel.id == model.client.ownClient?.channelId)
            }
            .padding(.leading, CGFloat(depth - 1) * 16)
            .dropDestination(for: String.self) { items, _ in drop(items, on: channel) }
        case .client(let client, let depth):
            ClientRow(client: client,
                      name: model.client.displayName(client),
                      isSelf: client.id == model.client.ownClientId,
                      isTalking: model.client.talking.contains(client.id),
                      mutedLocally: model.audioPreference(for: client.uid).mutedLocally)
                .padding(.leading, CGFloat(depth - 1) * 16 + 14)
                .draggable(Self.dragPrefix + String(client.id)) {
                    Label(client.nickname, systemImage: "person.fill").padding(4)
                }
        }
    }

    private func disclosure(_ id: UInt64, visible: Bool) -> some View {
        let collapsed = model.collapsedChannels.contains(id)
        return Button {
            if collapsed { model.collapsedChannels.remove(id) } else { model.collapsedChannels.insert(id) }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .disabled(!visible)
        .accessibilityLabel(collapsed ? "Expand" : "Collapse")
    }
}

private struct ChannelRow: View {
    let channel: ChannelInfo
    let isCurrent: Bool
    /// `.increased` on a selected (accent-filled) row, where accent-coloured icons would vanish.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let spacer = SpacerName(channel.name) {
            spacer.view
        } else {
            HStack(spacing: 6) {
                Image(systemName: isCurrent ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    .foregroundStyle(iconStyle)
                Text(channel.name)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if channel.hasPassword {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Password protected")
                }
                if channel.isDefault {
                    Image(systemName: "house.fill").foregroundStyle(.secondary).help("Default channel")
                }
                if channel.codec != 4 && channel.codec != 5 {
                    Image(systemName: "waveform.slash").foregroundStyle(.orange).help("Legacy codec, voice not supported")
                }
            }
            .help(channel.topic.isEmpty ? "Double-click to join" : channel.topic)
        }
    }
}

/// TeamSpeak "spacer" channels: names like `[cspacer]Title` or `[*spacer0]---`.
private struct SpacerName {
    enum Alignment { case left, center, right, `repeat` }
    let text: String
    let alignment: Alignment

    init?(_ name: String) {
        guard name.hasPrefix("["), let close = name.firstIndex(of: "]") else { return nil }
        let tag = name[name.index(after: name.startIndex)..<close]
        guard tag.contains("spacer") else { return nil }
        text = String(name[name.index(after: close)...])
        switch tag.first {
        case "c": alignment = .center
        case "r": alignment = .right
        case "*": alignment = .repeat
        default: alignment = .left
        }
    }

    @ViewBuilder var view: some View {
        switch alignment {
        case .repeat:
            Text(String(repeating: text.isEmpty ? "-" : text, count: max(1, 60 / max(text.count, 1))))
                .lineLimit(1)
                .foregroundStyle(.tertiary)
        case .center:
            Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
        case .right:
            Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        case .left:
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct ClientRow: View {
    let client: ClientInfo
    let name: String
    let isSelf: Bool
    let isTalking: Bool
    var mutedLocally = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 16)
            Text(name)
                .fontWeight(isSelf ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 4)
            if client.isChannelCommander {
                Image(systemName: "star.fill").foregroundStyle(.yellow).help("Channel commander")
            }
            if client.isRecording {
                Image(systemName: "record.circle").foregroundStyle(.red).help("Recording")
            }
            if mutedLocally {
                Image(systemName: "speaker.slash").foregroundStyle(.secondary).help("Muted locally (only for you)")
            }
        }
        .help(help)
    }

    private var statusSymbol: String {
        if client.isAway { return "moon.fill" }
        if client.outputMuted { return "speaker.slash.fill" }
        if client.inputMuted { return "mic.slash.fill" }
        if !client.outputHardware { return "speaker.slash" }
        if !client.inputHardware { return "mic.slash" }
        return isTalking ? "circle.fill" : "circle"
    }

    /// Hierarchical styles (not `Color.secondary`) so icons turn light on a selected row;
    /// indigo would disappear into the selection, so it becomes primary there.
    private var statusColor: AnyShapeStyle {
        if client.isAway { return prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.indigo) }
        if client.outputMuted || client.inputMuted { return AnyShapeStyle(Color.red) }
        if isTalking { return AnyShapeStyle(Color.green) }
        return AnyShapeStyle(.secondary)
    }

    private var help: String {
        var parts: [String] = []
        if client.isAway { parts.append("Away" + (client.awayMessage.isEmpty ? "" : ": \(client.awayMessage)")) }
        if client.inputMuted { parts.append("Microphone muted") }
        if client.outputMuted { parts.append("Speakers muted") }
        return parts.isEmpty ? client.nickname : parts.joined(separator: " · ")
    }
}

extension ChannelRow {
    /// Accent for your channel, except on a selected row (accent background) where it would vanish.
    fileprivate var iconStyle: AnyShapeStyle {
        guard isCurrent else { return AnyShapeStyle(.secondary) }
        return prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor)
    }
}
