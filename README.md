# WiFi Remote Input

Use a Mac keyboard and mouse to control text input on Android over a local Wi-Fi network.

The project is an open-source alternative for devices where Bluetooth HID controller mode is unavailable or unreliable. It does not require USB debugging, root access, or a cloud service.

## Planned architecture

- **macOS client:** SwiftUI menu bar app that captures keyboard and mouse input.
- **Android receiver:** Kotlin `InputMethodService` that commits text and editor actions to the focused app.
- **Transport:** authenticated, encrypted WebSocket on the local network.
- **Pairing:** short-lived pairing code or QR code, followed by persistent device keys.

```text
Mac keyboard/mouse
        │
        ▼
macOS client ── encrypted WebSocket ──► Android IME ──► focused input field
```

## Goals

- Send Unicode text, including Chinese, without depending on keyboard-layout emulation.
- Support Enter, Backspace, arrows, modifiers, shortcuts, media keys, mouse movement, clicks, and scrolling where Android permits them.
- Keep traffic on the local network and reject unauthenticated clients.
- Provide a simple setup flow for non-technical users.
- Work without ADB after the Android app is installed and enabled as an input method.

## Repository layout

```text
android/   Android IME and receiver
macos/     macOS client
protocol/  transport protocol and compatibility rules
docs/      architecture and product documentation
```

## Status

The repository is in the design and bootstrap phase. See [docs/architecture.md](docs/architecture.md) and [protocol/README.md](protocol/README.md).

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
