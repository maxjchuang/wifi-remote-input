# Protocol v1 — Text input and phone control

Current implementation: macOS / Android 0.9.6. Protocol version remains 1; optional control actions extend the existing authenticated connection.

[Architecture](../docs/architecture.md) · [Development and acceptance](../docs/development.md)

SPDX-License-Identifier: AGPL-3.0-only

Endpoint: `wss://<private IPv4>:8765/input`. No plaintext HTTP input endpoint.
Both peers require TLS 1.3; the Android minimum is API 29. TLS 1.2-only reconnects stalled during URLSession/JVM interoperability validation, so this MVP does not enable that fallback. Android owns a persistent, app-private self-signed RSA certificate. The user scans a QR code displayed by the phone, transferring its **complete SHA-256 certificate fingerprint**, address and one-time code to the Mac. Pairing UI uses QR scanning. The Mac checks the DER leaf certificate hash before transmitting any pairing code, credential or input. Never obtain a fingerprint from an unauthenticated network endpoint. No trust-on-first-use fallback or redirect is allowed.

## Pairing and authentication

1. User starts the Android foreground receiver and generates an eight-digit random pairing code. Codes expire after 120 seconds; at most five guesses are allowed globally across connections. Generating a new code invalidates the previous code.
2. Mac pins the phone certificate and sends `pair` with `{"code":"…"}`.
3. On success, Android consumes the code and returns `{"version":1,"type":"result","status":"paired","token":"…"}`. The token is 32 random bytes encoded as 64 lowercase hex characters. The session is now authenticated.
4. Mac stores the token in Keychain. Android persists only its SHA-256 hash in private preferences, with app backups disabled. The certificate private key is stored in the app's private no-backup directory. The PKCS12 container password is not an additional security boundary; Android's app sandbox is.
5. Reconnection uses `auth` with `{"token":"…"}` over the same pinned TLS connection and receives status `authenticated`.
6. Each phone supports **one paired Mac**. A successful new pairing replaces the old token. Revocation invalidates authorization for subsequent input messages on existing connections as well as future connections.

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
| `control.action` | `action`, plus string `x` / `y` for coordinate actions | Optional authenticated phone control; schema below |

Every request returns one `result` with `version:1` and a non-sensitive `status` string. The client sends **only one request at a time per connection**, so v1 does not need message IDs. No automatic retries of input are permitted: a disconnect before a response makes delivery uncertain.

Common statuses: `ok`, `paired`, `authenticated`, `pong`, `unauthorized`, `authentication_failed`, `password_blocked`, `device_locked`, `no_editor`, `editor_rejected`, `editor_timeout`, `invalid_message`, `unsupported_version`, `unknown_type`, `invalid_text`, `invalid_key`, `too_large`, `rate_limited`.

For editor operations, `ok` means the InputConnection accepted the operation, not that the target app persisted it. For gestures it acknowledges dispatch acceptance, not completion or the target app’s effect. Enter uses the editor's action (Search/Send/Done, etc.) unless the editor requests a literal Enter. Other keys use Android down/up events.

## Boundaries

- 16 KiB WebSocket frames/messages; maximum 4,096 UTF-16 code units per text commit; empty text rejected.
- Maximum 40 messages/second/connection; at most four admitted WebSocket sessions; unauthenticated sessions expire after ten seconds. These are application limits, not a guarantee against network denial of service.
- Binary frames rejected. Authentication failures, unauthorized input and rate violations close the connection.
- All text-password, visible-password, web-password and numeric-password editor types are blocked, including keys. Null/unknown editor classes are rejected. Locked phones reject input.
- InputConnection operations run on Android's main thread. Finished/inactive editor sessions cannot receive input.
- No application logging of input, clipboard, pairing codes, device keys or session keys. Errors never echo request payloads.
- Raw `key.down/up`, clipboard-transfer and arbitrary command messages are unsupported. Mouse and accessibility actions use only the `control.action` allowlist below; discovery uses DNS-SD outside this connection.

## Pairing QR (0.2.0)

Phone-generated QR text is UTF-8 JSON: `kind` = `wifi-remote-input`, `version` = `1`, `address` = private IPv4 plus port, `fingerprint` = full SHA-256 certificate hash, `code` = eight ASCII digits (preserve leading zeros). It contains no long-term device key. The existing `pair` request consumes this code; server-side expiration, attempt limits and single-use rules apply unchanged. Creating a new QR invalidates the previous code.

The Mac validates the QR schema, size (2 KiB), private address and fingerprint before connecting. It accepts exactly one valid pairing QR per frame, pins that certificate before sending the one-time code, and then saves the resulting key in Keychain. Camera frames remain in memory, are processed locally with Vision and are never recorded or uploaded. Capture stops when the scanner closes or a valid QR is accepted. Unrelated QR codes are not opened as links.

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


## 地址发现（可选，0.7.0）

DNS-SD 服务类型 `_wri-input._tcp.`，端口指向现有 TLS WebSocket 接收端；TXT `v=1`、`id=<完整小写 SHA-256 证书指纹>`。这些字段仅用于查找已配对记录和候选地址，不能建立信任或替换保存的证书。连接仍执行相同证书固定校验和 `auth` 流程；广播不含授权凭据，不允许未配对输入。

