import java.util.Base64
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val ocrTestApp = (project.findProperty("dart-defines") as? String)
    ?.split(",")?.any { String(Base64.getDecoder().decode(it)) == "OCR_TEST_APP=true" } == true
val signingProperties = Properties()
val signingPropertiesFile = file(
    "${System.getProperty("user.home")}/StoreFlow-Signing/key.properties"
)

if (signingPropertiesFile.isFile) {
    FileInputStream(signingPropertiesFile).use {
        signingProperties.load(it)
    }
}
android {
    namespace = "com.expiry_tracker.expiry_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // Device integration tests use a disposable app, keeping employee drafts safe.
        applicationId = if (ocrTestApp)
            "com.expiry_tracker.expiry_tracker.ocrtest" else "com.expiry_tracker.expiry_tracker"
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
        if (signingPropertiesFile.isFile) {
            create("storeflowRelease") {
                storeFile = file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            if (signingPropertiesFile.isFile) {
                signingConfig = signingConfigs.getByName("storeflowRelease")
            }
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

