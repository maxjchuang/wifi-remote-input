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

