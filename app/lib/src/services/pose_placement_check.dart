/// The real [PlacementCheck] (docs/SPEC.md "Placing the phone"): runs the
/// pose engine and the classifier and scores each frame with
/// [PlacementEvaluator].
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:salah_core/salah_core.dart';

import '../pose/pose_wire.dart' show PoseEngineError;
import 'latest_value.dart';
import 'seams.dart';

/// Scores engine output for the placement screen. Pure: feed it frames
/// (camera frames and heartbeats, in order) with [add].
///
/// * **bodyVisible**: a person is detected whose head (nose, eyes or ears)
///   and near-side shoulder, hip, knee and ankle (or heel) are seen with
///   confidence >= [minPointConf] and lie inside the frame, with the head
///   below the top edge and the feet above the bottom edge.
/// * **confidenceOk**: the near side's shoulder, hip, knee and ankle average
///   a confidence >= [minMeanConf] (0.7) continuously for [holdMs] (3 s) of
///   sensor time.
/// * **fpsOk**: at least [minFps] camera frames per second over the last
///   [holdMs] (3 s), once 3 s have passed. Heartbeats do not count. The
///   spec asks for 15 fps; [minFps] defaults to 14.5 so a camera paced at
///   exactly 15 fps that drops or jitters by one frame in the 3 s window
///   still passes (44 frames needed in 3 s instead of 45).
/// * **floorSpaceOk** (heuristic): while the classifier reads the user as
///   standing, the frame must show at least [floorFactor] (0.2) x the
///   user's height in landmarks (highest head point to lowest foot point) of
///   floor in front of the toes, in the direction the user faces. The
///   maintainer chose 0.2 so the check is easy to pass. In a full sujood the
///   head lands about 0.65-0.75 x height ahead of the toes, so with only 0.2
///   it may leave the frame; then sujood can go unseen and the prayer logic
///   stays silent for that rak'ah (a missed recitation, never a wrong one).
///   The facing direction comes from the nose and ear (clear in a side
///   view), falling back to heel -> toe, voted over the last [facingVotes]
///   frames so one noisy foot point cannot flip it. The space result is the
///   best of the last second of standing frames.
class PlacementEvaluator {
  final double minPointConf;
  final double minMeanConf;
  final int holdMs;
  final double minFps;
  final double floorFactor;
  final int facingVotes;
  final List<int> _facingHistory = [];
  final List<(int, bool)> _floorHistory = [];
  final int heartbeatMs;
  final PostureClassifier classifier;

  final FrameRateMonitor _fps;
  int? _firstCameraMs;
  int? _lastCameraMs;
  int? _confSince;
  PlacementState _last = const PlacementState();

  PlacementEvaluator({
    this.minPointConf = 0.5,
    this.minMeanConf = 0.7,
    this.holdMs = 3000,
    this.minFps = 14.5,
    this.floorFactor = 0.2,
    this.facingVotes = 15,
    this.heartbeatMs = defaultHeartbeatMs,
    PostureClassifier? classifier,
  }) : classifier = classifier ?? RuleBasedClassifier(),
       _fps = FrameRateMonitor(
         minFps: minFps,
         windowMs: holdMs,
         heartbeatMs: heartbeatMs,
       );

  PlacementState get current => _last;

  void reset() {
    classifier.reset();
    _fps.reset();
    _firstCameraMs = null;
    _lastCameraMs = null;
    _confSince = null;
    _facingHistory.clear();
    _floorHistory.clear();
    _last = const PlacementState();
  }

  /// Camera frames needed in the [holdMs] window for [PlacementState.fpsOk].
  int get requiredFrames => _fps.requiredFrames;

