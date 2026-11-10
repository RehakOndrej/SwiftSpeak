import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var defaultChannel = ""

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $address, prompt: Text("host or host:port"))
                TextField("Nickname", text: $nickname)
                SecureField("Server password", text: $password, prompt: Text("optional"))
                TextField("Default channel", text: $defaultChannel, prompt: Text("optional, e.g. Lobby/Games or /12"))
            } footer: {
                Text("The password is stored in your Keychain for this server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
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

    private var parsed: (host: String, port: UInt16)? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // host:port, but leave bare IPv6 addresses alone.
        if let colon = trimmed.lastIndex(of: ":"), trimmed.filter({ $0 == ":" }).count == 1 {
            guard let port = UInt16(trimmed[trimmed.index(after: colon)...]) else { return nil }
            return (String(trimmed[..<colon]), port)
        }
        return (trimmed, 9987)
    }

    private func load() {
        let last = Storage.lastServer
        if !last.host.isEmpty {
            address = last.port == 9987 ? last.host : "\(last.host):\(last.port)"
            password = Storage.serverPassword(host: last.host, port: last.port)
        }
        nickname = last.nickname
        defaultChannel = last.defaultChannel
    }

    private func connect() {
        guard let p = parsed else { return }
        model.connect(host: p.host, port: p.port, nickname: nickname.trimmingCharacters(in: .whitespaces),
                      password: password, defaultChannel: defaultChannel)
        dismiss()
    }
}
