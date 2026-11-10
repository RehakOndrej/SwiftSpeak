import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var defaultChannel = ""
    @State private var saveAsBookmark = false
    /// The bookmark the fields came from, so saving updates it instead of adding a copy.
    @State private var editing: Bookmark.ID?

    var body: some View {
        Form {
            if !model.bookmarks.isEmpty {
                Section("Bookmarks") {
                    ForEach(model.bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark, isSelected: bookmark.id == editing)
                            .contentShape(Rectangle())
                            .onTapGesture { fill(from: bookmark) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                model.connect(bookmark)
                                dismiss()
                            })
                            .contextMenu {
                                Button("Connect") { model.connect(bookmark); dismiss() }
                                Button("Delete Bookmark", role: .destructive) { delete(bookmark) }
                            }
                    }
                }
            }

            Section {
                TextField("Address", text: $address, prompt: Text("host or host:port"))
                TextField("Nickname", text: $nickname)
                SecureField("Server password", text: $password, prompt: Text("optional"))
                TextField("Default channel", text: $defaultChannel, prompt: Text("optional, e.g. Lobby/Games or /12"))
            } footer: {
                Text("Passwords are stored only on this Mac, readable by your user account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(editing == nil ? "Save as bookmark" : "Update bookmark", isOn: $saveAsBookmark)
                if saveAsBookmark {
                    TextField("Bookmark name", text: $name, prompt: Text(parsed?.host ?? "optional"))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect") { connect() }
                    .disabled(parsed == nil || nickname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
        .onChange(of: address) {
            if let p = parsed, password.isEmpty {
                password = Storage.serverPassword(host: p.host, port: p.port)
            }
        }
    }

    /// "host", "host:port", "[ipv6]:port" or a bare IPv6 address.
    private var parsed: (host: String, port: UInt16)? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return host.isEmpty ? nil : (host, 9987) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), !host.isEmpty else { return nil }
            return (host, port)
        }
        if let colon = trimmed.lastIndex(of: ":"), trimmed.filter({ $0 == ":" }).count == 1 {
            guard let port = UInt16(trimmed[trimmed.index(after: colon)...]) else { return nil }
            return (String(trimmed[..<colon]), port)
        }
        return (trimmed, 9987)
    }

    private func load() {
        let last = Storage.lastServer
        if let bookmark = model.bookmarks.first(where: { $0.host == last.host && $0.port == last.port }) {
            fill(from: bookmark)
            return
        }
        if !last.host.isEmpty {
            address = last.port == 9987 ? last.host : "\(last.host):\(last.port)"
            password = Storage.serverPassword(host: last.host, port: last.port)
        }
        nickname = last.nickname
        defaultChannel = last.defaultChannel
    }

    private func fill(from bookmark: Bookmark) {
        editing = bookmark.id
        name = bookmark.name
        address = bookmark.address
        nickname = bookmark.nickname
        defaultChannel = bookmark.defaultChannel
        password = Storage.serverPassword(host: bookmark.host, port: bookmark.port)
        saveAsBookmark = false
    }

    private func delete(_ bookmark: Bookmark) {
        model.deleteBookmark(bookmark)
        if editing == bookmark.id { editing = nil }
    }

    private func connect() {
        guard let p = parsed else { return }
        let nick = nickname.trimmingCharacters(in: .whitespaces)
        if saveAsBookmark {
            var bookmark = Bookmark(name: name.trimmingCharacters(in: .whitespaces), host: p.host, port: p.port,
                                    nickname: nick, defaultChannel: defaultChannel)
            if let editing { bookmark.id = editing }
            model.saveBookmark(bookmark, password: password)
        }
        model.connect(host: p.host, port: p.port, nickname: nick, password: password, defaultChannel: defaultChannel)
        dismiss()
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: "server.rack")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.displayName).fontWeight(isSelected ? .semibold : .regular)
                Text("\(bookmark.nickname) @ \(bookmark.address)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .help("Click to fill in, double-click to connect")
    }
}
