plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    packaging { resources.excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF" }
    namespace = "dev.wifiremote"
    compileSdk = 35
    defaultConfig { applicationId = "dev.wifiremote"; minSdk = 29; targetSdk = 35; versionCode = 2; versionName = "0.2.0" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    testOptions { unitTests.isIncludeAndroidResources = true }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    implementation("com.google.zxing:core:3.5.3")
    implementation("org.java-websocket:Java-WebSocket:1.6.0")
    implementation("org.slf4j:slf4j-nop:2.0.16")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.80")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250107")
}

dependencyLocking { lockAllConfigurations() }