  PlacementState add(PoseFrame f) {
    final last = _lastCameraMs;
    final heartbeat =
        !f.hasPerson &&
        last != null &&
        f.tMs > last &&
        (f.tMs - last) % heartbeatMs == 0;
    if (heartbeat) {
      // The camera stalled: only the frame rate changes.
      _fps.tick(f.tMs);
      return _last = _with(_last, fpsOk: _fpsOk(f.tMs));
    }
    _fps.addCameraFrame(f.tMs);
    _firstCameraMs ??= f.tMs;
    _lastCameraMs = f.tMs;
    final fpsOk = _fpsOk(f.tMs);
    final reading = classifier.classify(f);

    final person = _pick(f);
    if (person == null) {
      _confSince = null;
      return _last = PlacementState(
        fpsOk: fpsOk,
        imageW: f.imageW,
        imageH: f.imageH,
      );
    }

    final w = f.imageW.toDouble();
    final h = f.imageH.toDouble();
    bool seen(Landmark p) => p.conf >= minPointConf;
    bool inside(Landmark p) => p.x >= 0 && p.x <= w && p.y >= 0 && p.y <= h;

    final side = _nearSide(person);
    final shoulder = person[side.shoulder];
    final hip = person[side.hip];
    final knee = person[side.knee];
    final ankle = person[side.ankle];
    final heel = person[side.heel];
    final toe = person[side.toe];
    final head = [
      for (final i in const [
        LandmarkIndex.nose,
        LandmarkIndex.leftEye,
        LandmarkIndex.rightEye,
        LandmarkIndex.leftEar,
        LandmarkIndex.rightEar,
      ])
        if (seen(person[i])) person[i],
    ];
    final feet = [ankle, heel, toe].where(seen).toList();

    final headOk = head.isNotEmpty && head.every(inside);
    final feetOk =
        (seen(ankle) || seen(heel)) && feet.isNotEmpty && feet.every(inside);
    final limbsOk = [shoulder, hip, knee].every((p) => seen(p) && inside(p));
    final bodyVisible = headOk && feetOk && limbsOk;

    final mean = (shoulder.conf + hip.conf + knee.conf + ankle.conf) / 4;
    if (bodyVisible && mean >= minMeanConf) {
      _confSince ??= f.tMs;
    } else {
      _confSince = null;
    }
    final since = _confSince;
    final confidenceOk = since != null && f.tMs - since >= holdMs;

    var floorSpaceOk = false;
    String? message;
    if (!bodyVisible) {
      final cutOff = head.isEmpty || !headOk || !feetOk;
      message = cutOff
          ? 'Move the phone back'
          : 'Stand side-on where the phone can see you';
    } else {
      final facing = _votedFacing(_facing(person, side, seen));
      if (reading.posture == Posture.standing && facing != 0) {
        final topY = head.map((p) => p.y).reduce(math.min);
        final footY = feet.map((p) => p.y).reduce(math.max);
        final height = footY - topY;
        final front = facing > 0
            ? w - feet.map((p) => p.x).reduce(math.max)
            : feet.map((p) => p.x).reduce(math.min);
        _floorHistory.add((f.tMs, height > 0 && front >= floorFactor * height));
      }
      _floorHistory.removeWhere((e) => f.tMs - e.$1 > 1000);
      // Facing the camera, the space ahead can't be judged (and the prayer
      // can't be followed well), so the check stays open until side-on.
      final frontOn = _facesCamera(person, seen);
      if (frontOn) _floorHistory.clear();
      floorSpaceOk = !frontOn && _floorHistory.any((e) => e.$2);
      if (mean < minMeanConf) {
        message = 'Move the phone back';
      } else if (frontOn) {
        message = 'Turn sideways: the phone should be at your left or right';
      } else if (reading.posture != Posture.standing) {
        message = 'Stand up straight, side-on to the phone';
      } else if (facing == 0) {
        message = 'Turn side-on to the phone';
      } else if (!floorSpaceOk) {
        message = 'Step back a little so sujood fits in view';
      } else if (!fpsOk) {
        message = 'Turn on a light';
      } else if (!confidenceOk) {
        message = 'Hold still';
      }
    }

    return _last = PlacementState(
      bodyVisible: bodyVisible,
      confidenceOk: confidenceOk,
      fpsOk: fpsOk,
      floorSpaceOk: floorSpaceOk,
      message: message,
      skeleton: person,
      imageW: f.imageW,
      imageH: f.imageH,
    );
  }

  bool _fpsOk(int tMs) {
    final first = _firstCameraMs;
    return first != null &&
        tMs - first >= holdMs &&
        _fps.framesInWindow >= _fps.requiredFrames;
  }

  static PlacementState _with(PlacementState s, {required bool fpsOk}) =>
      PlacementState(
        bodyVisible: s.bodyVisible,
        confidenceOk: s.confidenceOk,
        fpsOk: fpsOk,
        floorSpaceOk: s.floorSpaceOk,
        message: s.message,
        skeleton: s.skeleton,
        imageW: s.imageW,
        imageH: s.imageH,
      );

