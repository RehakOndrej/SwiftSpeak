# SwiftSpeak

An unofficial native macOS (27+) TeamSpeak 3 client written in SwiftUI, implemented from the protocol notes in
[ReSpeak/tsdeclarations](https://github.com/ReSpeak/tsdeclarations) (`ts3protocol.md`, `Messages.toml`, `Book.toml`).

**Features:** connect · channel tree with `[Group]` tags · channel/client/server info panel · server, channel and private chat tabs · join channel · capture settings (push to talk with any key/mouse button, voice activation, noise removal, typing attenuation, echo cancellation, ducking) · playback settings (voice and sound volume, voice leveling, mic clicks, comfort noise) · away (mutes the mic) with away message / mic mute / speaker mute · bookmarks (⌘1–⌘9) · auto-reconnect to the last channel · notifications and Dock badge for private messages and pokes · per-user volume and local mute · global shortcuts · nickname change · ping · poke, move (drag and drop), kick and ban · Opus voice.

## Build and run

```sh
xcodegen generate                       # after changing project.yml
xcodebuild -project SwiftSpeak.xcodeproj -scheme SwiftSpeak -derivedDataPath build build
open build/Build/Products/Debug/SwiftSpeak.app
```

Requires Xcode with the macOS 27 SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
Or open `SwiftSpeak.xcodeproj` in Xcode and press ⌘R.

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
| `Packages/TS3Kit/Sources/TS3Kit/Client` | `TS3Client` (the protocol client object): observable channels/clients, join, mute, away |
| `Packages/TS3Kit/Sources/TS3Audio` | Core Audio device list, Opus encode/decode, `VoiceEngine` (capture, voice activation, jitter buffer, mixer) |
| `Packages/TS3Kit/Sources/CEd25519` | ref10 Ed25519 group ops from orlp/ed25519 (zlib licence) |
| `App/Sources` | SwiftUI app (SwiftSpeak) |

## Notes and limits

- Only servers ≥ 3.1 (the `initivexpand2` handshake). Tested against TeamSpeak 3.13.8.
- The client presents itself with a known TeamSpeak-signed version triple (`Versions.csv`), as every
  third-party client does.
- Voice is Opus only. Channels using Speex/CELT are shown with a warning, and you can't talk in them.
- Push to talk defaults to holding ⌥ Option; set any key, modifier combination or extra mouse button in Settings → Capture. Keyboard hotkeys work while the app is in the background only with Accessibility access. macOS ties that access to the app's signature, and an ad-hoc signed build gets a new one on every rebuild: the switch in System Settings stays on but hotkeys stop working in other apps. Run `Scripts/make-signing-certificate.sh` once to sign builds with a certificate of your own (kept in your login keychain), then grant access one more time.
- Sound pack: a default voice pack (15 clips, trimmed and loudness-matched) ships in `App/Resources/Sounds`. To override or add sounds, put files named after the events (`connected.mp3`, `user_switched_tocurrentchannel.wav`, …) in `~/Library/Application Support/SwiftSpeak/Sounds` (Settings → Playback → Open Sounds Folder lists the names). Missing ones are silent.
- Background-noise removal is a built-in spectral suppressor (`TS3Audio/NoiseSuppressor.swift`). Echo cancellation uses Apple voice processing, which plays through the system default output device.
- Identity and server passwords are kept in `~/Library/Application Support/SwiftSpeak/secrets.json` (mode 0600), not the Keychain: an ad-hoc signed build changes signature on every rebuild, which made macOS ask for the keychain password each time. Older Keychain entries are migrated once. The identity is generated at hashcash level 8.
- Protocol reference: ReSpeak's `tsclientlib` (MIT/Apache). QuickLZ decompression is ported from its `quicklz` crate.
- Renamed from "TS3 Client": on first launch SwiftSpeak copies `~/Library/Application Support/TS3 Client` to `…/SwiftSpeak` and copies the old preferences (`dev.personal.ts3-client`). The bundle id changed, so Accessibility and microphone access must be granted again.

## Status and license

Here is the code; do whatever you want with it. SwiftSpeak is source only: there are no binaries or
releases, and it is provided as-is, without warranty or support. Build it yourself (see above).

SwiftSpeak is an unofficial client. It is not affiliated with, endorsed by or supported by TeamSpeak
Systems GmbH. TeamSpeak is a trademark of its owner.

Licensed under the [MIT License](LICENSE). Third-party parts keep their own licenses:

- Ed25519 group operations from [orlp/ed25519](https://github.com/orlp/ed25519): zlib
  (`Packages/TS3Kit/Sources/CEd25519/LICENSE-ed25519.txt`)
- QuickLZ decompression ported from [ReSpeak/quicklz](https://github.com/ReSpeak/quicklz): MIT
  (`Packages/TS3Kit/Sources/TS3Kit/Protocol/LICENSE-quicklz.txt`)
- Swift package dependencies: [BigInt](https://github.com/attaswift/BigInt) (MIT),
  [swift-opus](https://github.com/alta/swift-opus) (BSD-3-Clause, bundles libopus)
- Notification voice clips in `App/Resources/Sounds`: generated with [ElevenLabs](https://elevenlabs.io)
  (paid plan).
