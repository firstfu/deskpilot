# Contributing to DeskPilot

DeskPilot is built by one person, so every bit of help is noticed. Issues and pull requests are welcome in English or 繁體中文.

## 1. Report a bug

Please include:

- macOS and iOS versions
- LAN or remote access (WireGuard tunnel)
- What you expected and what happened — a screenshot helps
- Whether Screen & System Audio Recording and Accessibility are granted to the host app

## 2. Suggest a feature

Describe the situation, not just the feature: what you're trying to do and how you handle it today. Use the feature-request issue template.

## 3. Send a pull request

Build setup is in the [README](README.md#build-from-source). Before you start:

- Read [`docs/context/reference/boundaries.md`](docs/context/reference/boundaries.md) for coding conventions and known pitfalls, and [`overview.md`](docs/context/reference/overview.md) for the architecture.
- Changes to the wire format must follow [`protocol.md`](docs/context/reference/modules/protocol.md), including the version rules.
- After touching a hot path (capture, encode, display), run the in-app benchmark or `scripts/host-bench.sh` and compare.
- Don't commit personal data: your home IP, domains, device names, Team ID or signing identities.
- Keep commits small, with a message that says why.

By contributing you agree that your work is released under the project's [MIT](LICENSE) license.
