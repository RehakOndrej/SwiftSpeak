import AppKit
import TS3Kit
import UserNotifications

/// macOS notifications and the Dock badge for private messages and pokes that arrive while the app is in the background.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Clicking a notification opens that chat tab.
    var onOpen: ((ChatTarget) -> Void)?

    private var badgeCount = 0
    private var askedForPermission = false
    private var activationObserver: Any?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearBadge() }
        }
    }

    /// Notifies only when the app isn't in front; in front, the chat tab's unread count is enough.
    func notify(_ message: ChatMessage, target: ChatTarget) {
        guard !NSApp.isActive else { return }
        switch (message.kind, target) {
        case (.poke, _), (.message, .client): break
        default: return // channel and server chat would be too noisy
        }
        badgeCount += 1
        NSApp.dockTile.badgeLabel = String(badgeCount)
        if message.kind == .poke { NSApp.requestUserAttention(.informationalRequest) }

        let content = UNMutableNotificationContent()
        content.title = message.kind == .poke ? "\(message.sender) poked you" : message.sender
        content.body = Self.plainText(message.text)
        content.sound = .default
        content.userInfo = ["target": Self.encode(target)]
        let request = UNNotificationRequest(identifier: message.id.uuidString, content: content, trigger: nil)

        Task {
            let center = UNUserNotificationCenter.current()
            if !askedForPermission {
                askedForPermission = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            try? await center.add(request)
        }
    }

    func clearBadge() {
        badgeCount = 0
        NSApp.dockTile.badgeLabel = nil
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo["target"] as? String
        await MainActor.run {
            NSApp.activate()
            if let key, let target = Self.decode(key) { self.onOpen?(target) }
        }
    }

    // MARK: - Helpers

    private static func encode(_ target: ChatTarget) -> String {
        switch target {
        case .server: "server"
        case .channel: "channel"
        case .client(let uid): "client:" + uid
        }
    }

    private static func decode(_ key: String) -> ChatTarget? {
        switch key {
        case "server": .server
        case "channel": .channel
        default: key.hasPrefix("client:") ? .client(uid: String(key.dropFirst(7))) : nil
        }
    }

    /// Notifications can't render BBCode; drop the tags.
    private static func plainText(_ bbcode: String) -> String {
        bbcode.replacing(#/\[\/?[a-zA-Z*]+(=[^\]]*)?\]/#, with: "")
    }
}
