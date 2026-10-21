# Salah Companion app (Flutter)

The Android app shell. Prayer logic lives in the pure-Dart package
[`../packages/salah_core`](../packages/salah_core), which this app depends on.

## Build prerequisites

| Tool | Version used | Notes |
| --- | --- | --- |
| Flutter | 3.47.7 (Dart 3.13.5) | `flutter config --android-sdk <sdk>` |
| JDK | 17 or newer (21 tested) | Gradle 9.3.1 wrapper, AGP 9.1.0, Kotlin 2.4.0 |
| Python | 3.8 or newer (standard library only) | Generates the placeholder audio |
| Android SDK | platform `android-36`, build-tools `36.0.0`, platform-tools, NDK `28.2.13676358` | Flutter 3.47's defaults (compileSdk/targetSdk 36) |

Install the SDK with the command-line tools, for example into `/opt/android-sdk`:

```
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358"
flutter config --android-sdk /opt/android-sdk
flutter doctor --android-licenses
```

Network needed by the first build: `maven.google.com`/`dl.google.com` (AGP, CameraX,
MediaPipe), Maven Central, the Gradle plugin portal (Flutter's own Gradle plugin is built
from source with `kotlin-dsl`), and `storage.googleapis.com` for the pose model.

**Pose model.** `pose_landmarker_lite.task` (MediaPipe, float16 v1, 5.8 MB, Apache 2.0) is
not committed. The Gradle task `downloadPoseModel` fetches the pinned file, checks its
SHA-256 and packages it (uncompressed) as the asset `pose_landmarker.task`. Options:
`-PposeModel=full` (9.4 MB, more accurate, slower) and, for offline builds,
`-PposeModelFile=/path/to/pose_landmarker_lite.task`. With `flutter build`, pass them as
`ORG_GRADLE_PROJECT_poseModel=full` etc. in the environment.

**Placeholder audio.** The placeholder tones (`assets/audio/placeholder/*.wav`) and
`assets/audio/silence_10s.wav` are generated, not committed (only `catalog.json` is). After
cloning, run once from the repository root:

```
python3 scripts/make_placeholder_audio.py
```

The Android build does this by itself when the files are missing (Gradle task
`makePlaceholderAudio`, before the assets are bundled), and `test/content_assets_test.dart`
runs it if needed, but `flutter test` and `flutter run` need the files in place before the
asset bundle is built, so run the command first. See
[`../assets/audio/README.md`](../assets/audio/README.md).

## Run

```
python3 scripts/make_placeholder_audio.py   # once after cloning (repository root)
cd app
flutter pub get
flutter run            # on a connected Android phone
flutter test
flutter analyze
flutter build apk --release   # -> build/app/outputs/flutter-apk/app-release.apk
flutter build apk --release --split-per-abi   # one APK per ABI (arm64 ~40 MB)
(cd android && ./gradlew :app:testDebugUnitTest)   # Kotlin JVM tests (pose math, heartbeat, device channel)
flutter run --dart-define=DEMO=true   # scripted demo services: no camera, no audio
```

`./gradlew testDebugUnitTest` without `:app:` also runs the plugins' own tests;
shared_preferences_android's Robolectric test downloads an Android jar at test time and
fails offline. Phone testing: [`../docs/TESTING-ON-PHONE.md`](../docs/TESTING-ON-PHONE.md).

## How the app is wired

`lib/main.dart` uses `RealServices` (`lib/src/services/real_services.dart`) on Android,
and `DemoServices` (scripted fakes) with `--dart-define=DEMO=true` or on any other
platform. The UI talks only to the seams in `lib/src/services/seams.dart`:

