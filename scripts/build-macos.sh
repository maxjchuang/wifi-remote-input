#!/bin/sh
set -eu
cd "$(dirname "$0")/../macos"
swift build -c release --product WiFiRemoteInput
APP="$PWD/build/WiFi Remote Input.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset
swiftc Sources/RemoteCore/AppIcon.swift ../scripts/render-icon.swift -o build/render-icon
build/render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/WiFiRemoteInput "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.wifiremote.mac</string>
<key>CFBundleName</key><string>WiFi Remote Input</string>
<key>CFBundleExecutable</key><string>WiFiRemoteInput</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.5</string>
<key>CFBundleVersion</key><string>605</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSCameraUsageDescription</key><string>扫描 Android 手机上的配对二维码，自动建立安全连接。画面仅在本机识别。</string>
<key>NSLocalNetworkUsageDescription</key><string>Connect to your paired Android keyboard over local Wi-Fi.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
