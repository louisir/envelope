import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningPropertiesFile = rootProject.file("key.properties")
val releaseSigningProperties = Properties()
if (releaseSigningPropertiesFile.exists()) {
    FileInputStream(releaseSigningPropertiesFile).use {
        releaseSigningProperties.load(it)
    }
}
val hasReleaseSigningConfig = releaseSigningPropertiesFile.exists()
val wantsReleaseBuild = gradle.startParameter.taskNames.any {
    it.lowercase().contains("release")
}
val dartDefines = (project.findProperty("dart-defines") as? String)
    ?.split(",")
    ?.mapNotNull { encoded ->
        runCatching {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        }.getOrNull()
    }
    ?.toSet()
    ?: emptySet()
val adbBridgeEnabled = "ENVELOPE_ADB_BRIDGE=true" in dartDefines

android {
    namespace = "com.westwardsoft.envelope"
    compileSdk = flutter.compileSdkVersion
    buildToolsVersion = "36.1.0"
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.westwardsoft.envelope"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "ENVELOPE_ADB_BRIDGE", adbBridgeEnabled.toString())
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigningConfig) {
                val storeFileValue = releaseSigningProperties["storeFile"]?.toString()
                    ?: throw GradleException("Missing storeFile in android/key.properties")
                storeFile = rootProject.file(storeFileValue)
                storePassword = releaseSigningProperties["storePassword"]?.toString()
                    ?: throw GradleException("Missing storePassword in android/key.properties")
                keyAlias = releaseSigningProperties["keyAlias"]?.toString()
                    ?: throw GradleException("Missing keyAlias in android/key.properties")
                keyPassword = releaseSigningProperties["keyPassword"]?.toString()
                    ?: throw GradleException("Missing keyPassword in android/key.properties")
            }
        }
    }

    buildTypes {
        release {
            if (!hasReleaseSigningConfig && wantsReleaseBuild) {
                throw GradleException(
                    "Missing Android release signing config. Run scripts/init-android-release-signing.ps1 first."
                )
            }
            signingConfig = signingConfigs.getByName(
                if (hasReleaseSigningConfig) "release" else "debug"
            )
        }
    }
}

dependencies {
    implementation("androidx.biometric:biometric:1.1.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
