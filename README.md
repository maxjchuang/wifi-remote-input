# WiFi Remote Input

通过同一 Wi-Fi，将 Mac 上输入的 Unicode 文本（包括中文）发送到 Android 普通输入框。无需 USB 调试、ADB、Root、辅助功能权限或云端中转。

当前 MVP 包含 Kotlin Android 输入法及加密接收服务、SwiftUI macOS 客户端、扫码配对、一次性验证码与持久设备密钥，以及 Enter、Backspace、方向键。鼠标、全局快捷键和实体键盘直接捕获尚未实现；目前在 Mac 窗口中输入文本后点击发送。

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

## 小米 13 安装与首次使用

1. 将 APK 通过你信任的文件传输方式传到手机，用手机文件管理器打开安装；按系统提示仅为该文件来源允许安装。整个过程不需要开启开发者选项或 USB 调试。
2. 手机和 Mac 连接同一可信 Wi-Fi。访客网络/AP 隔离会阻止两端互连。
3. 打开 Android **WiFi Remote Input**，依次点击「启用输入法」「选择输入法」。在系统列表中启用并选中 WiFi Remote Input。系统可能提示输入法有读取输入的能力，这是 Android 对第三方输入法的标准提醒。
4. 点击「启动接收」，允许通知，待状态显示「接收中」后点击「显示配对二维码」。应用默认选择 Wi-Fi 地址；有多张网卡时，可在二维码窗口中点「更换地址」。
5. 在 Mac 打开新版 `.app`，点击 **「扫码配对」**，首次使用允许摄像头访问。将手机二维码对准 Mac 摄像头，识别后自动连接；无需填写地址、证书指纹或验证码。画面只在本机处理，不保存、不上传。
6. 二维码两分钟有效，只能使用一次。过期、已使用或重新生成后，旧二维码无法配对；失败时在手机重新生成再扫。二维码包含临时授权凭据，请只扫描自己手机应用内显示的码。
7. 在手机点击应用内「普通测试框」，或打开备忘录并点击正文；保持 WiFi Remote Input 为当前输入法。在 Mac 发送 `你好，小米 13 👋`，确认手机显示完整中文及 emoji。
8. 测试 Enter、Backspace 和方向键。再点击手机应用内密码测试框，确认 Mac 显示「密码输入框禁止远程输入」，且手机内容未变。

Mac 无摄像头或未授权时，可展开「手动配对 / 连接设置」。手机「显示 / 隐藏手动配对信息」提供地址和完整指纹，二维码窗口提供八位备用码；填写后点击「手动连接 / 配对」。验证码最多允许五次错误尝试，之后需在手机重新生成。

之后点击 Mac「连接已配对手机」即可，地址、指纹和设备密钥会保留。手机地址改变时可以重新扫码。MVP 同时只配对一台 Mac；重新配对会撤销旧密钥。手机「撤销已配对 Mac」使旧会话及后续认证失效，「停止接收」关闭端口。Mac「忘记设备」清除本机 Keychain 项。

HyperOS 如在切换应用后中止接收服务，可在应用电池设置中允许其后台运行；保留前台通知。锁屏时拒绝输入。完成使用后可在输入法面板切回原输入法并停止接收。

## 验证

```sh
# 从项目根目录运行 Swift ↔ Kotlin 实际 TLS/WebSocket 互通测试
./scripts/test.sh
```

测试包含协议错误、认证失败、未配对输入、验证码过期/单次使用/跨连接猜测上限、密钥撤销、消息大小与频率限制、所有密码框变体拒绝、Android InputConnection 中文提交和按键/编辑器动作，以及证书指纹不符拒绝。

互通测试会在本机临时启动**与 Android 相同的接收服务代码**，由真正的 Swift URLSession 客户端配对、重新认证并发送中文和六种按键；仅使用本机回环，不接触手机。Robolectric 测试执行 Android IME 到 InputConnection 的调用。这些验证不能替代小米 13/HyperOS 的实际输入框验收，手机安装、输入法启用和最终中文显示需要在实机操作。

## 安全与范围

仅提供固定证书的 TLS 1.3 WebSocket；未认证不能输入。密码、可见密码、网页密码和数字密码框均拒绝远程文本及按键。输入框保护依赖目标应用正确声明 Android `inputType`；无法识别故意伪装成普通文本的密码控件。日志不记录输入内容、剪贴板、配对码或密钥。应用不请求辅助功能权限。

连接中断时不自动重发，以免重复输入；需检查手机后重连。扫码会自动导入完整证书指纹；手动填写保留为备用方式。没有公网服务、自动发现或后台开机自启动。

架构见 [docs/architecture.md](docs/architecture.md)，完整线协议见 [protocol/README.md](protocol/README.md)，本次本机验证结果见 [docs/validation.md](docs/validation.md)。

## License

AGPL-3.0-only，见 [LICENSE](LICENSE)。本 MVP 没有复制参考项目的源代码；第三方依赖及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。未来复用代码时须保留原始版权及许可证声明。
