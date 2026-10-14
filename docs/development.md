# 开发与本地验证

[返回项目首页](../README.md)

## 构建

要求 macOS 13+、Xcode/Swift 5.9+；Android 10+（API 29，TLS 1.3）。Android 构建使用 JDK 17、SDK 35、AGP 8.9.2、Kotlin 2.1.20、Gradle 8.11.1。

```sh
# 如缺少 Android 开发环境（Apple Silicon Homebrew）
brew install openjdk@17
brew install --cask android-commandlinetools
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
sdkmanager --sdk_root="$ANDROID_HOME" --licenses
sdkmanager --sdk_root="$ANDROID_HOME" 'platforms;android-35' 'build-tools;35.0.0'

# 项目根目录
./scripts/build-macos.sh
cd android
./gradlew assembleDebug testDebugUnitTest lintDebug
```

产物：

- `macos/build/WiFi Remote Input.app`：本地临时签名，无需 Apple 开发者账号。
- `android/app/build/outputs/apk/debug/app-debug.apk`：可直接安装的开发测试包，不是正式发布签名。

不要将 `local.properties`、构建输出或密钥提交到仓库。Gradle Wrapper 会首次下载固定版本；需要访问 Google Maven、Maven Central 和 Gradle 下载源。

## 验证

```sh
# 从项目根目录运行 Swift ↔ Kotlin 实际 TLS/WebSocket 互通测试
./scripts/test.sh
```

测试包含协议错误、认证失败、未配对输入、验证码过期/单次使用/跨连接猜测上限、密钥撤销、消息大小与频率限制、所有密码框变体拒绝、Android InputConnection 中文提交和按键/编辑器动作，以及证书指纹不符拒绝。另覆盖 Mac 中文组合输入、顺序发送、拒绝／断线不重发、暂停丢弃队列及 Android 两种系统外观启动。

互通测试会在本机临时启动**与 Android 相同的接收服务代码**，由真正的 Swift URLSession 客户端配对、重新认证并发送中文和六种按键；仅使用本机回环，不接触手机。Robolectric 测试执行 Android IME 到 InputConnection 的调用。这些验证不能替代小米 13/HyperOS 的实际输入框验收，手机安装、输入法启用和最终中文显示需要在实机操作。


## 当前版本与代码导航

当前 Mac 为 **0.10.3**、Android 为 **0.10.1**；协议版本仍为 **1**。手机控制属于新增功能域，不代表协议升级或已经发布 1.0。更新概览见[手机控制大更新](releases/0.9.md)，模块职责见[架构设计](architecture.md)。

- 输入与同步：`macos/Sources/RemoteCore/CommitTextView.swift`、`macos/Sources/WiFiRemoteInput/App.swift`、`android/app/src/main/java/dev/wifiremote/RemoteIme.kt`。
- 捕获与路由：`macos/Sources/WiFiRemoteInput/PhoneControlPanel.swift`、`Client.swift`。
- 手机控制：`android/app/src/main/java/dev/wifiremote/PhoneControlService.kt`、`PointerDrag.kt`、`PointerMotion.kt`。
- 协议与认证：`Protocol.kt`、`InputServer.kt`、`ReceiverService.kt`；扩展动作时同时修改 Swift 发送端及严格字段校验。
- 自动发现：Mac `DeviceDiscovery.swift`、Android `ServiceAdvertisement.kt`。

Android 版本号位于 `android/app/build.gradle.kts`，Mac 版本号由 `scripts/build-macos.sh` 写入 Info.plist。升级 APK 需相同签名并递增 versionCode；本地调试签名不等于正式发布签名。旧控制客户端可能不支持持续拖动，建议两端一起更新。

## 手机控制回归重点

| 测试位置 | 主要边界 |
| --- | --- |
| `macos/Tests/ClientTests/ClientTests.swift` | 仅当前手机接收控制、按下/移动/松开顺序、重复响应不重启捕获、触摸取消不退出、延迟确认与失焦取消、文字拒绝不停止鼠标 |
| `macos/Tests/ClientTests/MouseCaptureTests.swift` | 光标关联和隐藏/显示平衡，重复释放与失败清理 |
| `macos/Tests/RemoteCoreTests/MirrorTests.swift` | 中文组词不提前发送、镜像更新不回送、其他编辑器组词不受影响 |
| Android `ProtocolTest` / `PhoneControlTest` | 未认证拒绝、严格坐标、连接所有权、密码/锁屏/撤销、租期、常亮浮层清理 |
| Android `PointerDragTest` / `PointerMotionTest` | 连续触摸路径、取消/释放、最新位置合并、插值与停止 |
| Android `InteropTest` + Swift `Smoke` | 真正的 TLS/WebSocket 协议互通；手机执行回调为测试替身 |

