#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
if [ -z "${JAVA_HOME:-}" ]; then
  export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
fi
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
swift test --package-path macos
swift build --package-path macos --product Smoke
export WRI_SWIFT_SMOKE="$ROOT/macos/.build/debug/Smoke"
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug --rerun-tasks