## 可选手机控制（0.8.0）

`control.action` 分为两种严格 schema：

| 动作 | payload 字段 |
| --- | --- |
| start、pointer_start、stop、ping、back、home、recents、next、previous、left、right、up、down、click、long_click、scroll_up、scroll_down | 仅字符串 `action` |
| pointer_move、pointer_tap、pointer_down、pointer_drag、pointer_up | 字符串 `action`、`x`、`y`，不得缺少或附加字段 |

例如 `{ "action": "start" }`。未知动作或多余字段拒绝。仅通过已认证连接调用，返回普通 result/status。

服务端将控制权绑定到 WebSocket 实例，start 获取控制权；另一实例返回 control_busy。Mac 仅在本地控制区聚焦期间每两秒 ping；六秒无活动、断线、撤销认证、锁屏、用户暂停、接收服务停止或辅助功能退出都会释放控制权。新连接必须重新 start，不重放操作。stop 可重复调用，其他会话不能停止当前控制者。普通文字输入不要求此权限。

状态包括 accessibility_disabled、control_paused、control_busy、device_locked、no_controls、selection_changed、password_blocked、action_unavailable。选中控件在手机本地维护，不发送文本、节点树或截图。窗口更新后清除选中；执行前刷新节点并核对可见性、当前窗口、密码属性。坐标仅通过下述白名单动作提供，不接受任意 Intent／Shell 命令。

### 鼠标捕获扩展（0.9.0）

- `control.action` 新增 `pointer_start`（仅 action 字段），从屏幕中心建立指针会话；原有 start 保留键盘节点控制。
- `pointer_move` / `pointer_tap` payload 严格为 `{"action":"pointer_tap","x":"7000","y":"2500"}`，x/y 为十进制整数字符串，范围 0…10000，表示当前手机默认显示屏从左上角起算的归一化位置；不接受任意字段、负数、浮点、NaN 或越界值。
- `pointer_tap` 携带独立坐标，使用 AccessibilityService.dispatchGesture 发送 40ms 单击，不要求目标有可访问节点。可读取到的密码节点命中时拒绝。`ok` 表示系统已接受手势派发，不表示目标应用已经执行操作；系统拒绝为 gesture_unavailable，上一手势未完成为 gesture_busy，操作不重试。
- 右键沿用 back，Esc 沿用 stop。指针移动不产生触控，也不获取或上传手机画面。控制者认证、连接绑定、锁屏、租期及撤销规则不变。
- Mac 捕获仅在手机确认 pointer_start 且本地控制区仍聚焦后生效。移动采样 30Hz（0.9.2 起），连续移动合并；点击作为顺序边界并携带点击时位置。队列上限 32，停止时丢弃待发送操作。控制请求之间最少约 33.3ms（0.9.2 起），避免触发服务端 40 帧/秒限速。

### 持续触摸（0.9.3）

`pointer_down`、`pointer_drag`、`pointer_up` 使用与 pointer_move 相同的 x/y 严格归一化坐标字段。down 建立 willContinue=true 的触摸，drag 通过 continueStroke 延续同一根手指，up 用 willContinue=false 结束。未建立 down 的 drag 返回 touch_not_down；重复 down 返回 gesture_busy。旧 pointer_tap 保留兼容。

Mac 仅合并相邻且同类型的 pointer_drag，不跨 down/up 合并；up 携带最终坐标。Android 单个手势分段执行中仅保存最新待移动坐标，up 标记不会被移动覆盖；等待当前段完成后释放。stop、失焦引发的停止、断线、超时与撤销会丢弃待移动位置并结束当前触摸。释放可能触发目标应用的松手行为，已发生的按下或拖动不能撤销。


### 键鼠协同与错误恢复（当前客户端）

键鼠协同不新增报文类型。`pointer_start` 建立控制会话，文字仍使用 `editor.snapshot` / `editor.edit` / `key.press`，与控制请求在同一连接上串行执行。协同快照每 200ms 尝试一次，忙或按住左键时跳过；有效快照才允许协同打字。点击/返回使旧快照失效，editorId 变化丢弃旧组词。控制及其文字不参与多机广播。

| 状态 / 事件 | 当前客户端处理 |
| --- | --- |
| `no_editor`、`password_blocked`（输入框快照） | 清除文字快照并暂停文字，保留鼠标控制；有效新快照恢复文字 |
| `snapshot_unavailable`、`editor_too_large` | 无有效镜像，不接受协同文字，鼠标仍可操作 |
| `touch_not_down` | 保留捕获，本次拖动后续只移动指针；物理松开再按下才建立新触摸 |
| `gesture_busy` 或按下时 `password_blocked` | 本次按下失败，不自动重试，等待物理松开 |
| `gesture_unavailable`、`accessibility_disabled`、`device_locked`、`control_paused` | 停止本地控制并提示原因 |
| 断线 / 认证失败 | 释放捕获，不重放文字和手势；重新认证不会恢复旧控制会话 |

控制请求限速与文字/快照/保活共享服务端每秒 40 条的总预算，不能将它们当作独立限额。扩展协议时不得引入并行 exchange 或在确认丢失时补发触摸。TLS 互通测试验证封装与顺序，真实系统手势完成仍需手机验收。
