# Protocol v1 — MVP

SPDX-License-Identifier: AGPL-3.0-only

Endpoint: `wss://<private IPv4>:8765/input`. No plaintext HTTP input endpoint.
Both peers require TLS 1.3; the Android minimum is API 29. TLS 1.2-only reconnects stalled during URLSession/JVM interoperability validation, so this MVP does not enable that fallback. Android owns a persistent, app-private self-signed RSA certificate. The user scans a QR code displayed by the phone, transferring its **complete SHA-256 certificate fingerprint**, address and one-time code to the Mac; manual entry remains available. The Mac checks the DER leaf certificate hash before transmitting any pairing code, credential or input. Never obtain a fingerprint from an unauthenticated network endpoint. No trust-on-first-use fallback or redirect is allowed.

## Pairing and authentication

1. User starts the Android foreground receiver and generates an eight-digit random pairing code. Codes expire after 120 seconds; at most five guesses are allowed globally across connections. Generating a new code invalidates the previous code.
2. Mac pins the phone certificate and sends `pair` with `{"code":"…"}`.
3. On success, Android consumes the code and returns `{"version":1,"type":"result","status":"paired","token":"…"}`. The token is 32 random bytes encoded as 64 lowercase hex characters. The session is now authenticated.
4. Mac stores the token in Keychain. Android persists only its SHA-256 hash in private preferences, with app backups disabled. The certificate private key is stored in the app's private no-backup directory. The PKCS12 container password is not an additional security boundary; Android's app sandbox is.
5. Reconnection uses `auth` with `{"token":"…"}` over the same pinned TLS connection and receives status `authenticated`.
6. MVP supports **one paired Mac**. A successful new pairing replaces the old token. Revocation invalidates authorization for subsequent input messages on existing connections as well as future connections.

The bearer device key is protected by pinned TLS; no custom cryptography or unencrypted challenge/response layer is used. TLS protects against network replay. Someone with access to the phone display or Mac Keychain can authorize input; these endpoints are trusted.

## JSON text frames

```json
{"version":1,"type":"text.commit","payload":{"text":"你好，小米 13 👋"}}
```

| Type | Payload | Behavior |
| --- | --- | --- |
| `pair` | `code` string | Consume one-time code and issue device key |
| `auth` | `token` string | Authenticate a previously paired device |
| `text.commit` | `text` string | `InputConnection.commitText(text, 1)` |
| `key.press` | `key` string | `Enter`, `Backspace`, `ArrowLeft`, `ArrowRight`, `ArrowUp`, `ArrowDown` |
| `session.ping` | `{}` | Return `pong` after authentication |

Every request returns one `result` with `version:1` and a non-sensitive `status` string. The client sends **only one request at a time**, so v1 does not need message IDs. No automatic retries of input are permitted: a disconnect before a response makes delivery uncertain.

Common statuses: `ok`, `paired`, `authenticated`, `pong`, `unauthorized`, `authentication_failed`, `password_blocked`, `device_locked`, `no_editor`, `editor_rejected`, `editor_timeout`, `invalid_message`, `unsupported_version`, `unknown_type`, `invalid_text`, `invalid_key`, `too_large`, `rate_limited`.

`ok` means the InputConnection accepted the operation, not that the target app persisted it. Enter uses the editor's action (Search/Send/Done, etc.) unless the editor requests a literal Enter. Other keys use Android down/up events.

## Boundaries

- 16 KiB WebSocket frames/messages; maximum 4,096 UTF-16 code units per text commit; empty text rejected.
- Maximum 40 messages/second/connection; at most four admitted WebSocket sessions; unauthenticated sessions expire after ten seconds. These are application limits, not a guarantee against network denial of service.
- Binary frames rejected. Authentication failures, unauthorized input and rate violations close the connection.
- All text-password, visible-password, web-password and numeric-password editor types are blocked, including keys. Null/unknown editor classes are rejected. Locked phones reject input.
- InputConnection operations run on Android's main thread. Finished/inactive editor sessions cannot receive input.
- No application logging of input, clipboard, pairing codes, device keys or session keys. Errors never echo request payloads.
- `key.down/up`, clipboard, mouse, accessibility and discovery are reserved for future versions and currently rejected.

## Pairing QR (0.2.0)

Phone-generated QR text is UTF-8 JSON: `kind` = `wifi-remote-input`, `version` = `1`, `address` = private IPv4 plus port, `fingerprint` = full SHA-256 certificate hash, `code` = eight ASCII digits (preserve leading zeros). It contains no long-term device key. The existing `pair` request consumes this code; server-side expiration, attempt limits and single-use rules apply unchanged. Creating a new QR invalidates the previous code.

The Mac validates the QR schema, size (2 KiB), private address and fingerprint before connecting. It accepts exactly one valid pairing QR per frame, pins that certificate before sending the one-time code, and then saves the resulting key in Keychain. Camera frames remain in memory, are processed locally with Vision and are never recorded or uploaded. Capture stops when the sheet closes or a valid QR is accepted. Unrelated QR codes are not opened as links.
