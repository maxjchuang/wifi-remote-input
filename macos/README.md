# macOS client

Swift Package with a SwiftUI executable and shared `RemoteCore` transport. Build the app bundle with `../scripts/build-macos.sh` from this directory, or open Package.swift in Xcode. macOS 13+.

`RemoteCore` pins the full Android certificate SHA-256 and stores the device credential in Keychain. The `Smoke` executable uses this same transport for local cross-language tests. No Bluetooth transport or global input capture in this MVP.
