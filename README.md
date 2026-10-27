<div align="center">

# DeskPilot

**Control your Mac from your iPhone — built for office work, not games.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 27+](https://img.shields.io/badge/macOS-27%2B-black?logo=apple)
![iOS 27+](https://img.shields.io/badge/iOS-27%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-orange?logo=swift)

[Features](#features) · [Status](#status) · [Build from source](#build-from-source) · [Remote access](#remote-access-optional) · [Security](#security-model) · [FAQ](#faq)

English · [繁體中文](translations/README.zh-Hant.md)

</div>

> [!NOTE]
> **There is no download yet.** DeskPilot is a build-it-yourself project: no notarized `.app`, nothing on the App Store or TestFlight. You build both apps in Xcode and sign them with your own Apple ID. Details in [Status](#status).

## Why DeskPilot

Most remote-desktop apps are tuned for video: they keep encoding and sending frames whether or not anything changed. An office desktop is mostly still text. DeskPilot is built around that.

- **No change, no bytes.** If the screen didn't change, nothing is encoded or sent.
- **Never more pixels than your phone can show.** The encode resolution is capped at your iPhone's screen.
- **The finger never waits for the network.** The cursor is drawn on the phone, and pinch-zoom happens on the phone.
- **Chinese input that works.** Text is injected as Unicode, so it never goes through the Mac's input method.

## Features

### Trackpad-style touch control

| Gesture | Action |
|---|---|
| One-finger drag | Move the cursor (with acceleration) |
| Tap / double-tap | Left click / double click |
| Two-finger tap | Right click |
| Two-finger pinch | Zoom 1–6×, on the phone only |
| Two-finger drag | Pan while zoomed, scroll when not |
| Long-press, then drag | Click-and-drag |
| Three-finger drag | Scroll the Mac |
| Four-finger swipe | Mission Control, App Exposé, switch desktops |

Taps and drags give haptic feedback. The four-finger swipes send the standard <kbd>⌃</kbd> shortcuts, so they need those entries to stay enabled in the Mac's Keyboard Shortcuts settings.

### Shortcut bar

Four big buttons — Mission Control, Spotlight, App Switcher, Screenshot — plus a scrolling row of sticky modifiers (<kbd>⇧</kbd> <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>⌘</kbd>), arrows, Esc / Tab / Return, copy and paste.

### Input and clipboard

Zhuyin, Cangjie and other composing IMEs are sent only after you confirm the candidate, so the Mac never receives half-typed phonetic symbols. Copy and paste are explicit buttons rather than background sync, which avoids iOS's "Allow Paste" prompt.

### Resilient connection

Bonjour finds your Mac automatically on the same Wi-Fi. If the link drops, the phone keeps the last frame, reconnects with back-off and re-applies your settings. A data-saver mode (auto / on / off) lowers bitrate on cellular. Multi-display switching and audio are supported.

## Status

| Part | State |
|---|---|
| Same-network (LAN) connection | Tested on real devices |
| Remote access (cellular → tunnel → Mac) | **Not yet tested end to end** |
| Notarized builds / App Store / TestFlight | None |

Numbers in the docs, such as scrolling at about 1 Mbps, come from simulator measurements and the in-app benchmark, not from a controlled lab.

## Build from source

You need a Mac and an iPhone on the deployment targets in the project (macOS 27, iOS 27), a matching Xcode, and an Apple ID. A free Apple ID is enough to build, but **apps signed with it expire after about 7 days** and must be reinstalled. Go is only needed for the optional remote-access feature.

```sh
git clone https://github.com/firstfu/deskpilot.git && cd deskpilot
scripts/build-wireguard-go.sh   # only if you want remote access
open DeskPilot/DeskPilot.xcodeproj
```

1. In Xcode, pick your own Team under Signing for every target. Change the bundle identifiers (`tw.firstfu.*`) if you need to.
2. Set `teamID` in [`DeskPilot/Shared/HelperProtocol.swift`](DeskPilot/Shared/HelperProtocol.swift) to your Team ID. The privileged helper only accepts a host app signed by the same team; without this, remote access can't reach the helper.
3. Build **DeskPilotHost** for the Mac and **DeskPilot** for the iPhone.
   Keep the Mac build in Xcode's default DerivedData, not a temp folder like `/private/tmp`, or Screen Recording permission won't stick.
4. On the Mac, grant **Screen & System Audio Recording** and **Accessibility** in System Settings → Privacy & Security, then restart the host app.

### Connect on the same network

1. Open the host app on the Mac and DeskPilot on the iPhone. The Mac appears automatically.
2. The first time, confirm the 6-digit code on the Mac and click Allow. After that, a key in the Keychain authenticates automatically, and the phone asks for Face ID before each connection.

## Remote access (optional)

Away from home, DeskPilot connects through a WireGuard tunnel with the Mac as the server. Everything is built into the Mac app:

1. In the menu bar, turn on **External access (auto port mapping)**. Your router needs NAT-PMP or UPnP, otherwise forward UDP 51820 yourself.
2. Click **Install tunnel components…** and approve it once in System Settings → Login Items.
3. Click **Pair phone (external)…** to show a QR code, and scan it with the **official WireGuard app** on the iPhone.
4. On the phone, turn off Wi-Fi, enable the tunnel, choose "Outside" in DeskPilot and enter `10.66.0.1`.

Pair while you're next to the Mac. The QR code contains your current public IP, so regenerate it if the IP changes. It won't work behind carrier-grade NAT (CGNAT).

## Security model

- Every connection is encrypted and requires pairing ([protocol notes](docs/context/reference/modules/protocol.md)).
- The tunnel exposes WireGuard only. The host accepts private-range sources only, and DeskPilot itself is never exposed to the public internet.
- The privileged helper runs as root but offers a fixed set of methods: no paths, command strings or config files. Callers are checked by code signature. The phone's private key lives only in the QR code; the Mac doesn't keep it.
- Face ID (or passcode) is required before each connection, so a lost phone doesn't hand over your Mac.

> [!WARNING]
> Free Apple Development certificates aren't notarized, so signature checks are weaker than with Developer ID. For now this is suitable for personal use only.

## FAQ

<details>
<summary><b>The screen is black after connecting</b></summary>

Check that Screen & System Audio Recording is granted to the host app and that you restarted it afterwards. Also make sure the host app was built into Xcode's default DerivedData and not a temp folder.
</details>

<details>
<summary><b>The iPhone app stopped opening after a week</b></summary>

Apps signed with a free Apple ID expire after about 7 days. Rebuild and reinstall, or use a paid developer account.
</details>

<details>
<summary><b>Four-finger swipes do nothing</b></summary>

They send <kbd>⌃</kbd>-arrow shortcuts. In System Settings → Keyboard → Keyboard Shortcuts, keep the Mission Control and Spaces entries enabled.
</details>

<details>
<summary><b>Remote access can't connect</b></summary>

Check that your router supports NAT-PMP or UPnP (or forward UDP 51820), that you're not behind CGNAT, and that the QR code was generated with your current public IP. Remember that this path hasn't been verified end to end yet.
</details>

## Project layout

| Path | Contents |
|---|---|
| `DeskPilot/DeskPilot/` | iPhone app: display, gestures, Chinese input |
| `DeskPilot/DeskPilotHost/` | Mac host: capture, encoding, input injection, remote-access control |
| `DeskPilot/DeskPilotHelper/` | Privileged helper (root LaunchDaemon) that starts and stops WireGuard |
| `DeskPilot/Shared/` | Protocol and crypto shared by both sides |
| `docs/context/` | Architecture, protocol, operations and pitfalls — start at [`overview.md`](docs/context/reference/overview.md) |

## Contributing

Built by one person; issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). The most useful reports include your macOS and iOS versions, whether you're on LAN or remote access, and what the screen showed.

## Third-party components

Remote access uses [wireguard-go](https://git.zx2c4.com/wireguard-go) (MIT), compiled from pinned upstream source. `wireguard-tools` is deliberately not bundled, to avoid GPL obligations.

## License

[MIT](LICENSE).
