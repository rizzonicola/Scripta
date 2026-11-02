import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing credentials are never stored in the repository. They are read
// from android/key.properties (ignored by git), which CI generates from secrets.
// For F-Droid builds the signing configuration is removed by fdroidserver.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "cc.poppi.scripta"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "cc.poppi.scripta"
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Never fall back to the debug key for a release build. If
            // key.properties is missing, the APK is left unsigned (F-Droid
            // removes this block and signs the APK itself).
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}

flutter {
    source = "../.."
}

// CI sets this to fail fast when a tagged release would be built without the
// release keystore. F-Droid does not set it, because it signs the APK itself.
if (System.getenv("SCRIPTA_REQUIRE_RELEASE_SIGNING") == "1") {
    gradle.taskGraph.whenReady {
        val wantsRelease = allTasks.any {
            it.name.contains("Release", ignoreCase = true) && it.project.name == "app"
        }
        if (wantsRelease && !keystorePropertiesFile.exists()) {
            throw GradleException(
                "Release build without signing credentials: create android/key.properties " +
                    "(storeFile, storePassword, keyAlias, keyPassword) or run the debug build."
            )
        }
    }
}

