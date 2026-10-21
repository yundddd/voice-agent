plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.voiceagent.voice_agent"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // +238: extract native libs to nativeLibraryDir at install — the
    // ONLY place Android >= 10 will exec() from, and the espeak-ng
    // child process needs that. Costs a few MB of on-device storage,
    // buys the GPL boundary drawn at exec instead of at the linker.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.voiceagent.voice_agent"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // THE shipping identity, pinned to the vendored keystore (see
        // android/.gitignore for why it is committed). This is the same
        // certificate ~/.android/debug.keystore signed every installed
        // build with — the cert SHA-256 is in the commit that vendored
        // it — so any APK built here upgrades any app installed from
        // here, forever, regardless of this machine regenerating its
        // global debug key. Explicit credentials (not the "debug"
        // preset): the preset reads ~/.android, which is per-machine
        // and regenerable — that is exactly how a signature mismatch
        // (and a forced uninstall) creeps back in.
        create("release") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
