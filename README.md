# TS3 Client

A personal macOS (27+) TeamSpeak 3 client in SwiftUI, implemented from the protocol notes in
[ReSpeak/tsdeclarations](https://github.com/ReSpeak/tsdeclarations) (`ts3protocol.md`, `Messages.toml`, `Book.toml`).

**Features:** connect · channel tree with `[Group]` tags · channel/client/server info panel · server, channel and private chat tabs · join channel · capture settings (push to talk with any key/mouse button, voice activation, noise removal, typing attenuation, echo cancellation, ducking) · playback settings (voice and sound volume, voice leveling, mic clicks, comfort noise) · away (mutes the mic) with away message / mic mute / speaker mute · bookmarks (⌘1–⌘9) · auto-reconnect to the last channel · notifications and Dock badge for private messages and pokes · per-user volume and local mute · global shortcuts · nickname change · ping · poke, move (drag and drop), kick and ban · Opus voice.

## Build and run

```sh
xcodegen generate                       # after changing project.yml
xcodebuild -project TS3Client.xcodeproj -scheme TS3Client -derivedDataPath build build
open "build/Build/Products/Debug/TS3 Client.app"
```

Or open `TS3Client.xcodeproj` in Xcode and press ⌘R.

Protocol tests and the CLI probe live in the Swift package:

```sh
cd Packages/TS3Kit
swift test
TS3_PASSWORD='…' swift run ts3probe <host> <port> [nickname] [channel-id]
```

## Layout

| Path | What |
|---|---|
| `Packages/TS3Kit/Sources/TS3Kit/Crypto` | EAX (AES-CTR + CMAC via CommonCrypto), P-256 identity + hashcash, license chain, RSA puzzle |
| `Packages/TS3Kit/Sources/TS3Kit/Protocol` | Packet format, QuickLZ decompression, command escaping/parsing, `Connection` (handshake, acks, resend, ordering, ping) |
| `Packages/TS3Kit/Sources/TS3Kit/Client` | `TS3Client`: observable channels/clients, join, mute, away |
| `Packages/TS3Kit/Sources/TS3Audio` | Core Audio device list, Opus encode/decode, `VoiceEngine` (capture, voice activation, jitter buffer, mixer) |
| `Packages/TS3Kit/Sources/CEd25519` | ref10 Ed25519 group ops from orlp/ed25519 (zlib licence) |
| `App/Sources` | SwiftUI app |

## Notes and limits

- Only servers ≥ 3.1 (the `initivexpand2` handshake). Tested against TeamSpeak 3.13.8.
- The client presents itself with a known TeamSpeak-signed version triple (`Versions.csv`), as every
  third-party client does. Fine for personal use; don't distribute it.
- Voice is Opus only. Channels using Speex/CELT are shown with a warning, and you can't talk in them.
- Push to talk defaults to holding ⌥ Option; set any key, modifier combination or extra mouse button in Settings → Capture. Keyboard hotkeys work while the app is in the background only with Accessibility access.
- Background-noise removal is a built-in spectral suppressor (`TS3Audio/NoiseSuppressor.swift`). Echo cancellation uses Apple voice processing, which plays through the system default output device.
- Identity and server passwords are kept in `~/Library/Application Support/TS3 Client/secrets.json` (mode 0600), not the Keychain: an ad-hoc signed build changes signature on every rebuild, which made macOS ask for the keychain password each time. Older Keychain entries are migrated once. The identity is generated at hashcash level 8.
- Protocol reference: ReSpeak's `tsclientlib` (MIT/Apache). QuickLZ decompression is ported from its `quicklz` crate.
