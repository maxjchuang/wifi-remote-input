# Third-party notices

Project source: AGPL-3.0-only. No source has been copied from the reference Bluetooth or WiFi keyboard projects.

Runtime dependencies (resolved by Gradle; original notices remain in their distributions):

- ZXing core 3.5.3, ZXing authors: Apache-2.0; used to generate pairing QR codes.
- Kotlin standard library, JetBrains: Apache-2.0.
- Java-WebSocket 1.6.0, TooTallNate and contributors: MIT.
- SLF4J 2.0.16, QOS.ch: MIT; the no-op backend intentionally suppresses transport-library logging.
- Bouncy Castle (`bcpkix` 1.80; `bcprov` and `bcutil` 1.80.2), Legion of the Bouncy Castle: Bouncy Castle License (MIT-style).

Build/test dependencies include Gradle and Android Gradle Plugin (Apache-2.0), JUnit 4 (EPL-1.0), Robolectric (MIT), and JSON-java (public domain). macOS uses Apple system frameworks and Swift standard libraries without bundled third-party code.
