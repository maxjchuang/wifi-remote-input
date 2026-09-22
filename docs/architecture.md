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

## Multi-phone client (0.5.0)

`Client` owns device records and explicit input targets; `DeviceSession` owns one transport, authentication lifecycle, input pipeline, draft and editor snapshot. UI bindings follow the preview phone; input routes to a frozen set of recipients chosen at enqueue time. Switching/recipient edits invalidate queued work and the composition view. Every connection serializes its own authentication, input, snapshot and heartbeat requests. Failures propagate a group pause, not a replay or a rollback. Records store only display metadata; tokens remain keyed by certificate fingerprint in Keychain. Android stores the peer display name atomically with the credential hash and publishes authenticated connection state to its UI.


## 局域网发现（0.7.0）

Android 在 TLS 监听成功后用 NsdManager 注册 `_wri-input._tcp.`；接收停止时撤销，注册失败每 30 秒重试。NSD 在可用网络发布当前地址。服务名使用证书摘要前缀，TXT 仅包含 `v=1` 与公开证书 SHA-256 `id`，不广播设备友好名称、配对码、密钥或输入内容。

Mac 使用 Bonjour 搜索和周期解析服务，只接受已保存指纹对应的私有 IPv4 地址，缓存 35 秒。服务广播是不可信的路由提示：每次连接仍固定原证书指纹并使用原设备密钥认证，认证成功才保存新地址。单设备自动尝试间隔至少 30 秒；手动连接不受此间隔限制。曾发起连接的设备遇到网络失败后允许重连，显式断开／忘记／认证失败停止自动重连。应用重启不自动连接所有手机。重连成功暂停整组输入，不回放旧队列。

Bonjour 被禁用、访客网络隔离或无私有 IPv4 时保留扫码路径；自动发现不突破网络隔离。公开指纹会使局域网观察者关联同一设备在不同网络上的广播，但它不提供认证权限。

## 可选手机控制

PhoneControlService 独立于 RemoteIme，仅用户在 Android 系统中主动开启后可用。Protocol 校验控制动作，InputServer 将其绑定到 WebSocket 实例；ReceiverService 在主线程再次检查连接与配对认证后执行。关闭连接会立即释放对应控制者；每 500ms 检查撤销、锁屏和六秒租期，释放时移除覆盖层。

Mac ControlKeysView 只处理自身获得焦点时的键盘事件，按两秒间隔保活。DeviceSession 将控制请求与已有输入／快照请求互斥执行，暂停通过有序 stop 收尾，并用 generation / controlEpoch 丢弃迟到响应。Client 切换设备时停止原设备控制；广播文字功能不参与控制路由。手机端仅传回结果状态，不传回节点树、控件文本或屏幕图像。

节点点击和系统导航使用 [Android AccessibilityService](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService) 与 [AccessibilityNodeInfo](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo) 标准能力。控件不支持动作时直接提示，不用猜测坐标点击兜底。

### 鼠标捕获与触控

0.9.0 的 ControlKeysView 在授权会话确认和本地焦点校验之后使用 CGAssociateMouseAndMouseCursorPosition 固定 Mac 光标，通过局部 NSEvent 监听接收相对位移和左右键。MouseCaptureLease 平衡隐藏／显示与解除／恢复关联，退出和析构均可幂等释放。没有全局事件 tap；操作期间焦点离开立即退出。手机按当前显示屏真实尺寸绘制归一化坐标指针，通过 dispatchGesture 执行短单击，右键使用全局返回。移动只更新指针，不采集屏幕内容。
