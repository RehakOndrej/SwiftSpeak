import Foundation
import TS3Kit

// Usage: [TS3_PASSWORD=…] ts3probe <host> [port] [nickname] [channel-id-to-join]
// Connects, prints the channel tree, optionally joins a channel, toggles away, then disconnects.

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: ts3probe <host> [port] [nickname] [channel-id]")
    exit(2)
}
let host = args[1]
let port = args.count > 2 ? UInt16(args[2]) ?? 9987 : 9987
let nickname = args.count > 3 ? args[3] : "TS3Kit-probe"
let joinChannel = args.count > 4 ? UInt64(args[4]) : nil

let identityURL = FileManager.default.temporaryDirectory.appendingPathComponent("ts3probe-identity.json")
let identity: Identity
if let data = try? Data(contentsOf: identityURL), let saved = try? JSONDecoder().decode(Identity.self, from: data) {
    identity = saved
} else {
    identity = Identity.generate(level: 8)
    try? JSONEncoder().encode(identity).write(to: identityURL)
}
print("identity uid=\(identity.uid) level=\(identity.securityLevel)")

var options = ConnectOptions(host: host, port: port, nickname: nickname, identity: identity)
options.serverPassword = ProcessInfo.processInfo.environment["TS3_PASSWORD"] ?? ""
let connection = Connection(options: options)
connection.log = { print("  [conn] \($0)") }
connection.start()

var channels: [(id: UInt64, parent: UInt64, name: String)] = []
var ownId: UInt16 = 0
let deadline = Task {
    try await Task.sleep(for: .seconds(25))
    print("probe timeout, disconnecting")
    connection.disconnect()
}

for await event in connection.events {
    switch event {
    case .connected(let id):
        ownId = id
        print("CONNECTED as client \(id)")
    case .command(let c):
        switch c.name {
        case "channellist":
            for e in c.entries {
                channels.append((e.uint64("cid") ?? 0, e.uint64("cpid") ?? 0, e["channel_name"] ?? "?"))
            }
        case "channellistfinished":
            print("CHANNELS (\(channels.count)):")
            for ch in channels { print("  #\(ch.id) parent=\(ch.parent) \(ch.name)") }
            if let joinChannel {
                connection.send(Command("clientmove", [("clid", String(ownId)), ("cid", String(joinChannel)), ("return_code", "1")]))
            } else {
                connection.send(Command("clientupdate", [("client_away", "1"), ("client_away_message", "probe"), ("return_code", "2")]))
            }
        case "notifycliententerview":
            for e in c.entries { print("  client \(e["clid"] ?? "?") '\(e["client_nickname"] ?? "")' in #\(e["ctid"] ?? "?")") }
        case "notifyclientmoved":
            print("MOVED \(c.first)")
        case "notifyclientupdated":
            print("UPDATED \(c.first)")
        case "error":
            print("ERROR/OK \(c.first)")
            if c.first["return_code"] == "1" {
                connection.send(Command("clientupdate", [("client_away", "1"), ("client_away_message", "probe"), ("return_code", "2")]))
            } else if c.first["return_code"] == "2" {
                connection.disconnect()
            }
        default:
            print("← \(c.name)")
        }
    case .voice:
        break
    case .closed(let error):
        print("CLOSED \(error?.localizedDescription ?? "cleanly")")
    }
}
deadline.cancel()
