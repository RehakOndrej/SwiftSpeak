import SwiftUI
import TS3Kit

/// Right-hand panel: details of whatever is selected in the tree (your own channel by default).
struct InfoPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            switch effectiveSelection {
            case .server:
                ServerInfoView()
            case .channel(let id):
                if let channel = model.client.channels[id] { ChannelInfoView(channel: channel) }
            case .client(let id):
                if let client = model.client.clients[id] { ClientInfoView(client: client) }
            case nil:
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }

    private var effectiveSelection: TreeSelection? {
        switch model.treeSelection {
        case .channel(let id) where model.client.channels[id] != nil: return .channel(id)
        case .client(let id) where model.client.clients[id] != nil: return .client(id)
        case .server: return .server
        default: return model.client.ownChannel.map { .channel($0.id) } ?? .server
        }
    }
}

/// Big title + optional subtitle used as the first section's header.
private struct Title: View {
    let title: String
    let systemImage: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }
}

private struct RichSection: View {
    let title: String
    let source: String

    var body: some View {
        Section(title) {
            Text(BBCode.render(source))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ServerInfoView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let server = model.client.server
        let online = model.client.clients.values.filter { !$0.isQuery }.count
        Section {
            LabeledContent("Version", value: "\(server.version.split(separator: " ").first ?? "") on \(server.platform)")
            LabeledContent("Clients", value: server.maxClients > 0 ? "\(online) / \(server.maxClients)" : "\(online)")
            LabeledContent("Channels", value: "\(model.client.channels.count)")
            LabeledContent("Voice encryption", value: encryption(server.codecEncryptionMode))
        } header: {
            Title(title: server.name.isEmpty ? "Server" : server.name, systemImage: "server.rack")
        }
        if !server.welcomeMessage.isEmpty { RichSection(title: "Welcome Message", source: server.welcomeMessage) }
        if !server.hostMessage.isEmpty { RichSection(title: "Host Message", source: server.hostMessage) }
    }

    private func encryption(_ mode: Int) -> String {
        switch mode {
        case 1: "Off everywhere"
        case 2: "On everywhere"
        default: "Per channel"
        }
    }
}

private struct ChannelInfoView: View {
    @Environment(AppModel.self) private var model
    let channel: ChannelInfo

    var body: some View {
        let isCurrent = channel.id == model.client.ownClient?.channelId
        let count = model.client.clients(in: channel.id).count
        Section {
            LabeledContent("Audio codec", value: channel.codecName)
            LabeledContent("Codec quality", value: "\(channel.codecQuality)")
            LabeledContent("Properties", value: properties)
            LabeledContent("Clients", value: channel.maxClients < 0 ? "\(count) / Unlimited" : "\(count) / \(channel.maxClients)")
            if channel.neededTalkPower > 0 {
                LabeledContent("Needed talk power", value: "\(channel.neededTalkPower)")
            }
        } header: {
            Title(title: channel.name,
                  systemImage: isCurrent ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right",
                  subtitle: channel.topic)
        } footer: {
            if !isCurrent && !channel.isSpacer && !channel.hasPassword {
                HStack {
                    Spacer()
                    Button("Join Channel") { model.join(channel) }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .task(id: channel.id) { model.client.loadDescription(of: channel.id) }
        if let description = channel.description, !description.isEmpty {
            RichSection(title: "Description", source: description)
        }
    }

    private var properties: String {
        var parts = [channel.isPermanent ? "Permanent" : channel.isSemiPermanent ? "Semi-permanent" : "Temporary"]
        if channel.isDefault { parts.append("Default") }
        if channel.hasPassword { parts.append("Password") }
        if !channel.isUnencrypted { parts.append("Encrypted") }
        return parts.joined(separator: ", ")
    }
}

private struct ClientInfoView: View {
    @Environment(AppModel.self) private var model
    let client: ClientInfo

    var body: some View {
        let ts = model.client
        let isSelf = client.id == ts.ownClientId
        let groups = ts.serverGroups(of: client).map(\.name)
        Section {
            if !groups.isEmpty { LabeledContent("Server groups", value: groups.joined(separator: ", ")) }
            if let group = ts.channelGroups[client.channelGroupId] { LabeledContent("Channel group", value: group.name) }
            LabeledContent("Status", value: status(talking: ts.talking.contains(client.id)))
            if !client.version.isEmpty {
                let version = client.version.split(separator: " ").first.map(String.init) ?? client.version
                LabeledContent("Version", value: client.platform.isEmpty ? version : "\(version) on \(client.platform)")
            }
            if !client.country.isEmpty { LabeledContent("Country", value: client.country) }
            if let since = client.connectedSince {
                LabeledContent("Connected for") { ConnectedDuration(since: since) }
            }
            LabeledContent("Talk power", value: "\(client.talkPower)")
        } header: {
            Title(title: client.nickname, systemImage: "person.fill",
                  subtitle: client.isAway ? "Away" + (client.awayMessage.isEmpty ? "" : " — \(client.awayMessage)") : nil)
        } footer: {
            if !isSelf {
                HStack {
                    Spacer()
                    Button("Send Message") { model.openPrivateChat(with: client) }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        if !client.description.isEmpty {
            RichSection(title: "Description", source: client.description)
        }
        Section("Unique ID") {
            Text(client.uid).font(.callout.monospaced())
        }
        .task(id: client.id) { ts.loadDetails(of: client.id) }
    }

    private func status(talking: Bool) -> String {
        var parts: [String] = []
        if talking { parts.append("Talking") }
        if client.isAway { parts.append("Away") }
        if client.inputMuted { parts.append("Mic muted") } else if !client.inputHardware { parts.append("Mic off") }
        if client.outputMuted { parts.append("Speakers muted") } else if !client.outputHardware { parts.append("Speakers off") }
        if client.isChannelCommander { parts.append("Commander") }
        if client.isRecording { parts.append("Recording") }
        return parts.isEmpty ? "Online" : parts.joined(separator: ", ")
    }
}

/// "1h 3m 22s", ticking every second.
private struct ConnectedDuration: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(Duration.seconds(seconds), format: .units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 3))
                .monospacedDigit()
        }
        .help(since.formatted(date: .abbreviated, time: .shortened))
    }
}
