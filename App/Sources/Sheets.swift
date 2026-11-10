import SwiftUI
import TS3Kit

/// Nickname and away message.
struct ProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var awayMessage = ""

    var body: some View {
        Form {
            Section {
                TextField("Nickname", text: $nickname)
                TextField("Away message", text: $awayMessage, prompt: Text("optional, shown while you are away"))
            } footer: {
                if model.client.status != .connected {
                    Text("The nickname is used the next time you connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.updateProfile(nickname: nickname, awayMessage: awayMessage)
                    dismiss()
                }
                .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            nickname = model.client.ownClient?.nickname ?? Storage.lastServer.nickname
            awayMessage = model.awayMessage
        }
    }
}

/// Poke, kick or ban someone, after typing a message or reason.
struct ModerationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let action: ModerationAction
    let clientId: UInt16
    @State private var text = ""
    @State private var banDuration = BanDuration.oneHour

    enum BanDuration: CaseIterable, Identifiable {
        case tenMinutes, oneHour, oneDay, oneWeek, permanent
        var id: Self { self }
        var title: String {
            switch self {
            case .tenMinutes: "10 minutes"
            case .oneHour: "1 hour"
            case .oneDay: "1 day"
            case .oneWeek: "1 week"
            case .permanent: "Permanently"
            }
        }
        var duration: Duration? {
            switch self {
            case .tenMinutes: .seconds(600)
            case .oneHour: .seconds(3_600)
            case .oneDay: .seconds(86_400)
            case .oneWeek: .seconds(604_800)
            case .permanent: nil
            }
        }
    }

    var body: some View {
        let name = model.client.clients[clientId]?.nickname ?? "this user"
        Form {
            Section {
                TextField(action.textLabel, text: $text, prompt: Text(action == .poke ? "Hey!" : "optional"))
                if action == .ban {
                    Picker("Duration", selection: $banDuration) {
                        ForEach(BanDuration.allCases) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("\(action.title): \(name)")
                    .font(.headline)
                    .textCase(nil)
            } footer: {
                if action.isDestructive {
                    Text("The server decides whether you have permission; if not, the error appears in the server tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    model.perform(action, on: clientId, text: text.trimmingCharacters(in: .whitespaces),
                                  banDuration: banDuration.duration)
                    dismiss()
                }
                .disabled(action == .poke && text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onChange(of: model.client.clients[clientId] == nil) { _, gone in
            if gone { dismiss() } // they left meanwhile
        }
    }
}
