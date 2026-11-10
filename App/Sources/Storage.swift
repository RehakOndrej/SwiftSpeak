import Foundation
import Security
import TS3Audio
import TS3Kit

/// Identity and server passwords live in a private file (`0600`, in a `0700` folder) under
/// Application Support; everything else in UserDefaults.
///
/// Not the Keychain: login-keychain items are tied to the app's code signature, and an ad-hoc
/// signed build gets a new one on every rebuild, so macOS asked for the keychain password each time.
/// The official TeamSpeak client also keeps its identity in a local file.
@MainActor
enum Storage {
    private struct Secrets: Codable {
        var identity: Identity?
        /// Keyed by "host:port".
        var serverPasswords: [String: String] = [:]
    }

    private static let directory = URL.applicationSupportDirectory.appending(path: "TS3 Client", directoryHint: .isDirectory)
    private static let secretsURL = directory.appending(path: "secrets.json")

    private static var secrets: Secrets = loadSecrets()

    static func loadIdentity() -> Identity? { secrets.identity }

    static func saveIdentity(_ identity: Identity) {
        secrets.identity = identity
        saveSecrets()
    }

    static func serverPassword(host: String, port: UInt16) -> String {
        secrets.serverPasswords["\(host):\(port)"] ?? ""
    }

    static func setServerPassword(_ password: String, host: String, port: UInt16) {
        let key = "\(host):\(port)"
        guard secrets.serverPasswords[key] ?? "" != password else { return }
        secrets.serverPasswords[key] = password.isEmpty ? nil : password
        saveSecrets()
    }

    // MARK: Secrets file

    private static func loadSecrets() -> Secrets {
        if let data = try? Data(contentsOf: secretsURL),
           let saved = try? JSONDecoder().decode(Secrets.self, from: data) {
            return saved
        }
        // First run with file storage: bring over what earlier versions kept in the Keychain.
        let migrated = LegacyKeychain.takeAll()
        let secrets = Secrets(identity: migrated.identity, serverPasswords: migrated.passwords)
        if secrets.identity != nil || !secrets.serverPasswords.isEmpty, write(secrets) {
            LegacyKeychain.deleteAll()
        }
        return secrets
    }

    private static func saveSecrets() { write(secrets) }

    /// Returns false when the file could not be written.
    @discardableResult
    private static func write(_ secrets: Secrets) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(secrets)
            try data.write(to: secretsURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsURL.path(percentEncoded: false))
            return true
        } catch {
            NSLog("TS3 Client: could not save secrets: \(error)")
            return false
        }
    }

    // MARK: Defaults

    static var audioSettings: AudioSettings {
        get {
            UserDefaults.standard.data(forKey: "audioSettings")
                .flatMap { try? JSONDecoder().decode(AudioSettings.self, from: $0) } ?? AudioSettings()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "audioSettings") }
    }

    static var pushToTalkHotkey: Hotkey {
        get {
            UserDefaults.standard.data(forKey: "pushToTalkHotkey")
                .flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .default
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "pushToTalkHotkey") }
    }

    struct LastServer: Codable {
        var host = ""
        var port: UInt16 = 9987
        var nickname = NSFullUserName().components(separatedBy: " ").first ?? "Guest"
        var defaultChannel = ""
    }

    static var lastServer: LastServer {
        get {
            UserDefaults.standard.data(forKey: "lastServer")
                .flatMap { try? JSONDecoder().decode(LastServer.self, from: $0) } ?? LastServer()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "lastServer") }
    }
}

/// Reads and removes the Keychain items written by earlier versions (one-time migration).
private enum LegacyKeychain {
    static let service = "dev.personal.ts3-client"

    static func takeAll() -> (identity: Identity?, passwords: [String: String]) {
        var identity: Identity?
        var passwords: [String: String] = [:]
        for account in accounts() {
            guard let data = data(account) else { continue }
            if account == "identity" {
                identity = try? JSONDecoder().decode(Identity.self, from: data)
            } else if account.hasPrefix("server:"), let password = String(data: data, encoding: .utf8), !password.isEmpty {
                passwords[String(account.dropFirst("server:".count))] = password
            }
        }
        return (identity, passwords)
    }

    static func deleteAll() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }

    /// Account names only; reading attributes does not need the item's access prompt.
    private static func accounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func data(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
