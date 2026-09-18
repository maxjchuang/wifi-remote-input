# 本机验证记录

## 0.2.0 扫码配对更新

用户已反馈 0.1.0 基础功能在实机跑通。本次新增手机二维码及 Mac 摄像头扫码自动配对，两端版本均为 0.2.0。Android 更新安装保留原证书和配对记录。

本次实际执行：Swift 测试 4 项、Kotlin 协议测试 11 项、IME 测试 3 项、跨语言互通测试 1 项，合计 **19 项全部通过，零跳过**。互通测试使用 Android 生产二维码生成代码输出图片，经过 macOS Vision 解码，自动执行固定证书 TLS 配对，并验证二维码不可重复使用、重连认证、中文和按键。另覆盖错误格式、未知版本、外网地址、缺失指纹及二维码过期/撤销状态。

Android APK、Mac Release 应用构建成功。摄像头权限说明已写入 Mac 应用；摄像头仅在打开扫码窗口时启动，关闭或识别成功后停止。图片解码至网络配对链路已在本机自动验证；用户随后反馈扫码配对「已验证 ok」，确认实机扫码流程通过。基础输入与扫码配对均有用户实机反馈，未逐项反馈的其他边界仍以自动测试结果为准。

新版产物：`artifacts/WiFiRemoteInput-0.2.0-debug.apk`、`artifacts/WiFiRemoteInput-0.2.0-macOS.zip`。手机打开「显示配对二维码」，Mac 点击「扫码配对」并允许摄像头访问即可；无摄像头时仍可手动配对。

以下保留首次 MVP 的验证记录。


首次验证日期：2026-09-18；开发基于起始提交 `5d5b917`。

## 环境与产物

- Apple Silicon，macOS 15.7.4；Xcode 26.3；Swift 6.2.4。
- 自动安装 Homebrew OpenJDK 17.0.20.1、Android command-line tools、Android SDK 35 / Build Tools 35.0.0。
- Gradle Wrapper 8.11.1 下载及 SHA-256 校验已实际执行；依赖版本保存在 `android/app/gradle.lockfile`。
- APK：`android/app/build/outputs/apk/debug/app-debug.apk`。APK 签名验证通过；包名 `dev.wifiremote`，版本 0.1.0，minSdk 29，targetSdk 35。
- Mac：`macos/build/WiFi Remote Input.app`。Release 构建及本地临时签名验证通过，实际启动窗口并检查了未连接状态下禁止发送、空地址拒绝连接。
- 便于传输的副本：`artifacts/WiFiRemoteInput-0.1.0-debug.apk` 和 `artifacts/WiFiRemoteInput-macOS.zip`，附 `artifacts/SHA256SUMS`。这些构建输出不会纳入 Git。

## 实际执行的验证

`./scripts/test.sh` 成功：

| 测试 | 数量 | 结果 |
| --- | ---: | --- |
| Kotlin 协议、安全边界 | 10 | 全部通过 |
| Android IME / InputConnection（Robolectric，API 35） | 3 | 全部通过 |
| Swift ↔ Kotlin TLS 1.3 / WebSocket 互通 | 1 | 通过 |
| Swift 地址与证书指纹校验 | 2 | 全部通过 |

合计 **16 项，零失败，零跳过**。另执行 Android `assembleDebug`、`lintDebug` 及 macOS Release 构建。

互通测试运行真实 Swift URLSession 客户端和 Android 使用的同一份 Kotlin 接收服务代码，验证错误证书拒绝、未配对输入拒绝、首次配对、设备密钥重连认证、中文 `你好，小米 13 👋` 和全部六种按键。服务端在 JVM 上运行，测试设备密钥只存于临时目录并在测试后清理。

IME 测试执行真正的 `RemoteIme` 逻辑和 Android `BaseInputConnection`，核对中文缓冲区、编辑器动作、按键对、输入结束后拒绝，以及普通密码、可见密码、网页密码和数字密码框同时拒绝文本与按键。

这两组测试分别验证网络链路和 Android 编辑器链路；**没有安装或控制实物小米 13，也没有声称已在 HyperOS 实机输入框完成验收**。没有运行 ADB 或使用 USB 调试。

## TLS 兼容性取舍

TLS 1.2-only 配置在本机 URLSession/JVM 的连续断开、重连测试中出现超时；最终版本明确只启用 TLS 1.3，不保留该降级路径。最终完整测试针对这一配置通过。Android 最低版本因此设为 Android 10；[Android 官方说明](https://developer.android.com/about/versions/10/behavior-changes-all)确认 Android 10 开始内置并默认启用 TLS 1.3。小米 13 的实际 Android TLS 实现仍属于下面的实机验收范围。

Lint 没有错误。非阻断警告包括当前中文界面的资源化建议，以及 Bouncy Castle 依赖中未使用的信任管理器类。生产 Android 代码仅用 Bouncy Castle 生成本地证书，不使用该信任管理器建立客户端连接；Mac 对证书做完整 SHA-256 固定校验，并已通过错误证书拒绝测试。备份和设备迁移均显式禁用。

## 首次交付时的小米 13 验收清单（后续反馈见上文）

按根目录 README 的安装与配对步骤操作：

- 安装 APK，启用并选择 WiFi Remote Input，启动接收服务。
- Mac 填写手机地址及手机显示的完整证书指纹，然后输入两分钟有效的配对码。
- 在手机应用内普通测试框以及备忘录正文分别发送 `你好，小米 13 👋`，核对显示。
- 验证 Enter、Backspace、四个方向键；测试密码框，确认内容不变且 Mac 显示拒绝。
- 断开后留空配对码重连；撤销配对后确认旧 Mac 无法再输入；停止服务后确认连接失效。
- 在 HyperOS 切换到其他应用后确认前台接收服务仍工作；如系统限制后台运行，按 README 调整该应用的电池设置。
