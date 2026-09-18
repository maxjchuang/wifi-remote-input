// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WiFiRemoteInput", platforms: [.macOS(.v13)], products: [.executable(name: "WiFiRemoteInput", targets: ["WiFiRemoteInput"]), .executable(name: "Smoke", targets: ["Smoke"])], targets: [.target(name: "RemoteCore"), .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]), .executableTarget(name: "WiFiRemoteInput", dependencies: ["RemoteCore"]), .executableTarget(name: "Smoke", dependencies: ["RemoteCore"])])
