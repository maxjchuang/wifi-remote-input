# Android receiver

Kotlin application, API 29+, SDK 35. See the root README for build/install instructions.

`RemoteIme` applies authenticated input on the main thread. `ReceiverService` owns a user-started foreground TLS WebSocket server. `Protocol` and `InputServer` are also exercised on the JVM with the production Swift client. `Identity` persists a self-signed TLS identity in private no-backup storage. No ADB, root, accessibility or cloud dependencies.
