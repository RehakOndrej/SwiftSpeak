import Foundation

/// A saved server.
struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16 = 9987
    var nickname: String
    var defaultChannel = ""

    var address: String { port == 9987 ? host : "\(host):\(port)" }
    var displayName: String { name.isEmpty ? address : name }
}

/// How loud one person is for us, remembered by their unique id across sessions and servers.
struct UserAudioPreference: Codable, Equatable, Sendable {
    var volumeDB: Float = 0
    var mutedLocally = false

    var isDefault: Bool { volumeDB == 0 && !mutedLocally }
    var gain: Float { mutedLocally ? 0 : powf(10, volumeDB / 20) }
}

/// Optional system-wide shortcuts for the toolbar toggles.
struct Shortcuts: Codable, Equatable, Sendable {
    var toggleMicrophone: Hotkey?
    var toggleSpeakers: Hotkey?
    var toggleAway: Hotkey?

    enum Action: CaseIterable, Sendable {
        case toggleMicrophone, toggleSpeakers, toggleAway

        var title: String {
            switch self {
            case .toggleMicrophone: "Mute / unmute microphone"
            case .toggleSpeakers: "Mute / unmute speakers"
            case .toggleAway: "Away / back"
            }
        }

        var keyPath: WritableKeyPath<Shortcuts, Hotkey?> {
            switch self {
            case .toggleMicrophone: \.toggleMicrophone
            case .toggleSpeakers: \.toggleSpeakers
            case .toggleAway: \.toggleAway
            }
        }
    }
}

/// Kick, ban and poke, which all ask for a short text first.
enum ModerationAction: Hashable, Sendable {
    case poke, kickFromChannel, kickFromServer, ban

    var title: String {
        switch self {
        case .poke: "Poke"
        case .kickFromChannel: "Kick from Channel"
        case .kickFromServer: "Kick from Server"
        case .ban: "Ban"
        }
    }

    var textLabel: String { self == .poke ? "Message" : "Reason" }
    var isDestructive: Bool { self != .poke }
}

/// Sheets presented over the main window.
enum AppSheet: Identifiable, Hashable {
    case profile
    case moderation(ModerationAction, clientId: UInt16)

    var id: Self { self }
}