PointerDrag 路径测试使用 Robolectric native graphics，不能以 legacy 图形模式的路径结果代替真实几何检查。Mac 鼠标生命周期测试注入关联/隐藏函数，不捕获开发者的真实鼠标。最新已执行结果为 Swift 51 项、Android 58 项通过；详细适用范围见[验证记录](validation.md)，数字不是对真机兼容性的承诺。

## 实机验收清单

不使用 ADB 或 USB 调试。将 APK 传到手机并覆盖安装，启动接收、选择输入法，再按需启用「Remote Input 手机控制」。Mac 退出旧版后启动新构建。

| 场景 | 预期 |
| --- | --- |
| 未启用辅助功能 | 普通中文输入正常，手机控制提示开启权限 |
| 点击控制区 | 手机确认后隐藏 Mac 光标，手机出现指针；启动点击不触发手机操作 |
| 点击、长按、拖动、右键 | 分别执行触控或返回；拖动取消后松开再按下可恢复，不自动补发 |
| 选中普通输入框 | 不切 Tab 即可中文选词和编辑；快照与手机文字一致，无提前提交 |
| 手机切框、密码框、无输入框 | 丢弃旧组词/快照，禁止错误文字目标；鼠标仍可操作 |
| Esc 与失焦 | 组词阶段先取消组词，否则释放捕获；小窗收起，其他 Mac App 中文输入正常 |
| 等待确认时切窗口 | 迟到响应不会重新隐藏或捕获 Mac 鼠标；双显示屏分别验证 |
| 断线、停止接收、撤销权限、锁屏 | 不补发输入/手势，释放控制与常亮；网络异常受租期超时约束 |
| 两台手机已连接并开启文字群发 | 手机控制及协同文字仍只发当前手机；切换设备停止旧控制 |
| 控制后静置 | 手机常亮；退出后恢复原系统息屏，不主动唤醒或解锁 |
| 输入法面板 | 点标题/留白进入 App，点切换按钮只打开系统输入法选择器 |
| 换 Wi-Fi | 同网重新发现已配对手机，固定证书认证成功才更新地址；不恢复旧控制动作 |

请使用备忘录或测试会话验收，区分“协议返回 ok”“系统接受手势”和“目标 App 完成操作”。记录机型、系统版本、目标 App、复现步骤与状态文字；不要记录输入内容、配对码或密钥。当前无投屏，因此端到端触控及中文上屏须直接观察手机。

## 调试更新与诊断（0.10.0）

- Android `DiagnosticLog.kt`：预定义事件白名单，300 条有界保留，相邻相同事件 10 秒内去重。默认启用，可关闭、清空、通过系统文档选择器导出。不抓取 logcat、异常详情或用户内容，自动同步到已配对 Mac，不上传公网。
- `MaintenanceActivity.kt`：日志及更新页面；`UpdateInbox.kt`：单连接上传、校验及私有暂存；`UpdateProvider.kt`：向系统安装器临时授予单个 APK 的只读权限。
- Mac `DeviceSession.pushUpdate` 与工作台侧栏：选择本地 APK，暂停目标设备输入和控制，在已有认证连接上串行上传；失败关闭连接以清理未完成上传，不自动重试。

首次需手动安装支持该协议的手机版本。以后递增 `android/app/build.gradle.kts` 的 versionCode/versionName，使用同一签名构建 `assembleDebug`，连接手机并在手机允许接收后，从 Mac 选择新 APK。保留本机调试签名；换电脑或换签名生成的包不能作为原应用更新。不要把签名私钥提交到仓库。相同 versionCode 的重新构建也不能推送覆盖。

推送只传输文件，手机仍须明确触发并确认系统安装。最多 80 MiB，授权窗口 10 分钟；目前不提供 GitHub 查询、下载、自动安装或断点续传。无需 ADB、USB 调试或新开未认证端口。

`MaintenanceTest` 覆盖授权窗口、身份/所有权、乱序与超大分片、摘要、包名/签名/版本、日志隐私与导出入口。Swift 测试覆盖目标隔离、暂停输入及分片重组；TLS 互通测试覆盖真实传输，但使用更新执行回调替身。需额外真机验收：手动装基础版 → 推送同签名更高版本 → 手机确认安装 → 重新连接；以及拒绝同版本、断线清理和关闭日志后的不记录行为。

### Codex 分析手机日志

两端更新至 0.10.1 后，在手机保留日志记录并连接 Mac。停止输入/拖动等待一次空闲心跳，然后让 Codex 读取 `/tmp/wifi-remote-input/*.log`。Mac 侧栏「查看手机日志」的悬浮提示显示当前设备对应路径。每个文件按设备隔离，保存最新 300 条快照；不会无限追加。目录只允许当前 macOS 用户访问，系统可能清理 `/tmp`。查看事件时间以判断是否为最新复现；离线不会更新文件。