  /// The single person, or the tallest of several (the classifier does the
  /// real person selection during the prayer).
  static List<Landmark>? _pick(PoseFrame f) {
    final people = f.people.isNotEmpty
        ? f.people
        : [if (f.landmarks != null) f.landmarks!];
    List<Landmark>? best;
    var bestH = -1.0;
    for (final p in people) {
      if (p.length < LandmarkIndex.count) continue;
      final ys = p.where((l) => l.conf >= 0.3).map((l) => l.y);
      if (ys.isEmpty) continue;
      final h = ys.reduce(math.max) - ys.reduce(math.min);
      if (h > bestH) {
        bestH = h;
        best = p;
      }
    }
    return best;
  }

  static _Side _nearSide(List<Landmark> p) {
    double mean(_Side s) =>
        (p[s.shoulder].conf +
            p[s.hip].conf +
            p[s.knee].conf +
            p[s.ankle].conf) /
        4;
    return mean(_Side.left) >= mean(_Side.right) ? _Side.left : _Side.right;
  }

  /// +1 facing right (towards larger x), -1 facing left, 0 unknown.
  /// True when the user faces the camera (or has their back to it) instead
  /// of standing side-on: both shoulders clearly seen and far apart compared
  /// with the torso. Side-on, the shoulders overlap (width well under half
  /// the shoulder-hip length); facing the camera they are about as wide as
  /// the torso is long.
  static bool _facesCamera(List<Landmark> p, bool Function(Landmark) seen) {
    final ls = p[LandmarkIndex.leftShoulder],
        rs = p[LandmarkIndex.rightShoulder];
    final lh = p[LandmarkIndex.leftHip], rh = p[LandmarkIndex.rightHip];
    if (!(seen(ls) && seen(rs) && seen(lh) && seen(rh))) return false;
    final width = (ls.x - rs.x).abs();
    final torso = ((lh.y + rh.y) / 2 - (ls.y + rs.y) / 2).abs();
    return torso > 0 && width > 0.55 * torso;
  }

  /// Majority of the last [facingVotes] facing readings (0 = unknown).
  int _votedFacing(int now) {
    if (now != 0) {
      _facingHistory.add(now);
      if (_facingHistory.length > facingVotes) _facingHistory.removeAt(0);
    }
    final sum = _facingHistory.fold(0, (a, b) => a + b);
    return sum == 0 ? 0 : (sum > 0 ? 1 : -1);
  }

  /// +1 facing right in the image, -1 facing left, 0 unknown. The nose
  /// sits clearly ahead of the ear in a side view, so it decides; foot
  /// points (often noisy) are only a fallback.
  static int _facing(
    List<Landmark> p,
    _Side side,
    bool Function(Landmark) seen,
  ) {
    final nose = p[LandmarkIndex.nose];
    final ear = p[side.ear];
    if (seen(nose) && seen(ear)) {
      final dx = nose.x - ear.x;
      if (dx.abs() >= 3) return dx > 0 ? 1 : -1;
    }
    final heel = p[side.heel];
    final toe = p[side.toe];
    if (seen(heel) && seen(toe)) {
      final dx = toe.x - heel.x;
      if (dx.abs() >= 3) return dx > 0 ? 1 : -1;
    }
    return 0;
  }
}

class _Side {
  final int shoulder, hip, knee, ankle, heel, toe, ear;
  const _Side(
    this.shoulder,
    this.hip,
    this.knee,
    this.ankle,
    this.heel,
    this.toe,
    this.ear,
  );

  static const left = _Side(
    LandmarkIndex.leftShoulder,
    LandmarkIndex.leftHip,
    LandmarkIndex.leftKnee,
    LandmarkIndex.leftAnkle,
    LandmarkIndex.leftHeel,
    LandmarkIndex.leftFootIndex,
    LandmarkIndex.leftEar,
  );
  static const right = _Side(
    LandmarkIndex.rightShoulder,
    LandmarkIndex.rightHip,
    LandmarkIndex.rightKnee,
    LandmarkIndex.rightAnkle,
    LandmarkIndex.rightHeel,
    LandmarkIndex.rightFootIndex,
    LandmarkIndex.rightEar,
  );
}

