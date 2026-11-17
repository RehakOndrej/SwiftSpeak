import AppKit
import SwiftUI

@main
struct SwiftSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @AppStorage("layout.audioPanel") private var showAudioPanel = true

    init() {
        Storage.migrateFromTS3Client() // before AppModel reads any saved state
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("SwiftSpeak", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 520)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 940, height: 900)
        .commands {
            CommandMenu("Connection") {
                Button("Connect…") { model.showConnectSheet = true }
                    .keyboardShortcut("k")
                Button("Disconnect") { model.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.client.status != .connected && model.client.status != .connecting && model.reconnect == nil)
                Menu("Bookmarks") {
                    ForEach(Array(model.bookmarks.enumerated()), id: \.element.id) { index, bookmark in
                        if index < 9 {
                            Button(bookmark.displayName) { model.connect(bookmark) }
                                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        } else {
                            Button(bookmark.displayName) { model.connect(bookmark) }
                        }
                    }
                    if !model.bookmarks.isEmpty { Divider() }
                    Button("Manage Bookmarks…") { model.showConnectSheet = true }
                }
                Divider()
                Button("Nickname & Away Message…") { model.sheet = .profile }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button(model.micMuted ? "Unmute Microphone" : "Mute Microphone") { model.toggleMic() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button(model.outputMuted ? "Unmute Speakers" : "Mute Speakers") { model.toggleOutput() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button(model.away ? "Back" : "Set Away") { model.toggleAway() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Audio Panel", isOn: $showAudioPanel)
                    .keyboardShortcut("u", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Quitting while connected first disconnects cleanly, so others see "disconnected" instead of a timeout.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.client.status == .connected || model.client.status == .connecting else {
            return .terminateNow
        }
        Task { @MainActor in
            await model.disconnectBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
