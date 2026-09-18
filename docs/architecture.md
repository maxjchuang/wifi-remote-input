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

## Implemented MVP (0.1.0)

- Android SDK 35/Kotlin with user-started `specialUse` foreground service; no boot receiver. A local TLS WebSocket listener shares one process with the IME. IME calls are marshalled to the main thread, rechecking authorization immediately before applying input.
- Certificate pinning uses a full SHA-256 value transferred via a QR code on the phone display (manual entry remains available); pairing uses a two-minute, eight-digit code with a global five-attempt budget. The Mac stores the issued 256-bit bearer device key in Keychain; Android stores only its hash and disables backups. A new pairing replaces the previous Mac.
- TLS certificate/private key persists in Android's app-private no-backup directory. Reinstalling/clearing phone application data requires pairing with a new fingerprint. No separate account or CA service exists.
- SwiftUI text editor and structured-key buttons; a shared URLSession transport also drives local interoperability tests. The client has one in-flight request, checks connectivity every five seconds and never replays input automatically.
- All Android password editor variants and locked devices reject both text and keys. No focused editor returns `no_editor`. No AccessibilityService is shipped.
- Scope deliberately excludes direct global hardware capture, mouse, clipboard, Bonjour. None is needed for the Unicode MVP.

The foreground service declaration follows [Android's service-type requirements](https://developer.android.com/about/versions/14/changes/fgs-types-required). Real HyperOS background behavior remains a device-level acceptance check.

## QR pairing (0.2.0)

Android renders the address, full certificate fingerprint and existing expiring pairing code using ZXing. Wi-Fi addresses are preferred; the phone allows selecting another local interface. macOS captures camera frames with AVFoundation, detects QR codes locally using Vision, validates the offer and runs the existing pinned TLS pairing exchange. No new listening port or unauthenticated input route is introduced. Camera access is requested only when the user opens the scanner.
