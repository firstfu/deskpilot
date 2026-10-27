<div align="center">

# DeskPilot

**Control your Mac from your iPhone — engineered for office work, not games.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 27+](https://img.shields.io/badge/macOS-27%2B-black?logo=apple)
![iOS 27+](https://img.shields.io/badge/iOS-27%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-orange?logo=swift)

[Features](#features) · [Status](#status) · [Build from source](#build-from-source) · [Remote access](#remote-access-optional) · [Security](#security-model) · [FAQ](#faq)

English · [繁體中文](translations/README.zh-Hant.md)

</div>

> [!NOTE]
> **No prebuilt binaries are available.** DeskPilot is distributed as source only: there is no notarized `.app`, and no App Store or TestFlight release. You build both apps in Xcode and sign them with your own Apple ID. See [Status](#status).

## Overview

Conventional remote-desktop software is optimized for video and continues to encode and transmit frames regardless of whether the display has changed. An office desktop, by contrast, is mostly static text. DeskPilot is designed around that workload:

- **Change-driven transmission.** When the screen is unchanged, nothing is encoded or sent.
- **Resolution bounded by the client.** The encode resolution never exceeds the iPhone's display.
- **Latency-independent interaction.** The cursor is rendered locally on the phone, and pinch-zoom is performed locally, so touch response does not wait on the network.
- **Reliable Chinese input.** Text is injected as Unicode and bypasses the Mac's input method entirely.

## Features

### Trackpad-style touch control

| Gesture | Action |
|---|---|
| One-finger drag | Move the cursor (with pointer acceleration) |
| Tap / double-tap | Left click / double click |
| Two-finger tap | Right click |
| Two-finger pinch | Zoom 1–6×, applied on the phone only |
| Two-finger drag | Pan when zoomed; scroll otherwise |
| Long-press, then drag | Click and drag |
| Three-finger drag | Scroll on the Mac |
| Four-finger swipe | Mission Control, App Exposé, switch desktops |

Taps and drags provide haptic feedback. Four-finger swipes send the standard <kbd>⌃</kbd> shortcuts, so the corresponding entries must remain enabled under Keyboard Shortcuts in macOS System Settings.

### Shortcut bar

Four primary buttons (Mission Control, Spotlight, App Switcher, Screenshot) sit above a scrollable row containing sticky modifiers (<kbd>⇧</kbd> <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>⌘</kbd>), arrow keys, Esc / Tab / Return, and copy / paste.

### Text input and clipboard

Composing input methods such as Zhuyin and Cangjie transmit text only after the candidate is confirmed, so the Mac never receives partially composed phonetic symbols. Copy and paste are explicit actions rather than background clipboard synchronization, which avoids the iOS "Allow Paste" prompt.

### Connection resilience

On the same Wi-Fi network, Bonjour discovers the Mac automatically. If the connection drops, the phone retains the last received frame, reconnects with exponential back-off, and reapplies your settings. A data-saver mode (auto / on / off) reduces bitrate on cellular networks. Multi-display switching and audio are supported.

## Status

| Component | State |
|---|---|
| Same-network (LAN) connection | Verified on physical devices |
| Remote access (cellular → tunnel → Mac) | **Not yet verified end to end** |
| Notarized builds / App Store / TestFlight | Not available |

Figures cited in the documentation, such as roughly 1 Mbps while scrolling, come from simulator measurements and the in-app benchmark. They were not obtained under controlled laboratory conditions.

## Build from source

**Requirements:** a Mac and an iPhone meeting the project's deployment targets (macOS 27, iOS 27), a matching version of Xcode, and an Apple ID. A free Apple ID is sufficient to build, but **apps signed with it expire after approximately 7 days** and must be reinstalled. Go is required only for the optional remote-access feature.

```sh
git clone https://github.com/firstfu/deskpilot.git && cd deskpilot
scripts/build-wireguard-go.sh   # only if you want remote access
open DeskPilot/DeskPilot.xcodeproj
```

1. In Xcode, select your own Team under Signing for every target. Change the bundle identifiers (`tw.firstfu.*`) if necessary.
2. Set `teamID` in [`DeskPilot/Shared/HelperProtocol.swift`](DeskPilot/Shared/HelperProtocol.swift) to your Team ID. The privileged helper accepts only a host app signed by the same team; without this change, remote access cannot reach the helper.
3. Build **DeskPilotHost** for the Mac and **DeskPilot** for the iPhone.
   Keep the Mac build in Xcode's default DerivedData rather than a temporary location such as `/private/tmp`; otherwise the Screen Recording permission will not persist.
4. On the Mac, grant **Screen & System Audio Recording** and **Accessibility** under System Settings → Privacy & Security, then restart the host app.

### Connect on the same network

1. Launch the host app on the Mac and DeskPilot on the iPhone. The Mac is discovered automatically.
2. On first connection, confirm the 6-digit code on the Mac and click Allow. Subsequent connections authenticate automatically with a key stored in the Keychain, and the phone requires Face ID before each connection.

## Remote access (optional)

Outside your home network, DeskPilot connects through a WireGuard tunnel with the Mac acting as the server. All required components are built into the Mac app:

1. In the menu bar, enable **External access (auto port mapping)**. Your router must support NAT-PMP or UPnP; otherwise, forward UDP 51820 manually.
2. Select **Install tunnel components…** and approve the request once under System Settings → Login Items.
3. Select **Pair phone (external)…** to display a QR code, then scan it with the **official WireGuard app** on the iPhone.
4. On the phone, turn off Wi-Fi, enable the tunnel, choose "Outside" in DeskPilot, and enter `10.66.0.1`.

Pair while you are physically near the Mac. The QR code embeds your current public IP address and must be regenerated if that address changes. Remote access does not work behind carrier-grade NAT (CGNAT).

## Security model

- Every connection is encrypted and requires pairing. See the [protocol notes](docs/context/reference/modules/protocol.md).
- The tunnel exposes WireGuard only. The host accepts connections from private address ranges exclusively, and DeskPilot itself is never exposed to the public internet.
- The privileged helper runs as root but exposes a fixed set of methods and accepts no paths, command strings, or configuration files. Callers are verified by code signature. The phone's private key exists only in the QR code and is not retained by the Mac.
- Face ID (or the device passcode) is required before each connection, so a lost phone does not grant access to your Mac.

> [!WARNING]
> Free Apple Development certificates are not notarized, so signature verification is weaker than with Developer ID. At present, DeskPilot is suitable for personal use only.

## FAQ

<details>
<summary><b>The screen is black after connecting</b></summary>

Verify that Screen & System Audio Recording is granted to the host app and that the app was restarted afterwards. Also confirm that the host app was built into Xcode's default DerivedData rather than a temporary folder.
</details>

<details>
<summary><b>The iPhone app stopped opening after a week</b></summary>

Apps signed with a free Apple ID expire after approximately 7 days. Rebuild and reinstall the app, or use a paid developer account.
</details>

<details>
<summary><b>Four-finger swipes have no effect</b></summary>

These gestures send <kbd>⌃</kbd>-arrow shortcuts. In System Settings → Keyboard → Keyboard Shortcuts, keep the Mission Control and Spaces entries enabled.
</details>

<details>
<summary><b>Remote access cannot connect</b></summary>

Confirm that your router supports NAT-PMP or UPnP (or that UDP 51820 is forwarded), that you are not behind CGNAT, and that the QR code was generated with your current public IP address. Note that this path has not yet been verified end to end.
</details>

## Project layout

| Path | Contents |
|---|---|
| `DeskPilot/DeskPilot/` | iPhone app: display, gestures, Chinese input |
| `DeskPilot/DeskPilotHost/` | Mac host: capture, encoding, input injection, remote-access control |
| `DeskPilot/DeskPilotHelper/` | Privileged helper (root LaunchDaemon) that starts and stops WireGuard |
| `DeskPilot/Shared/` | Protocol and cryptography shared by both sides |
| `docs/context/` | Architecture, protocol, operations, and known pitfalls — start with [`overview.md`](docs/context/reference/overview.md) |

## Contributing

DeskPilot is maintained by a single developer, and issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). The most useful bug reports include your macOS and iOS versions, whether you were on LAN or remote access, and what the screen displayed.

## Third-party components

Remote access uses [wireguard-go](https://git.zx2c4.com/wireguard-go) (MIT), compiled from pinned upstream source. `wireguard-tools` is deliberately not bundled, to avoid GPL obligations.

## License

Released under the [MIT License](LICENSE).
