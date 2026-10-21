/// The production wiring of every seam (Android).
library;

import 'package:flutter/widgets.dart';
import 'package:salah_core/salah_core.dart';

import '../audio/asset_audio_catalog.dart';
import '../audio/just_audio_recitation_player.dart';
import '../audio/playback_backend.dart' show clearAudioAssetCache;
import '../pose/android_pose_engine.dart';
import '../pose/pose_preview.dart';
import 'app_services.dart';
import 'content_services.dart';
import 'device_services.dart';
import 'pose_placement_check.dart';
import 'pose_session_runner.dart';
import 'screen_control.dart';
import 'seams.dart';
import 'settings_stores.dart';

/// Real services: CameraX + MediaPipe pose engine, the salah_core pipeline,
/// just_audio recitation from the bundled catalog, a settings file
/// settings, and the device channels.
///
/// One [AndroidPoseEngine] is shared by the placement check and the prayer
/// session; the placement screen stops its check before the session starts,
/// so only one of them holds the camera at a time.
class RealServices {
  final AndroidPoseEngine engine;
  final ContentRepository content;
  final SettingsStore settingsStore;

  RealServices._(this.engine, this.content, this.settingsStore);

  /// Loads the audio catalog (a bundled asset) and builds the services.
  static Future<RealServices> load() async {
    // Temporary copies of bundled audio from an earlier run (possibly cut
    // short when the app was killed) are never reused.
    await clearAudioAssetCache();
    final catalog = await AssetAudioCatalog.load();
    return RealServices._(
      AndroidPoseEngine(),
      ContentRepository(catalog),
      ResilientSettingsStore(FileSettingsStore.android()),
    );
  }

  static Future<PlayerHandle> _createPlayer() async {
    final p = await JustAudioRecitationPlayer.create();
    return (player: p, interruptions: p.interruptions);
  }

  AppServices wrap({required Widget child}) => AppServices(
    settingsStore: settingsStore,
    surahNames: const ManifestSurahNames(),
    todaysSurahs: todaysSurahsFrom(content),
    sessionRunnerFactory: (settings, prayer) => PoseSessionRunner(
      settings: settings,
      prayer: prayer,
      engine: engine,
      planner: content,
      store: settingsStore,
      createPlayer: _createPlayer,
    ),
    // The lens comes from the settings: PlacementPage passes it to start()
    // and the session runner reads SessionSettings.cameraConfig.
    placementCheckFactory: () => PosePlacementCheck(
      engine: engine,
      activeLens: engine.activeLens,
      previewBuilder: (_) => const PosePreview(),
    ),
    prompter: const NoSpeechPrompter(),
    audioCheck: DeviceAudioCheck(),
    cameraPermission: EngineCameraPermission(engine),
    screenControl: const DeviceScreenControl(),
    child: child,
  );
}
