import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.javp.javp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.javp.javp"
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    flavorDimensions += "distribution"
    productFlavors {
        // Public APK channel (updater.javp.app) — self-update + REQUEST_INSTALL_PACKAGES.
        create("sideload") {
            dimension = "distribution"
            isDefault = true
        }
        // Dev sideload channel (updater.javp.app/dev) — side-by-side with stable.
        // Still JAVP_DISTRIBUTION=sideload so self-update stays enabled.
        create("sideloadDev") {
            dimension = "distribution"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
        }
        // Google Play AAB — no self-update permission; updates via Play only.
        create("play") {
            dimension = "distribution"
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Prefer upload/release keystore when android/key.properties exists;
            // otherwise keep debug signing so local `flutter run --release` still works.
            // CI / publish sets JAVP_REQUIRE_RELEASE_SIGNING=1 so we never ship a
            // fresh Android Debug cert (breaks in-app updates across runners).
            val requireReleaseSigning =
                System.getenv("JAVP_REQUIRE_RELEASE_SIGNING") == "1"
            signingConfig = when {
                keystorePropertiesFile.exists() ->
                    signingConfigs.getByName("release")
                requireReleaseSigning ->
                    throw GradleException(
                        "JAVP_REQUIRE_RELEASE_SIGNING=1 but android/key.properties is missing. " +
                            "See docs/play-store.md (Release signing) and ANDROID_KEYSTORE_* secrets.",
                    )
                else -> signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
    implementation("androidx.mediarouter:mediarouter:1.7.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
}

flutter {
    source = "../.."
}
