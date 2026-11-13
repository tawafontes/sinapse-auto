plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.synapseauto.synapse_auto"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.synapseauto.synapse_auto"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// R4.3-R2.6.22-INT: androidx.camera:camera-video 1.6.2 is replaced by the same release plus the
// F2 patch, rebuilt from the official sources by third_party/androidx_camera_video_f2/build.sh.
// On Android 13 a video codec released while only configured leaves its C2OMXNode thread alive
// for the rest of the process (one per segment rotation, session STOP, HOME/return, aborted
// START); F2 makes EncoderImpl hand its persistent input surface to the next video encoder, which
// frees that node. Only this module and only at exactly 1.6.2: the camera plugin and every other
// CameraX module stay upstream. Provenance, verification and removal: that folder's README.md.
repositories {
    exclusiveContent {
        forRepository {
            maven {
                name = "cameraVideoF2"
                url = uri(rootProject.file("../third_party/androidx_camera_video_f2/maven"))
            }
        }
        filter { includeModule("com.synapseauto.thirdparty.androidx.camera", "camera-video") }
    }
}

// Dashcam dual camera phase 0 (DualCameraProbe.kt): the app's own Kotlin compiles against
// CameraX's concurrent camera API. The same modules, at the same 1.6.2, the camera plugin
// already brings in (and camera-video still resolves to F2, by the substitution below) — they
// are declared only to be on the app's compile classpath, not added to the build.
dependencies {
    implementation("androidx.camera:camera-core:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-video:1.6.2")
}

configurations.configureEach {
    resolutionStrategy.dependencySubstitution {
        substitute(module("androidx.camera:camera-video:1.6.2"))
            .using(module("com.synapseauto.thirdparty.androidx.camera:camera-video:1.6.2-synapse-f2"))
            .because("R4.3-R2.6.22-INT: camera-video 1.6.2 + F2 (third_party/androidx_camera_video_f2)")
    }
}
