# Architecture

## Components

### macOS client

The macOS app captures local keyboard and mouse events, translates them into protocol messages, and sends them to a paired Android device. The first implementation can reuse concepts and selected AGPL-compatible code from `jqssun/darwin-bt-remote`, especially its SwiftUI controls, key mapping, and direct-input capture.

### Android receiver

The Android app provides an `InputMethodService`. When selected as the active keyboard, it applies incoming text through `InputConnection.commitText()` and sends navigation or editor actions through the appropriate `InputConnection` APIs.

Mouse and global navigation are a separate optional capability because they require Android Accessibility permission. Text input must work without that permission.

### Local transport

The Android device hosts the local endpoint. The Mac discovers it through Bonjour/mDNS or connects using a QR code containing the local address and a short-lived pairing secret.

After pairing, both sides store device keys. Every session is authenticated and encrypted. The server must not expose an unauthenticated HTTP or WebSocket input endpoint.

## Trust boundaries

- Text and key events are sensitive because they may contain private messages or credentials.
- Password fields must disable remote text input by default.
- Pairing secrets expire after first use or a short timeout.
- A paired Mac can be revoked from the Android app.
- Logs must never contain typed text, clipboard contents, pairing secrets, or session keys.

## Initial milestones

1. Android IME that accepts local test messages and commits Unicode text.
2. Authenticated LAN connection and pairing flow.
3. macOS text-entry client.
4. Direct physical-keyboard capture on macOS.
5. Navigation keys and editor actions.
6. Optional mouse and scroll support using Android Accessibility APIs.
7. Packaging, upgrade flow, documentation, and compatibility testing on Xiaomi 13.