/// [PlacementCheck] over a [PoseEngine]. Shares the engine with the prayer
/// session: [stop] releases the camera (and hides the preview) before the
/// session opens it again. If the app is paused while checking (the engine
/// reports `paused`), the check restarts when the app is resumed.
///
/// The lens comes from [start] / [switchLens] and replaces
/// [cameraConfig]'s; the evaluator's thresholds are the same for both
/// lenses. Each state carries the lens actually active ([activeLens], when
/// the engine reports one, else the requested lens), so the overlay can be
/// mirrored to match a front-camera preview. The landmarks themselves are
/// never mirrored.
class PosePlacementCheck implements PlacementCheck {
  final PoseEngine engine;

  /// Size and frame rate to request; its lens is replaced by the requested
  /// one.
  final CameraConfig cameraConfig;
  final WidgetBuilder? previewBuilder;
  final PlacementEvaluator evaluator;

  /// The lens the engine actually opened (null until it reports), e.g.
  /// `AndroidPoseEngine.activeLens`.
  final ValueListenable<CameraLens?>? activeLens;

  final _state = LatestValue<PlacementState>();
  final ValueNotifier<bool> _showPreview = ValueNotifier(false);
  StreamSubscription<PoseFrame>? _sub;
  AppLifecycleListener? _lifecycle;
  bool _running = false;
  bool _pausedByApp = false;
  late CameraLens _lens = cameraConfig.lens;
  PlacementState _last = const PlacementState();

  PosePlacementCheck({
    required this.engine,
    this.cameraConfig = const CameraConfig(),
    this.previewBuilder,
    this.activeLens,
    PlacementEvaluator? evaluator,
    bool watchLifecycle = true,
  }) : evaluator = evaluator ?? PlacementEvaluator() {
    _publish(const PlacementState());
    activeLens?.addListener(_onActiveLens);
    if (watchLifecycle) {
      _lifecycle = AppLifecycleListener(onResume: _onResume);
    }
  }

  /// The lens requested by [start] or [switchLens].
  CameraLens get requestedLens => _lens;

  CameraLens get _currentLens => activeLens?.value ?? _lens;

  void _publish(PlacementState s) =>
      _state.add(_last = s.copyWith(lens: _currentLens));

  void _onActiveLens() {
    if (_running && _last.lens != _currentLens) _publish(_last);
  }

  CameraConfig get _config => CameraConfig(
    width: cameraConfig.width,
    height: cameraConfig.height,
    fps: cameraConfig.fps,
    lens: _lens,
  );

  @override
  Stream<PlacementState> get state => _state.stream;

  @override
  Future<void> start({CameraLens lens = CameraLens.rear}) async {
    if (_running) return;
    _running = true;
    _lens = lens;
    _open();
  }

  @override
  Future<void> switchLens(CameraLens lens) async {
    _lens = lens;
    if (!_running) return;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    await engine.stop(); // One camera at a time: release before reopening.
    if (!_running) return; // Stopped meanwhile.
    _publish(const PlacementState());
    _open();
  }

  void _open() {
    evaluator.reset();
    _pausedByApp = false;
    _showPreview.value = true;
    _sub = engine
        .start(_config)
        .listen(
          (f) => _publish(evaluator.add(f)),
          onError: (Object e) {
            final code = e is PoseEngineError ? e.code : 'cameraUnavailable';
            debugPrint('PosePlacementCheck: $e');
            _sub = null;
            if (code == 'paused') {
              _pausedByApp = true;
              return;
            }
            _publish(
              PlacementState(
                message: code == 'permissionDenied'
                    ? 'Allow camera access in the phone settings'
                    : 'The camera is not available',
              ),
            );
          },
        );
  }

  void _onResume() {
    if (_running && _pausedByApp) _open();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _showPreview.value = false;
    _lifecycle?.dispose();
    _lifecycle = null;
    activeLens?.removeListener(_onActiveLens);
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    await engine.stop();
  }

  @override
  Widget? buildPreview(BuildContext context) {
    final b = previewBuilder;
    if (b == null) return null;
    return ValueListenableBuilder<bool>(
      valueListenable: _showPreview,
      builder: (context, show, _) =>
          show ? b(context) : const SizedBox.shrink(),
    );
  }
}
