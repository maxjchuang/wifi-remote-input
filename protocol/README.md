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
| `pair` | `code` string, optional `deviceName` | Consume one-time code and issue device key |
| `auth` | `token` string, optional `deviceName` | Authenticate a previously paired device |
| `text.commit` | `text` string | `InputConnection.commitText(text, 1)` |
| `key.press` | `key` string | `Enter`, `Send`, `LineBreak`, `Backspace`, `ArrowLeft`, `ArrowRight`, `ArrowUp`, `ArrowDown` |
| `editor.edit` | String fields: `editorId`, `expectedHash`, `text`, `selectionStart`, `selectionEnd` | Compare and apply single-phone mirrored edit (0.6.0+) |
| `editor.snapshot` | `{}` | Authenticated read of the focused non-password editor (0.4.0+) |
| `session.ping` | `{}` | Return `pong` after authentication |

Every request returns one `result` with `version:1` and a non-sensitive `status` string. The client sends **only one request at a time per connection**, so v1 does not need message IDs. No automatic retries of input are permitted: a disconnect before a response makes delivery uncertain.

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

## Focused editor snapshot (0.4.0)

`editor.snapshot` requires live paired-device authentication, an empty payload, and the same TLS connection as input. Android rechecks authorization on the IME main thread and after the read. Lock-screen and password/unknown input-type checks happen **before** calling `getExtractedText(request, 0)`. The IME must have an active editor.

A successful result has `status: "snapshot"`, `editorId` (opaque string identifying the input session), `text`, `selectionStart`, and `selectionEnd` (UTF-16 offsets within text). Full replacement on every snapshot, never append. `startOffset` must be zero and `partialStartOffset` must be -1; otherwise return `snapshot_unavailable`. Text exceeding 2048 UTF-16 units returns `editor_too_large`, without a text field. The limit keeps even JSON-escaped responses below 16 KiB. Empty text is a valid snapshot of an empty field.

Failures contain status only, without text or selections: `password_blocked`, `device_locked`, `no_editor`, `snapshot_unavailable`, `editor_too_large`, `editor_timeout`, or `unauthorized`. Clients discard previously displayed text on failure/disconnect/hidden input and must not substitute local input history. Older servers return `unknown_type`; the Mac prompts for an Android update.

Mac polls about every 250ms while the input view is visible and key, and reads during continuous input at most about every 300ms, serialized with input/heartbeat exchanges. It displays the last available snapshot, not an atomic live mirror; target applications control extraction support and correctness. New input invalidates old snapshots. No snapshot text is persisted or logged. Pairing UI informs users that the paired Mac can view the focused ordinary input field.

## Device names and multiple phones (0.5.0)

`pair` and `auth` accept an optional `deviceName` string identifying the Mac. If present, it must be nonempty after trimming, at most 80 UTF-16 code units, and contain no ISO control or bidi override/isolate characters. Validate before consuming a pairing code. Successful `paired` / `authenticated` responses include the phone's `deviceName`; failures do not disclose it. Names are display metadata, never identities or authorization credentials.

Android atomically stores the Mac name alongside its token hash in app-private preferences. Raw legacy hashes remain valid and upgrade on successful named authentication. Failed authentication cannot rename the peer; revocation removes both name and hash. Each phone continues to authorize one Mac; the Mac holds a separate pinned transport, token, serialized input queue and snapshot per phone. Phone records are deduplicated by certificate fingerprint, never by name/address.

Fan-out is client-side, using the existing protocol independently on each selected connection. Recipient changes discard queued input and pause the group; in-flight input can finish only on its original connection. A disconnected/paused target blocks further fan-out. Any recipient rejection pauses all target queues, without retries or rollback: earlier deliveries may have succeeded on other phones. Broadcast recipients are explicit and broadcasting is off at launch.

## Single mirrored editor (0.6.0)

`editor.edit` requires live authentication and exactly five string fields. Text is bounded to 2048 UTF-16 units, selection offsets must satisfy `0 <= start <= end <= text.length`, and `expectedHash` is 64 lowercase hex digits. Hash input is UTF-8 encoding of `oldText + U+0000 + decimal(min(oldSelectionStart, oldSelectionEnd)) + "," + decimal(max(...))`. Both SHA-256 hash and `editorId` must match a fresh full snapshot before applying an edit. All password, lock-screen, editor-active, main-thread authorization and extraction limits apply before reading or writing. Mismatch returns `editor_conflict` without a mutation. Unsupported extraction does not permit mirrored edits.

Within an InputConnection batch, Android replaces only the changed text range (preserving unchanged spans and surrogate pairs), then sets the requested selection. This is an IME-level compare-before-write safeguard; Android target app mutations are not a cross-process transaction. Editor rejection, normalization, concurrent changes or editor switches can require a new snapshot. Clients discard queued edits on rejection; no replay. A lost acknowledgement remains uncertain and must not be retried.

Mac shows a single native text editor. Confirmed local edits remain visible while pending, and snapshots cannot overwrite marked text or a newer pending edit. Focus loss drops unfinished composition and queued operations; re-entering the native editor or returning to a key window resumes without waiting for an earlier acknowledgement. Phone reads never echo back as writes. Multi-phone mode sends independent text/key events at each target's own caret rather than copying the preview phone's entire document to others.

`Send` invokes the editor's custom action if supplied, otherwise `IME_ACTION_SEND`. `LineBreak` commits a literal newline. Automatic `Enter` recognizes explicit SEND even with NO_ENTER_ACTION, supports custom actionId when permitted, and otherwise uses paired virtual keyboard events with SOFT_KEYBOARD and KEEP_TOUCH_MODE flags. These calls confirm request acceptance, not delivery of a chat message; applications control their send behavior. Shift+Enter maps to LineBreak after composition is confirmed.
