import SwiftUI
import TS3Kit

/// Bottom panel: chat history for the active tab, with floating glass tabs and input over it.
struct ChatPanel: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        let ts = model.client
        MessageList(messages: ts.messages[ts.activeChat] ?? [])
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ChatTabs()
                    input
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 6)
            }
    }

    private var input: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .disabled(!canSend)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send")
            }
        }
    }

    private var canSend: Bool {
        let ts = model.client
        guard ts.status == .connected else { return false }
        if case .client(let uid) = ts.activeChat { return ts.client(uid: uid) != nil }
        return true
    }

    private var placeholder: String {
        let ts = model.client
        guard ts.status == .connected else { return "Not connected" }
        switch ts.activeChat {
        case .client(let uid):
            guard let other = ts.client(uid: uid) else { return "They are not on the server" }
            return "Message \(other.nickname)"
        case .channel:
            return "Message \(ts.ownChannel?.name ?? "channel")"
        case .server:
            return "Message everyone on \(ts.server.name)"
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        model.sendChat(text)
        inputFocused = true
    }
}

private struct ChatTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ts = model.client
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ChatTab(title: ts.server.name.isEmpty ? "Server" : ts.server.name, systemImage: "server.rack", target: .server)
                    if ts.status == .connected, let channel = ts.ownChannel {
                        ChatTab(title: channel.name, systemImage: "bubble.left.and.bubble.right", target: .channel)
                    }
                    ForEach(ts.privateChats) { chat in
                        ChatTab(title: chat.nickname, systemImage: chat.clientId == nil ? "person.slash" : "person",
                                target: .client(uid: chat.uid),
                                onClose: { ts.closePrivateChat(uid: chat.uid) })
                    }
                }
                .padding(2)
            }
        }
        .scrollClipDisabled()
    }
}

private struct ChatTab: View {
    @Environment(AppModel.self) private var model
    let title: String
    let systemImage: String
    let target: ChatTarget
    var onClose: (() -> Void)?

    var body: some View {
        let ts = model.client
        let selected = ts.activeChat == target
        let unread = ts.unread[target] ?? 0
        HStack(spacing: 4) {
            Group {
                if selected {
                    Button { ts.activeChat = target } label: { label(unread: unread) }
                        .buttonStyle(.glassProminent)
                } else {
                    Button { ts.activeChat = target } label: { label(unread: unread) }
                        .buttonStyle(.glass)
                }
            }
            .controlSize(.small)
            if selected, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("Close chat")
            }
        }
        .contextMenu {
            if let onClose { Button("Close Chat", action: onClose) }
        }
    }

    private func label(unread: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title).lineLimit(1)
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.bold())
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.red))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct MessageList: View {
    let messages: [ChatMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) {
                if let last = messages.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(line)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var line: AttributedString {
        switch message.kind {
        case .event, .error:
            return ChatStyle.event(message.parts, tone: message.tone)
        case .poke:
            var head = AttributedString("Poke from ")
            head.foregroundColor = ChatStyle.toneColor(.negative)
            var name = ChatStyle.name(message.sender, color: ChatStyle.client)
            name.foregroundColor = ChatStyle.client
            var colon = AttributedString(": ")
            colon.foregroundColor = ChatStyle.toneColor(.negative)
            return head + name + colon + BBCode.render(message.text)
        case .message:
            var body = BBCode.render(message.text)
            guard !message.sender.isEmpty else {
                if message.tone != .neutral { body.foregroundColor = ChatStyle.toneColor(message.tone) }
                return body
            }
            let name = ChatStyle.name(message.sender, color: message.isOwn ? ChatStyle.ownName : ChatStyle.client)
            return name + AttributedString("  ") + body
        }
    }
}

/// Chat and event colours. System colours only, so they adapt to light/dark mode and sit well on glass.
enum ChatStyle {
    static let client = Color.accentColor
    static let ownName = Color.orange
    static let channel = Color.teal
    static let server = Color.purple
    static let group = Color.primary

    static func toneColor(_ tone: ChatMessage.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .positive: .green
        case .negative: .red
        }
    }

    static func name(_ text: String, color: Color) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = color
        a.inlinePresentationIntent = .stronglyEmphasized
        return a
    }

    static func event(_ parts: [EventText.Part], tone: ChatMessage.Tone) -> AttributedString {
        var out = AttributedString()
        for part in parts {
            switch part {
            case .text(let s):
                var a = AttributedString(s)
                a.foregroundColor = toneColor(tone)
                out += a
            case .client(let s): out += name(s, color: client)
            case .channel(let s): out += name(s, color: channel)
            case .server(let s): out += name(s, color: server)
            case .group(let s):
                var a = AttributedString(s)
                a.foregroundColor = group
                a.font = .callout.weight(.medium)
                out += a
            }
        }
        return out
    }
}