| Seam | Real implementation |
| --- | --- |
| `SessionRunner` | `PoseSessionRunner`: `AndroidPoseEngine` -> `RuleBasedClassifier` -> `MajoritySmoother` -> `SalahStateMachine(prayer:)` (the prayer chosen on Home) -> `SessionController` (with its `FrameRateMonitor` fed every frame) -> `JustAudioRecitationPlayer`, plans from `ContentRepository(AssetAudioCatalog)`. Interruptions: the player's (headphones, audio focus), pose engine errors, the app lifecycle (hidden/paused), and cancel. Saves `settingsAfterSession(clock())` after a completed session (the Auto pair moves on once per calendar day). |
| `PlacementCheck` | `PosePlacementCheck` + `PlacementEvaluator` (`pose_placement_check.dart`, thresholds and the floor-space heuristic documented there), preview `PosePreview`. |
| `SurahNames`, `TodaysSurahs` | `ManifestSurahNames`, `ContentRepository.surahsFor` |
| `AudioCheck` | `DeviceAudioCheck`: MethodChannel `salah_companion/device` (`DeviceChannel.kt`): STREAM_MUSIC volume and a connected Bluetooth A2DP output |
| `CameraPermission` | `EngineCameraPermission` (the pose engine's `cameraPermission` method) |
| `Prompter` | `NoSpeechPrompter` (no spoken prompts yet; Android TTS would need an offline-only voice check) |
| `ScreenControl` | `DeviceScreenControl` (wakelock_plus, screen_brightness) |
| `SettingsStore` | `SharedPrefsSettingsStore` |

One `AndroidPoseEngine` serves both the placement check and the session. The placement
screen stops its check (and hides the preview) before the prayer screen opens, and the
session waits 300 ms before opening the camera, so only one of them holds it.

Release check (run by hand before every release; CI is not set up yet). The permissions
must be exactly `CAMERA`, `WAKE_LOCK` and androidx's
`in.kukoo.salah_companion.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` (declared and used);
`INTERNET` or `ACCESS_NETWORK_STATE` appearing fails the release:

```
$ANDROID_HOME/build-tools/36.0.0/aapt2 dump permissions build/app/outputs/flutter-apk/app-release.apk
```

## Pose engine (Android)

`lib/src/pose/android_pose_engine.dart` (`AndroidPoseEngine implements PoseEngine`) talks to
Kotlin in `android/app/src/main/kotlin/in/kukoo/salah_companion/pose/`:

- **Camera:** CameraX, the lens from `CameraConfig.lens` (`SessionSettings.camera`: back
  camera by default, or front; the widest back lens for `CameraLens.rearUltraWide`). A
  missing facing falls back to the other one, and the `started` event reports the lens
  actually opened (`AndroidPoseEngine.activeLens`). `ImageAnalysis` at 480x640 portrait, RGBA, `STRATEGY_KEEP_ONLY_LATEST`, AE fps range chosen
  to hold 15 fps (`[15,15]` preferred) and paced to 15 fps by sensor timestamp.
- **Pose:** MediaPipe Tasks `PoseLandmarker` 0.10.35, `LIVE_STREAM`, `numPoses = 3`, GPU
  delegate first, CPU if the GPU delegate fails to load or errors before the first frame.
- **Frames:** each buffer is rotated upright before inference, so landmarks come back in
  pixels of the upright, unmirrored frame, for both lenses (analysis buffers are never
  mirrored; a front sensor is usually mounted at 270 degrees, a back one at 90, and
  `rotationDegrees` covers both). Only the front preview is mirrored (`PreviewView`), and
  the placement overlay mirrors the skeleton to match. `conf` is MediaPipe's per-landmark `visibility`.
  `z` is MediaPipe's z times the image width. `tMs` is the sensor timestamp minus the first
  analysed frame's. `tiltDeg` is the accelerometer roll relative to that first frame
  (positive = counter-clockwise, seen from the screen). Every detected person is in
  `people`; `landmarks` is set only when exactly one is.
- **Heartbeats:** exactly SPEC section 5's rule (`HeartbeatScheduler.kt`). "100 ms with no
  frame" is measured on delivery time plus a 50 ms latency guard; a frame that would arrive
  after a heartbeat with a later stamp is dropped, so the stream is always ordered.
- **Wire:** frames and heartbeats are Float32 lists (format in `PoseWire.kt` and
  `lib/src/pose/pose_wire.dart`, tested against shared golden vectors); errors and
  diagnostics are small maps. Each event carries the Dart session token.
- **Errors:** permission denied, camera in use/disabled/fatal, model load failure and
  similar arrive as a `PoseEngineError` stream error whose `interruption` is
  `Interruption.cameraUnavailable`; `paused` (activity stopped, i.e. no longer visible; camera released) maps to
  `Interruption.appBackgrounded`. A mere ON_PAUSE (a transparent dialog, the assistant,
  multi-window focus change) keeps the session, as Dart ignores `inactive`. The stream then closes.
- **Permission:** `AndroidPoseEngine.cameraPermission()` (a small MethodChannel;
  `permission_handler_android` 14 needs compileSdk 37). `start()` also requests it.
- **Preview:** `PosePreview` is a platform view (`AndroidView`) hosting CameraX's
  `PreviewView` in COMPATIBLE (TextureView) mode, shown only while a session runs. The SPEC
  mentions a native texture; a platform view was simpler and gets rotation and scaling from
  CameraX. No camera image reaches Dart either way.
- **No usage stats:** MediaPipe Tasks normally logs usage via Google `datatransport`
  (`RemoteLoggingClient`). That library is excluded in `android/app/build.gradle.kts` and
  replaced with no-op classes in `android/app/src/main/java/com/google/android/datatransport/`.
  If a MediaPipe upgrade needs more of that API, the release build fails in R8.

## Privacy rules built into the Android project

- `android/app/src/release/AndroidManifest.xml` strips `INTERNET` and
  `ACCESS_NETWORK_STATE` from release builds. Debug builds keep `INTERNET` only for
  Flutter's development tools.
- Backup and device transfer of app data are off (`allowBackup="false"`,
  `res/xml/data_extraction_rules.xml`).
- `minSdk` is 26.
- The only runtime permission is `CAMERA` (`uses-feature android.hardware.camera`).

The launcher icon is a placeholder vector (no image files yet).
