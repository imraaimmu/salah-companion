/// Small Android-backed seams: the audio check and the camera permission.
library;

import 'package:flutter/services.dart';

import '../pose/android_pose_engine.dart';
import 'seams.dart';

/// The media output check (docs/SPEC.md setup step 6) over the
/// `salah_companion/device` MethodChannel in MainActivity:
/// `audioStatus` -> `{volume, maxVolume, bluetoothA2dp}` from
/// `AudioManager.getStreamVolume(STREAM_MUSIC)` and the connected outputs.
class DeviceAudioCheck implements AudioCheck {
  static const MethodChannel defaultChannel = MethodChannel(
    'salah_companion/device',
  );

  final MethodChannel _channel;

  DeviceAudioCheck([MethodChannel? channel])
    : _channel = channel ?? defaultChannel;

  @override
  Future<AudioStatus> check() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('audioStatus');
      if (m == null) return const AudioStatus();
      final volume = m['volume'];
      return AudioStatus(
        volumeAboveZero: volume is! int || volume > 0,
        bluetooth: m['bluetoothA2dp'] == true,
      );
    } on PlatformException {
      return const AudioStatus(); // Unknown: never block Start on it.
    } on MissingPluginException {
      return const AudioStatus();
    }
  }
}

/// Camera permission through the pose engine's `cameraPermission` method.
class EngineCameraPermission implements CameraPermission {
  final AndroidPoseEngine engine;
  const EngineCameraPermission(this.engine);

  @override
  Future<bool> isGranted() => engine.cameraPermission(request: false);

  @override
  Future<bool> request() => engine.cameraPermission(request: true);
}

/// Spoken placement prompts are not wired yet: Android TextToSpeech would
/// need an offline-only voice check, so the placement screen shows its
/// prompts as text only for now.
class NoSpeechPrompter implements Prompter {
  const NoSpeechPrompter();

  @override
  Future<void> speak(String text) async {}
}
