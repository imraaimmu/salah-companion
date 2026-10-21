import java.net.URI
import java.security.MessageDigest

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "in.kukoo.salah_companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "in.kukoo.salah_companion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26 // adaptive icon only; MediaPipe needs 24+
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    androidResources {
        // MediaPipe memory-maps the model; keep it uncompressed in the APK.
        noCompress += "task"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
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

// MediaPipe Tasks pulls in Google datatransport only to upload usage statistics
// (RemoteLoggingClient). It is replaced by the no-op classes in
// src/main/java/com/google/android/datatransport so nothing is queued or sent
// (docs/SPEC.md section 8, "No data collection").
configurations.configureEach {
    exclude(group = "com.google.android.datatransport")
}

dependencies {
    val camerax = "1.6.2"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")
    // Pinned exactly (strictly): the datatransport stand-ins match this version's
    // RemoteLoggingClient (checked by DatatransportStubsTest). Upgrade deliberately.
    implementation("com.google.mediapipe:tasks-vision") { version { strictly("0.10.35") } }
    implementation("com.google.mediapipe:tasks-core") { version { strictly("0.10.35") } }

    testImplementation("junit:junit:4.13.2")
}

// ---- Pose model ------------------------------------------------------------------------
// The MediaPipe model is not committed. It is downloaded once at build time (pinned version,
// SHA-256 checked) into build/generated/poseModel/assets and packaged as the Android asset
// `pose_landmarker.task`. Choose with -PposeModel=lite|full (default lite). For offline
// builds, pass -PposeModelFile=/path/to/pose_landmarker_<variant>.task (still SHA-checked).

data class PoseModel(val url: String, val sha256: String)

val poseModels = mapOf(
    "lite" to PoseModel(
        "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task",
        "59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a",
    ),
    "full" to PoseModel(
        "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task",
        "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1",
    ),
)

abstract class DownloadPoseModel : DefaultTask() {
    @get:Input abstract val url: Property<String>
    @get:Input abstract val sha256: Property<String>
    @get:Input @get:Optional abstract val localFile: Property<String>
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun run() {
        val out = outputDir.file("pose_landmarker.task").get().asFile
        val want = sha256.get()
        if (out.exists() && sha(out) == want) return
        out.parentFile.mkdirs()
        val tmp = File(out.parentFile, "pose_landmarker.task.part")
        val local = localFile.orNull
        if (local != null) {
            File(local).copyTo(tmp, overwrite = true)
        } else {
            logger.lifecycle("Downloading pose model ${url.get()}")
            URI(url.get()).toURL().openStream().use { input ->
                tmp.outputStream().use { input.copyTo(it) }
            }
        }
        val got = sha(tmp)
        if (got != want) {
            tmp.delete()
            throw GradleException("Pose model SHA-256 mismatch: got $got, want $want")
        }
        if (!tmp.renameTo(out)) {
            tmp.copyTo(out, overwrite = true)
            tmp.delete()
        }
    }

    private fun sha(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}

val poseModelName = (findProperty("poseModel") as String?) ?: "lite"
val poseModel = poseModels[poseModelName]
    ?: throw GradleException("poseModel must be one of ${poseModels.keys}, was $poseModelName")

val downloadPoseModel = tasks.register<DownloadPoseModel>("downloadPoseModel") {
    url.set(poseModel.url)
    sha256.set(poseModel.sha256)
    (findProperty("poseModelFile") as String?)?.let { localFile.set(it) }
    outputDir.set(layout.buildDirectory.dir("generated/poseModel/assets"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(downloadPoseModel, DownloadPoseModel::outputDir)
    }
}

// ---- Placeholder audio -----------------------------------------------------------------
// The placeholder tones and silence (app/assets/audio, see assets/audio/README.md) are
// generated, not committed. Like the pose model, they are produced at build time when
// missing: scripts/make_placeholder_audio.py --if-missing (Python 3 standard library only;
// deterministic output; does nothing when every file exists). It must run before Flutter
// bundles its assets (compileFlutterBuild*) and before Android merges assets.

val repoRoot = rootProject.projectDir.parentFile.parentFile
val makePlaceholderAudio = tasks.register<Exec>("makePlaceholderAudio") {
    description = "Generates the placeholder audio assets if any are missing."
    workingDir = repoRoot
    commandLine("python3", "scripts/make_placeholder_audio.py", "--if-missing")
}

tasks.configureEach {
    if (name.startsWith("compileFlutterBuild") ||
        (name.startsWith("merge") && name.endsWith("Assets"))
    ) {
        dependsOn(makePlaceholderAudio)
    }
}
