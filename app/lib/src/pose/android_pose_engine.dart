/// The Android [PoseEngine]: CameraX + MediaPipe Pose Landmarker in Kotlin
/// (`android/app/src/main/kotlin/in/kukoo/salah_companion/pose/`), bridged over
/// platform channels. Only landmark numbers cross to Dart; camera images never do.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:salah_core/salah_core.dart';

import 'pose_wire.dart';

export 'pose_wire.dart' show PoseEngineError;

/// Asks for (or checks) the camera permission. Returns whether it is granted.
/// Injected in tests; the default is [AndroidPoseEngine.cameraPermission].
typedef CameraPermissionRequest = Future<bool> Function();

class AndroidPoseEngine implements PoseEngine {
  static const MethodChannel defaultMethodChannel = MethodChannel(
    'salah_companion/pose',
  );
  static const EventChannel defaultEventChannel = EventChannel(
    'salah_companion/pose/events',
  );

  final MethodChannel _methods;
  final EventChannel _events;
  final CameraPermissionRequest? _permissionOverride;

  /// Try MediaPipe's GPU delegate first (falls back to CPU natively).
  final bool preferGpu;

  int _nextToken = 0;
  int? _activeToken;
  StreamSubscription<Object?>? _subscription;
  StreamController<PoseFrame>? _controller;

  /// The latest diagnostics from the native side (lens, fps range, analysis size,
  /// delegate). For logs and the placement check; never needed by prayer logic.
  final Map<String, Object?> info = {};

  /// The camera the native side actually opened for the current session
  /// (from its `started` event), or null until it reports. It differs from
  /// the requested [CameraConfig.lens] only when the phone lacks that camera
  /// and the other one was used instead. Landmarks are in the upright,
  /// unmirrored frame for every lens; this is only for display (the overlay
  /// is mirrored to match a front-camera preview) and diagnostics.
  final ValueNotifier<CameraLens?> activeLens = ValueNotifier(null);

  /// Maps a native `lens` label to a [CameraLens] (unknown labels: rear).
  static CameraLens lensFromWire(Object? label) => switch (label) {
    'front' => CameraLens.front,
    'rearUltraWide' => CameraLens.rearUltraWide,
    _ => CameraLens.rear,
  };

  AndroidPoseEngine({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    CameraPermissionRequest? requestPermission,
    this.preferGpu = true,
  }) : _methods = methodChannel ?? defaultMethodChannel,
       _events = eventChannel ?? defaultEventChannel,
       _permissionOverride = requestPermission;

  /// Checks the camera permission and, if [request] is true and it is not
  /// granted yet, shows the system dialog. Returns whether it is granted.
  /// Call this from the setup screen first (docs/SPEC.md section 3);
  /// [start] calls it again with `request: true`.
  Future<bool> cameraPermission({bool request = true}) async {
    try {
      return await _methods.invokeMethod<bool>('cameraPermission', {
            'request': request,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Starts the camera and emits a [PoseFrame] per analysed camera frame plus
  /// heartbeats (docs/SPEC.md section 5).
  ///
  /// A failure (permission denied, camera in use or disabled, model load error,
  /// app paused) arrives as a stream error of type [PoseEngineError], whose
  /// [PoseEngineError.interruption] is [Interruption.cameraUnavailable] (or
  /// [Interruption.appBackgrounded] for `paused`); the stream then closes and
  /// the camera is already released. Cancelling the subscription stops the
  /// engine. Starting again stops the previous session first.
  @override
  Stream<PoseFrame> start(CameraConfig config) {
    final previous = _controller;
    if (previous != null) {
      _teardown();
      unawaited(_invokeStop());
      unawaited(previous.close());
    }
    final token = ++_nextToken;
    activeLens.value = null;
    late final StreamController<PoseFrame> controller;
    controller = StreamController<PoseFrame>(
      onListen: () => _begin(token, config, controller),
      onCancel: () async {
        if (_activeToken == token) await stop();
      },
    );
    _controller = controller;
    _activeToken = token;
    return controller.stream;
  }

  Future<void> _begin(
    int token,
    CameraConfig config,
    StreamController<PoseFrame> c,
  ) async {
    bool granted;
    try {
      final override = _permissionOverride;
      granted = override != null ? await override() : await cameraPermission();
    } catch (_) {
      granted = false;
    }
    if (_activeToken != token) return;
    if (!granted) {
      _fail(
        token,
        c,
        const PoseEngineError('permissionDenied', 'Camera permission denied'),
      );
      return;
    }
    _subscription = _events.receiveBroadcastStream().listen(
      (event) => _onEvent(token, c, event),
      onError: (Object e) => _fail(
        token,
        c,
        PoseEngineError('cameraUnavailable', 'Event channel error: $e'),
      ),
    );
    try {
      await _methods.invokeMethod<void>('start', {
        'token': token,
        'width': config.width,
        'height': config.height,
        'fps': config.fps,
        'lens': config.lens.name,
        'preferGpu': preferGpu,
      });
    } on PlatformException catch (e) {
      _fail(token, c, PoseEngineError(e.code, e.message ?? ''));
    } on MissingPluginException catch (e) {
      _fail(token, c, PoseEngineError('cameraUnavailable', '$e'));
    }
  }

  void _onEvent(int token, StreamController<PoseFrame> c, Object? event) {
    if (_activeToken != token) return;
    final PoseWireEvent decoded;
    try {
      decoded = PoseWireDecoder.decode(event);
    } on FormatException {
      return; // Never let one bad event end a prayer session.
    }
    if (decoded.token != token) return; // From an earlier session.
    switch (decoded) {
      case PoseWireFrame(:final frame):
        c.add(frame);
      case PoseWireError(:final error):
        _fail(token, c, error);
      case PoseWireInfo(:final event, :final data):
        info.addAll(data);
        if (event == 'started') activeLens.value = lensFromWire(data['lens']);
    }
  }

  void _fail(int token, StreamController<PoseFrame> c, PoseEngineError error) {
    if (_activeToken != token) return;
    _teardown();
    unawaited(_invokeStop()); // Native side already stopped; harmless.
    if (!c.isClosed) {
      c.addError(error);
      unawaited(c.close());
    }
  }

  void _teardown() {
    _activeToken = null;
    _controller = null;
    final sub = _subscription;
    _subscription = null;
    if (sub != null) unawaited(sub.cancel());
  }

  Future<void> _invokeStop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } on PlatformException {
      // Nothing to release.
    } on MissingPluginException {
      // Not on Android.
    }
  }

  /// Stops the camera and closes the frame stream.
  @override
  Future<void> stop() async {
    final c = _controller;
    _teardown();
    await _invokeStop();
    if (c != null && !c.isClosed) await c.close();
  }
}
