import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firma di release: le credenziali NON stanno nel repository. Vengono lette da
// android/key.properties (ignorato da git), che in CI viene generato dai
// secret (vedi .github/workflows/android_release.yml):
//   storeFile=/percorso/upload-keystore.jks
//   storePassword=...
//   keyAlias=...
//   keyPassword=...
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "io.github.scripta"
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
        applicationId = "io.github.scripta"
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
            // MAI la chiave di debug: chiunque può firmare un APK con essa,
            // quindi un APK "release" firmato in debug è aggiornabile/
            // sostituibile da terzi. Senza key.properties la build di release
            // fallisce (vedi il controllo sotto) invece di ricadere in debug.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

// Fallisce subito e in modo esplicito se si tenta una build di release senza
// credenziali di firma, invece di produrre un APK non firmato / firmato male.
gradle.taskGraph.whenReady {
    val wantsRelease = allTasks.any { it.name.contains("Release", ignoreCase = true) && it.project.name == "app" }
    if (wantsRelease && !keystorePropertiesFile.exists()) {
        throw GradleException(
            "Build di release senza firma: crea android/key.properties " +
                "(storeFile, storePassword, keyAlias, keyPassword). " +
                "Per provare l'app usa una build debug."
        )
    }
}
