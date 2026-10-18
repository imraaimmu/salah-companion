/// Synthetic labelled Fajr prayers for tests and tuning, before (and
/// alongside) real recordings. See docs/SPEC.md, "Test data" and the
/// "Required replay cases" in "Prayer logic".
///
/// A 2D side-view stick body is animated through a scripted Fajr prayer and
/// rendered to the 33 BlazePose landmarks, then perturbed (pixel noise,
/// confidence jitter, dropouts, hidden knees, camera tilt, timing jitter, a
/// second smaller person). The output is a [Recording] plus a [LabelSet], so it
/// can be written with [encodeRecording] and [encodeLabels].
///
/// Everything is deterministic for a given seed (only `dart:math` [math.Random]
/// is used).
///
/// ## Labelling rules
///
/// * **States are the person's true place in the sequence**, using the
///   spec's state definitions, not the state machine's delayed view: a state
///   label switches at the midpoint of the movement into the posture that
///   starts it (no hold times). The one exception is `takbir`, which by
///   definition runs from the takbir event (the moment the raise completes,
///   i.e. the hands are back at rest) for [takbirHoldMs] of standing, after
///   which `qiyam1` starts (matching the 0.8 s hold in the states table).
/// * When no takbir hand raise happens ([SyntheticCase.missedTakbir]) the
///   standing before the first ruku stays `waiting` with rak'ah 0: by the
///   spec, Takbir is entered only on a hand-raise event.
/// * A missed ruku ([SyntheticCase.missedRuku]) is still labelled `bowing` /
///   `ruku1|2`: the person did bow, the camera just did not see it.
/// * Jalsa, a brief sitting before rak'ah 2 and the rise up to its midpoint
///   are labelled with the current `sujood1|2` state; everything after the
///   midpoint of the move into the final sitting (sujood al-sahw, salam) is
///   `finalSitting`; standing up afterwards is `done`.
/// * **Transitions:** the first 20 % of a posture-changing movement keeps the
///   old posture, the last 20 % already carries the new posture, and the
///   middle 60 % is labelled `unknown` (the body matches neither posture's
///   rules there). For movements made of several legs (standing → kneeling →
///   prostrating) the 20 % applies to the first and last leg. Arm-only
///   movements (raises, qunut, folding the hands, salam head turns) keep the
///   posture label.
/// * Only the opening takbir (takbirat al-ihram) is a takbir event in the
///   labels. Later hand raises (at ruku, qunut) are listed in
///   [SyntheticPrayer.gestures] for classifier tests.
library;

import 'dart:math' as math;

import 'pose.dart';
import 'posture.dart';
import 'prayer.dart';
import 'recording.dart';

/// The scripted scenarios. Together they cover every "Required replay case"
/// in docs/SPEC.md section "Prayer logic", plus [normal].
enum SyntheticCase {
  /// A plain Fajr: takbir, two rak'ahs, final sitting, salam, stand up.
  normal,

  /// Standing 30–45 s before the takbir (iqamah, intention).
  iqamahWait,

  /// No takbir hand raise at all; the hands are folded without raising.
  missedTakbir,

  /// Shafi'i qunut: raised hands in the i'tidal of rak'ah 2.
  shafiiQunut,

  /// Maliki qunut: raised hands in qiyam 2, before the ruku.
  malikiQunut,

  /// Hands raised before going into ruku and again in i'tidal, both rak'ahs.
  raisedHandsAtRuku,

  /// A brief sitting after the second sujood of rak'ah 1, then standing.
  briefSittingBeforeRakah2,

  /// Jalsa held under 0.5 s (labelled sitting time < 500 ms) in both rak'ahs.
  hurriedJalsa,

  /// One ruku (random rak'ah) not seen: frames dropped or very low confidence.
  missedRuku,

  /// Final sitting of 100–170 s (under the 180 s timeout).
  longTashahhud,

  /// Two sujood al-sahw in the final sitting, before the salam.
  sahwBeforeSalam,

  /// Salam, then two sujood al-sahw, sitting and a second salam.
  sahwAfterSalam,

  /// A child (smaller person) walks into frame and stands or copies the
  /// prayer for a while.
  childInFrame,
}

enum SyntheticGestureKind {
  /// The opening takbir hand raise.
  takbir,

  /// A hand raise before ruku or in i'tidal (raf' al-yadayn).
  rukuRaise,

  /// Hands raised palms up for qunut (the hold, from raised to lowering).
  qunut,

  /// A salam head turn.
  salam,
}

/// An arm or head gesture in the script, for classifier tests.
class SyntheticGesture {
  final SyntheticGestureKind kind;
  final int startMs;
  final int endMs;

  const SyntheticGesture(this.kind, this.startMs, this.endMs);

  @override
  String toString() => 'SyntheticGesture(${kind.name}, $startMs-$endMs ms)';
}

/// A span of time in which the user was deliberately hidden from the camera.
class SyntheticSpan {
  final int startMs;
  final int endMs;

  const SyntheticSpan(this.startMs, this.endMs);

  bool contains(int tMs) => tMs >= startMs && tMs < endMs;
}

/// How the scenario is timed and perturbed.
class SyntheticOptions {
  /// Multiplier for the long holds (qiyam recitation, ordinary tashahhud,
  /// qunut). 1.0 is realistic; tests use e.g. 0.05. Scaled holds have floors
  /// (qiyam 2.5 s, tashahhud 6 s, qunut 2 s) so the sequence stays valid for
  /// the state machine's hold times. Case-defining durations (the 30 s iqamah,
  /// the long tashahhud, the hurried jalsa) and all movements are never
  /// scaled.
  final double timeScale;

  /// Nominal camera frame rate.
  final int fps;

  /// Standard deviation of frame timestamps around the nominal 1/fps grid.
  final double timingJitterMs;

  /// Probability that a frame is missing from the file (a timing gap).
  final double frameSkipRate;

  /// Gaussian pixel noise (standard deviation) added to every landmark.
  final double pixelNoise;

  /// Gaussian noise on each landmark's confidence (clamped to 0..1).
  final double confJitter;

  /// Per landmark, per frame probability of a dropout (confidence near 0,
  /// position scattered).
  final double landmarkDropoutRate;

  /// Per frame probability of starting a whole-frame dropout burst (1–20
  /// frames written as `people: []`).
  final double frameDropoutRate;

  /// Loose clothing: knee confidence low and jittery (0.15–0.5, positions
  /// noisy). Ankles, heels and feet below the hem stay visible and get only a
  /// mild drop (confidence capped at 0.5–0.8).
  final bool kneesHidden;

  /// Camera roll in degrees. Every landmark is rotated about the frame centre
  /// by -roll in image coordinates (y down, so positive angles turn clockwise
  /// on screen); rotating by +roll about the centre undoes it.
  ///
  /// Each frame's `tilt` field is the roll relative to the session start
  /// (roll minus the roll at t = 0), as the recording format defines it, so
  /// it starts at 0 and only [tiltDriftDeg] makes it move.
  final double tiltDeg;

  /// Amplitude of a slow sinusoidal drift added to [tiltDeg].
  final double tiltDriftDeg;

  /// Add a second, smaller person (a child) for part of the prayer.
  final bool child;

  /// Which way the user faces in the image: +1 right, -1 left, null random.
  final int? facing;

  /// The user's standing height in pixels; null picks 360–500 at random.
  final double? heightPx;

  const SyntheticOptions({
    this.timeScale = 1.0,
    this.fps = 15,
    this.timingJitterMs = 3,
    this.frameSkipRate = 0,
    this.pixelNoise = 1.0,
    this.confJitter = 0.03,
    this.landmarkDropoutRate = 0,
    this.frameDropoutRate = 0,
    this.kneesHidden = false,
    this.tiltDeg = 0,
    this.tiltDriftDeg = 0,
    this.child = false,
    this.facing,
    this.heightPx,
  });

  /// No noise, jitter or dropouts at all: exact geometry on a 15 fps grid.
  const SyntheticOptions.clean({
    this.timeScale = 1.0,
    this.fps = 15,
    this.facing,
    this.heightPx,
  })  : timingJitterMs = 0,
        frameSkipRate = 0,
        pixelNoise = 0,
        confJitter = 0,
        landmarkDropoutRate = 0,
        frameDropoutRate = 0,
        kneesHidden = false,
        tiltDeg = 0,
        tiltDriftDeg = 0,
        child = false;

  /// A random mix of perturbations, as used by [generateSyntheticBatch].
  factory SyntheticOptions.random(math.Random rng, {double timeScale = 1.0}) {
    double u(double lo, double hi) => lo + rng.nextDouble() * (hi - lo);
    bool p(double prob) => rng.nextDouble() < prob;
    return SyntheticOptions(
      timeScale: timeScale,
      timingJitterMs: u(0, 8),
      frameSkipRate: p(0.3) ? u(0, 0.03) : 0,
      pixelNoise: u(0.3, 4),
      confJitter: u(0.01, 0.08),
      landmarkDropoutRate: p(0.5) ? u(0, 0.02) : 0,
      frameDropoutRate: p(0.4) ? u(0, 0.01) : 0,
      kneesHidden: p(0.3),
      tiltDeg: p(0.3) ? u(-4, 4) : 0,
      tiltDriftDeg: p(0.2) ? u(0, 1.5) : 0,
      child: p(0.1),
    );
  }

  SyntheticOptions copyWith({bool? child, double? timeScale}) =>
      SyntheticOptions(
        timeScale: timeScale ?? this.timeScale,
        fps: fps,
        timingJitterMs: timingJitterMs,
        frameSkipRate: frameSkipRate,
        pixelNoise: pixelNoise,
        confJitter: confJitter,
        landmarkDropoutRate: landmarkDropoutRate,
        frameDropoutRate: frameDropoutRate,
        kneesHidden: kneesHidden,
        tiltDeg: tiltDeg,
        tiltDriftDeg: tiltDriftDeg,
        child: child ?? this.child,
        facing: facing,
        heightPx: heightPx,
      );
}

/// Standing time in the `takbir` state after the takbir event.
const int takbirHoldMs = 800;

/// One generated prayer.
class SyntheticPrayer {
  final SyntheticCase scenario;
  final int seed;
  final SyntheticOptions options;

  /// Base name; files are `<name>.recording.ndjson` / `<name>.labels.ndjson`.
  final String name;
  final Recording recording;
  final LabelSet labels;

  /// Every scripted hand raise, qunut and salam turn, in time order.
  final List<SyntheticGesture> gestures;

  /// Spans where the user was deliberately hidden (the missed ruku).
  final List<SyntheticSpan> occlusions;

  const SyntheticPrayer({
    required this.scenario,
    required this.seed,
    required this.options,
    required this.name,
    required this.recording,
    required this.labels,
    required this.gestures,
    required this.occlusions,
  });

  String get recordingFileName => '$name.recording.ndjson';
  String get labelsFileName => '$name.labels.ndjson';

  String encodeRecordingText() => encodeRecording(recording);
  String encodeLabelsText() => encodeLabels(labels);
}

/// Generates one prayer for [scenario]. Same arguments, same output.
SyntheticPrayer generateSyntheticPrayer(
  SyntheticCase scenario, {
  int seed = 0,
  SyntheticOptions options = const SyntheticOptions(),
  String? name,
}) {
  final rng = math.Random(seed);
  final opts = scenario == SyntheticCase.childInFrame
      ? options.copyWith(child: true)
      : options;
  final facing = opts.facing ?? (rng.nextBool() ? 1 : -1);
  final height = opts.heightPx ?? _u(rng, 360, 500);
  final body = _Body.random(rng, height, facing, adult: true);
  final kf = _Keyframes(body, rng);
  final script = _buildScript(scenario, kf, rng, opts);
  final fileName = name ?? 'synthetic-${scenario.name}-s$seed';
  final frames = _render(script, body, rng, opts);
  return SyntheticPrayer(
    scenario: scenario,
    seed: seed,
    options: opts,
    name: fileName,
    recording: Recording(
      header: RecordingHeader(
        engine: 'salah-synthetic',
        model: 'stick-v1',
        fps: opts.fps,
        orientation: 'portrait',
        side: facing > 0 ? 'right' : 'left',
        device: 'synthetic',
        imageW: _imageW,
        imageH: _imageH,
      ),
      frames: frames,
    ),
    labels: LabelSet(
      recording: '$fileName.recording.ndjson',
      intervals: script.intervals(),
      takbirTimesMs: List.unmodifiable(script.takbirs),
    ),
    gestures: List.unmodifiable(script.gestures),
    occlusions: List.unmodifiable(script.occlusions),
  );
}

/// [count] prayers cycling through every [SyntheticCase] in order, each with
/// its own derived seed and [SyntheticOptions.random] perturbations.
Iterable<SyntheticPrayer> generateSyntheticBatch(
  int count, {
  int seed = 0,
  double timeScale = 1.0,
}) sync* {
  final rng = math.Random(seed);
  const cases = SyntheticCase.values;
  for (var i = 0; i < count; i++) {
    final c = cases[i % cases.length];
    final options = SyntheticOptions.random(rng, timeScale: timeScale);
    final s = rng.nextInt(1 << 31);
    yield generateSyntheticPrayer(
      c,
      seed: s,
      options: options,
      name: 'synthetic-${(i + 1).toString().padLeft(4, '0')}-${c.name}-s$s',
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers

const int _imageW = 480;
const int _imageH = 640;
const double _deg = math.pi / 180;

double _u(math.Random rng, double lo, double hi) =>
    lo + rng.nextDouble() * (hi - lo);

int _ms(math.Random rng, num lo, num hi) =>
    (lo + rng.nextDouble() * (hi - lo)).round();

/// Gaussian noise from one generator (Box-Muller, keeping the spare value).
class _Noise {
  final math.Random rng;
  double? _spare;
  _Noise(this.rng);

  double gauss() {
    final spare = _spare;
    if (spare != null) {
      _spare = null;
      return spare;
    }
    final u1 = 1.0 - rng.nextDouble(); // (0, 1]
    final u2 = rng.nextDouble();
    final r = math.sqrt(-2 * math.log(u1));
    _spare = r * math.sin(2 * math.pi * u2);
    return r * math.cos(2 * math.pi * u2);
  }
}

/// 2D point in body world coordinates: x forward (the facing direction),
/// y up, origin at the near toe tip on the floor. Units are pixels.
class _V {
  final double x, y;
  const _V(this.x, this.y);
  _V operator +(_V o) => _V(x + o.x, y + o.y);
  _V operator -(_V o) => _V(x - o.x, y - o.y);
  _V operator *(double k) => _V(x * k, y * k);
  double get len => math.sqrt(x * x + y * y);
}

/// Unit vector at [deg] from straight up, positive towards the front.
_V _dir(double deg) => _V(math.sin(deg * _deg), math.cos(deg * _deg));

/// Angle of [v] from straight up, positive towards the front, in (-180, 180].
double _angleOf(_V v) => math.atan2(v.x, v.y) / _deg;

/// Arms are kept in [-90, 270) so "down" (180) never wraps.
double _armAngle(double a) {
  var r = a;
  while (r < -90) {
    r += 360;
  }
  while (r >= 270) {
    r -= 360;
  }
  return r;
}

_V _rotate(_V v, double deg) {
  final c = math.cos(deg * _deg), s = math.sin(deg * _deg);
  return _V(v.x * c - v.y * s, v.x * s + v.y * c);
}

// ---------------------------------------------------------------------------
// Body model

/// Segment lengths (pixels) and rendering constants for one person.
class _Body {
  final double h;
  final double foot, ankleUp, ankleBack, shank, thigh, torso, neck;
  final double upperArm, forearm, hand, kneeR, seat;
  final int facing;
  final double toeX, floorY;
  final _V farOffset; // pixel offset of far-side landmarks
  final List<double> baseConf;

  _Body._({
    required this.h,
    required this.foot,
    required this.ankleUp,
    required this.ankleBack,
    required this.shank,
    required this.thigh,
    required this.torso,
    required this.neck,
    required this.upperArm,
    required this.forearm,
    required this.hand,
    required this.kneeR,
    required this.seat,
    required this.facing,
    required this.toeX,
    required this.floorY,
    required this.farOffset,
    required this.baseConf,
  });

  /// Proportions after Winter's anthropometric table, varied per person.
  factory _Body.random(math.Random rng, double h, int facing,
      {required bool adult, double? toeX, double? floorY}) {
    double v(double frac, [double spread = 0.05]) =>
        frac * h * _u(rng, 1 - spread, 1 + spread);
    final legScale = _u(rng, 0.96, 1.04);
    final foot = v(0.152);
    final conf = List<double>.filled(LandmarkIndex.count, 0);
    for (var i = 0; i < LandmarkIndex.count; i++) {
      final far = _isFar(i, facing);
      conf[i] = far
          ? _u(rng, 0.3, 0.6)
          : (i <= 10 ? _u(rng, 0.9, 0.99) : _u(rng, 0.85, 0.99));
      if (!adult) conf[i] *= _u(rng, 0.8, 0.95);
    }
    final floor = floorY ?? _u(rng, 565, 620);
    return _Body._(
      h: h,
      foot: foot,
      ankleUp: 0.27 * foot,
      ankleBack: 0.75 * foot,
      shank: v(0.246) * legScale,
      thigh: v(0.245) * legScale,
      torso: v(0.288),
      neck: v(0.10),
      upperArm: v(0.186),
      forearm: v(0.146),
      hand: v(0.108),
      kneeR: 0.025 * h,
      seat: v(0.06, 0.15),
      facing: facing,
      // Leave room in front for sujood (toe to fingertips is ~0.75 h).
      toeX: toeX ?? (_imageW / 2 - facing * (0.3 * h) + _u(rng, -15, 15)),
      floorY: floor,
      farOffset:
          _V(-facing * _u(rng, 2, 7) * h / 450, _u(rng, -2, 2) * h / 450),
      baseConf: conf,
    );
  }

  /// A smaller copy for a child, standing elsewhere in the frame.
  factory _Body.child(math.Random rng, _Body adult) {
    final h = adult.h * _u(rng, 0.5, 0.68);
    return _Body.random(rng, h, rng.nextBool() ? adult.facing : -adult.facing,
        adult: false, toeX: 0, floorY: adult.floorY - _u(rng, 10, 45));
  }
}

/// Indices of the side facing away from the camera. Facing right in the
/// image (unmirrored, camera on the person's right) shows the right side.
bool _isFar(int i, int facing) {
  if (i == LandmarkIndex.nose) return false;
  final isLeft = (i >= 1 && i <= 3) || (i >= 7 && i.isOdd);
  return facing > 0 ? isLeft : !isLeft;
}

/// Segment directions of a pose, in degrees from straight up, positive
/// forward. Interpolated component-wise.
class _Pose {
  static const int n = 11;
  final List<double> v;
  const _Pose._(this.v);

  factory _Pose({
    double foot = 0, // toe pitch: 0 flat, ~80 toes tucked, heel up
    double shank = 0, // ankle -> knee
    double thigh = 0, // knee -> hip
    double torso = 0, // hip -> shoulder
    double neck = 5, // shoulder -> ear
    double head = 15, // head "up" axis (face looks along head + 90)
    double upper = 180, // shoulder -> elbow
    double fore = 180, // elbow -> wrist
    double foreScale = 1, // forearm foreshortening (hands towards midline)
    double? hand, // wrist -> fingers; defaults to the forearm
    double turn = 0, // salam head turn, 0..1
  }) =>
      _Pose._([
        foot,
        shank,
        thigh,
        torso,
        neck,
        head,
        _armAngle(upper),
        _armAngle(fore),
        foreScale,
        _armAngle(hand ?? fore),
        turn,
      ]);

  double get foot => v[0];
  double get shank => v[1];
  double get thigh => v[2];
  double get torso => v[3];
  double get neck => v[4];
  double get head => v[5];
  double get upper => v[6];
  double get fore => v[7];
  double get foreScale => v[8];
  double get hand => v[9];
  double get turn => v[10];

  _Pose withArms(_Pose arms) => _Pose._([
        ...v.sublist(0, 6),
        arms.upper,
        arms.fore,
        arms.foreScale,
        arms.hand,
        v[10],
      ]);

  _Pose withTurn(double t) => _Pose._([...v.sublist(0, 10), t]);

  static _Pose lerp(_Pose a, _Pose b, double t) {
    if (identical(a, b) || t <= 0) return a;
    if (t >= 1) return b;
    return _Pose._(
        [for (var i = 0; i < n; i++) a.v[i] + (b.v[i] - a.v[i]) * t]);
  }

  /// Small natural sway: torso, head and arms move by a degree or two.
  _Pose sway(double tMs, List<double> phase) => _Pose._([
        v[0],
        v[1],
        v[2],
        v[3] + 0.8 * math.sin(tMs / 3100 * 2 * math.pi + phase[0]),
        v[4],
        v[5] + 2.0 * math.sin(tMs / 4300 * 2 * math.pi + phase[1]),
        v[6] + 1.0 * math.sin(tMs / 2700 * 2 * math.pi + phase[2]),
        v[7] + 1.2 * math.sin(tMs / 3700 * 2 * math.pi + phase[3]),
        v[8],
        v[9],
        v[10],
      ]);
}

/// Joint positions in body world coordinates.
class _Skeleton {
  final _V toe, heel, ankle, knee, hip, shoulder, elbow, wrist;
  final _V ear, nose, eyeInner, eye, eyeOuter, mouth, forehead;
  final _V index, pinky, thumb;

  _Skeleton._(
      {required this.toe,
      required this.heel,
      required this.ankle,
      required this.knee,
      required this.hip,
      required this.shoulder,
      required this.elbow,
      required this.wrist,
      required this.ear,
      required this.nose,
      required this.eyeInner,
      required this.eye,
      required this.eyeOuter,
      required this.mouth,
      required this.forehead,
      required this.index,
      required this.pinky,
      required this.thumb});

  factory _Skeleton(_Body b, _Pose p) {
    const toe = _V(0, 0);
    final heel = _rotate(_V(-b.foot, 0), -p.foot);
    final ankle = _rotate(_V(-b.ankleBack, b.ankleUp), -p.foot);
    final knee = ankle + _dir(p.shank) * b.shank;
    final hip = knee + _dir(p.thigh) * b.thigh;
    final shoulder = hip + _dir(p.torso) * b.torso;
    final ear = shoulder + _dir(p.neck) * b.neck;
    final up = _dir(p.head);
    final fwd = _dir(p.head + 90) * (1 - 0.5 * p.turn);
    _V face(double f, double u) => ear + fwd * (f * b.h) + up * (u * b.h);
    final elbow = shoulder + _dir(p.upper) * b.upperArm;
    final wrist = elbow + _dir(p.fore) * (b.forearm * p.foreScale);
    final hs = b.hand * (0.6 + 0.4 * p.foreScale);
    return _Skeleton._(
      toe: toe,
      heel: heel,
      ankle: ankle,
      knee: knee,
      hip: hip,
      shoulder: shoulder,
      elbow: elbow,
      wrist: wrist,
      ear: ear,
      nose: face(0.085, -0.005),
      eyeInner: face(0.075, 0.02),
      eye: face(0.066, 0.022),
      eyeOuter: face(0.054, 0.021),
      mouth: face(0.07, -0.04),
      forehead: face(0.072, 0.055),
      index: wrist + _dir(p.hand) * (0.75 * hs),
      pinky: wrist + _dir(p.hand + 12) * (0.62 * hs),
      thumb: wrist + _dir(p.hand - 28) * (0.42 * hs),
    );
  }

  /// Near-side world position for every BlazePose index.
  _V at(int i) => switch (i) {
        0 => nose,
        1 || 4 => eyeInner,
        2 || 5 => eye,
        3 || 6 => eyeOuter,
        7 || 8 => ear,
        9 || 10 => mouth,
        11 || 12 => shoulder,
        13 || 14 => elbow,
        15 || 16 => wrist,
        17 || 18 => pinky,
        19 || 20 => index,
        21 || 22 => thumb,
        23 || 24 => hip,
        25 || 26 => knee,
        27 || 28 => ankle,
        29 || 30 => heel,
        _ => toe,
      };
}

// ---------------------------------------------------------------------------
// Keyframes

/// Two-link arm IK from the shoulder to [target]. Returns (upper, fore).
(double, double) _armIk(_V shoulder, _V target, double a, double b,
    {required bool elbowHigh}) {
  final d0 = (target - shoulder).len;
  final d = d0.clamp((a - b).abs() + 1e-3, a + b - 1e-3);
  final phi = _angleOf(target - shoulder);
  final cosA = ((a * a + d * d - b * b) / (2 * a * d)).clamp(-1.0, 1.0);
  final alpha = math.acos(cosA) / _deg;
  final w = shoulder + _dir(phi) * d;
  final e1 = shoulder + _dir(phi + alpha) * a;
  final e2 = shoulder + _dir(phi - alpha) * a;
  final e = (e1.y > e2.y) == elbowHigh ? e1 : e2;
  return (_angleOf(e - shoulder), _angleOf(w - e));
}

/// Keyframe poses for one body, with per-prayer style choices.
class _Keyframes {
  final _Body b;
  final math.Random rng;

  /// Arm rest positions.
  late final _Pose armsSides;
  late final _Pose armsFolded;

  /// Takbir raise peak (ears, shoulders or chest).
  late final _Pose raisePeak;
  late final double standTorso;
  late final double gazeHead;

  _Keyframes(this.b, this.rng) {
    armsSides = _Pose(upper: _u(rng, 176, 184), fore: _u(rng, 178, 186));
    armsFolded = switch (rng.nextInt(3)) {
      // Chest (Shafi'i), navel (Hanafi), or arms at the sides (Maliki sadl).
      0 => _Pose(
          upper: _u(rng, 172, 178),
          fore: _u(rng, 45, 60),
          foreScale: _u(rng, 0.55, 0.65)),
      1 => _Pose(
          upper: _u(rng, 175, 182),
          fore: _u(rng, 70, 95),
          foreScale: _u(rng, 0.5, 0.62)),
      _ => armsSides,
    };
    raisePeak = switch (rng.nextInt(3)) {
      0 =>
        _Pose(upper: _u(rng, 105, 120), fore: _u(rng, -20, -5), foreScale: 0.9),
      1 =>
        _Pose(upper: _u(rng, 140, 155), fore: _u(rng, 0, 15), foreScale: 0.9),
      _ =>
        _Pose(upper: _u(rng, 160, 170), fore: _u(rng, 25, 38), foreScale: 0.85),
    };
    standTorso = _u(rng, 0, 4);
    gazeHead = _u(rng, 12, 25);
  }

  _Pose standing(_Pose arms) => _Pose(
        shank: _u(rng, 0, 2),
        thigh: _u(rng, -1, 1),
        torso: standTorso,
        neck: _u(rng, 3, 8),
        head: gazeHead,
      ).withArms(arms);

  /// Qunut: hands raised palms up, chest (low) to face (high) height.
  _Pose qunutArms() {
    final high = rng.nextBool();
    final fore = high ? _u(rng, 15, 35) : _u(rng, 55, 75);
    return _Pose(
        upper: _u(rng, 150, 165), fore: fore, foreScale: 0.85, hand: fore - 25);
  }

  _Pose bowing() {
    final torso = _u(rng, 82, 95);
    final base = _Pose(
      shank: _u(rng, 0, 3),
      thigh: _u(rng, -8, -3),
      torso: torso,
      neck: torso + _u(rng, 0, 6),
      head: torso + _u(rng, -5, 10),
    );
    final s = _Skeleton(b, base);
    // Hands on (or just above) the knees.
    final target = s.knee + _V(0.02 * b.h, 0.02 * b.h);
    final (u, f) =
        _armIk(s.shoulder, target, b.upperArm, b.forearm, elbowHigh: true);
    return _Pose(
      shank: base.shank,
      thigh: base.thigh,
      torso: base.torso,
      neck: base.neck,
      head: base.head,
      upper: u,
      fore: f,
    );
  }

  /// Shank angle that puts the knee on the floor for toe pitch [foot].
  double _kneeOnFloor(double foot) {
    final ankle = _rotate(_V(-b.ankleBack, b.ankleUp), -foot);
    final dy = (ankle.y - b.kneeR).clamp(0.0, b.shank * 0.99);
    final dx = math.sqrt(b.shank * b.shank - dy * dy);
    return _angleOf(_V(dx, -dy));
  }

  _Pose kneeling() {
    final foot = _u(rng, 70, 80);
    final torso = _u(rng, 15, 30);
    return _Pose(
      foot: foot,
      shank: _kneeOnFloor(foot),
      thigh: _u(rng, 5, 20),
      torso: torso,
      neck: torso + 10,
      head: torso + 25,
      upper: _u(rng, 145, 160),
      fore: _u(rng, 140, 160),
    );
  }

  /// Knees, toes, hands and forehead on the floor, hips above the heels.
  _Pose prostrating({required bool compact}) {
    final foot = _u(rng, 70, 85);
    final shank = _kneeOnFloor(foot);
    final thigh = compact ? _u(rng, -45, -35) : _u(rng, -2, 15);
    final dn = _u(rng, -5, 5), dh = _u(rng, -25, -12);
    _Pose withTorso(double o) => _Pose(
        foot: foot,
        shank: shank,
        thigh: thigh,
        torso: o,
        neck: o + dn,
        head: o + dh);
    double faceY(double o) {
      final s = _Skeleton(b, withTorso(o));
      return math.min(s.nose.y, s.forehead.y) - 0.006 * b.h;
    }

    // Bisection: lean the torso forward until the forehead meets the floor.
    var lo = 60.0, hi = 175.0;
    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      if (faceY(mid) > 0) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final base = withTorso((lo + hi) / 2);
    final s = _Skeleton(b, base);
    final target = _V(s.ear.x - 0.03 * b.h, 0.01 * b.h);
    final (u, f) = _armIk(s.shoulder, target, b.upperArm, b.forearm * 0.95,
        elbowHigh: true);
    return _Pose(
      foot: foot,
      shank: shank,
      thigh: thigh,
      torso: base.torso,
      neck: base.neck,
      head: base.head,
      upper: u,
      fore: f,
      foreScale: 0.95,
      hand: 90,
    );
  }

  /// Sitting on the heels (toes tucked), torso upright, hands on the thighs.
  _Pose sitting() {
    final foot = _u(rng, 68, 82);
    final shank = _kneeOnFloor(foot);
    final heel = _rotate(_V(-b.foot, 0), -foot);
    final ankle = _rotate(_V(-b.ankleBack, b.ankleUp), -foot);
    final knee = ankle + _dir(shank) * b.shank;
    final hipY = heel.y + b.seat;
    final dy = (hipY - knee.y).clamp(0.0, b.thigh * 0.98);
    final dx = math.sqrt(b.thigh * b.thigh - dy * dy);
    final thigh = _angleOf(_V(-dx, dy));
    final torso = _u(rng, 0, 12);
    final base = _Pose(
        foot: foot,
        shank: shank,
        thigh: thigh,
        torso: torso,
        neck: torso + _u(rng, 3, 10),
        head: torso + _u(rng, 15, 30));
    final s = _Skeleton(b, base);
    final target = s.hip + (s.knee - s.hip) * 0.7 + _V(0, 0.035 * b.h);
    final (u, f) =
        _armIk(s.shoulder, target, b.upperArm, b.forearm, elbowHigh: false);
    return _Pose(
      foot: foot,
      shank: shank,
      thigh: thigh,
      torso: torso,
      neck: base.neck,
      head: base.head,
      upper: u,
      fore: f,
    );
  }
}

// ---------------------------------------------------------------------------
// Script

class _Seg {
  final int start, end;
  final _Pose from, to;
  const _Seg(this.start, this.end, this.from, this.to);
}

class _Script {
  final List<_Seg> segs = [];
  final List<LabelInterval> _pieces = [];
  final List<int> takbirs = [];
  final List<SyntheticGesture> gestures = [];
  final List<SyntheticSpan> occlusions = [];
  final List<bool> occlusionLowConf = [];
  int t = 0;
  _Pose pose;
  Posture posture;
  PrayerState state = PrayerState.waiting;
  int rakah = 0;

  _Script(this.pose, this.posture);

  void _label(int s, int e, Posture p, PrayerState st, int r) {
    if (e <= s) return;
    _pieces.add(
        LabelInterval(startMs: s, endMs: e, posture: p, state: st, rakah: r));
  }

  /// Holds the current pose for [ms], optionally entering a new state.
  void hold(int ms, {PrayerState? state, int? rakah}) {
    if (state != null) this.state = state;
    if (rakah != null) this.rakah = rakah;
    if (ms <= 0) return;
    segs.add(_Seg(t, t + ms, pose, pose));
    _label(t, t + ms, posture, this.state, this.rakah);
    t += ms;
  }

  void _legs(List<_Pose> keys, List<int> durs) {
    for (var i = 0; i < keys.length; i++) {
      segs.add(_Seg(t, t + durs[i], pose, keys[i]));
      t += durs[i];
      pose = keys[i];
    }
  }

  /// A posture-changing movement through [keys]. See the library docs for
  /// how its frames are labelled.
  void move(List<_Pose> keys, List<int> durs, Posture to,
      {PrayerState? state, int? rakah}) {
    final t0 = t;
    final total = durs.fold(0, (a, d) => a + d);
    final a = t0 + (0.2 * durs.first).round();
    final b = t0 + total - (0.2 * durs.last).round();
    final mid = (t0 + total ~/ 2).clamp(a, b);
    final newState = state ?? this.state;
    final newRakah = rakah ?? this.rakah;
    if (to == posture) {
      _label(t0, mid, posture, this.state, this.rakah);
      _label(mid, t0 + total, to, newState, newRakah);
    } else {
      _label(t0, a, posture, this.state, this.rakah);
      _label(a, mid, Posture.unknown, this.state, this.rakah);
      _label(mid, b, Posture.unknown, newState, newRakah);
      _label(b, t0 + total, to, newState, newRakah);
    }
    _legs(keys, durs);
    posture = to;
    this.state = newState;
    this.rakah = newRakah;
  }

  /// An arm or head movement that keeps the posture label.
  void gesture(List<_Pose> keys, List<int> durs, {SyntheticGestureKind? kind}) {
    final t0 = t;
    final total = durs.fold(0, (a, d) => a + d);
    _label(t0, t0 + total, posture, state, rakah);
    _legs(keys, durs);
    if (kind != null) gestures.add(SyntheticGesture(kind, t0, t));
  }

  List<LabelInterval> intervals() {
    final out = <LabelInterval>[];
    for (final p in _pieces) {
      if (out.isNotEmpty) {
        final last = out.last;
        if (last.endMs == p.startMs &&
            last.posture == p.posture &&
            last.state == p.state &&
            last.rakah == p.rakah) {
          out[out.length - 1] = LabelInterval(
              startMs: last.startMs,
              endMs: p.endMs,
              posture: p.posture,
              state: p.state,
              rakah: p.rakah);
          continue;
        }
      }
      out.add(p);
    }
    return List.unmodifiable(out);
  }

  /// Index of the segment containing [tMs] (the last one if past the end).
  int segAt(int tMs, [int from = 0]) {
    var i = from;
    while (i < segs.length - 1 && tMs >= segs[i].end) {
      i++;
    }
    return i;
  }

  int segAtBinary(int tMs) {
    var lo = 0, hi = segs.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (tMs >= segs[mid].end) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  _Pose poseAt(int tMs, int segIndex) {
    final s = segs[segIndex];
    final span = s.end - s.start;
    final x = span <= 0 ? 1.0 : ((tMs - s.start) / span).clamp(0.0, 1.0);
    final e = x * x * (3 - 2 * x); // smoothstep easing
    return _Pose.lerp(s.from, s.to, e);
  }
}

_Script _buildScript(
    SyntheticCase c, _Keyframes kf, math.Random rng, SyntheticOptions opts) {
  int r(num lo, num hi) => _ms(rng, lo, hi);
  // Long holds scale with timeScale, with floors that keep the sequence valid
  // for the state machine's hold times.
  int long(num lo, num hi, int floor) =>
      math.max(floor, (r(lo, hi) * opts.timeScale).round());

  final sides = kf.armsSides;
  final folded = kf.armsFolded;
  final stand0 = kf.standing(sides);
  final s = _Script(stand0, Posture.standing);

  // How the person rests their hands while standing in prayer.
  _Pose standFolded() => kf.standing(folded);
  _Pose itidalPose() => kf.standing(rng.nextDouble() < 0.7 ? sides : folded);

  void raise(SyntheticGestureKind kind, _Pose rest) {
    final peak = s.pose.withArms(kf.raisePeak);
    s.gesture([
      peak,
      peak,
      s.pose.withArms(rest)
    ], [
      r(300, 500),
      r(80, 350),
      r(300, 500)
    ], kind: kind);
  }

  void qunut({required _Pose after, required bool lower}) {
    final up = s.pose.withArms(kf.qunutArms());
    s.gesture([up], [r(500, 800)]);
    final t0 = s.t;
    s.hold(long(8000, 30000, 2000));
    s.gestures.add(SyntheticGesture(SyntheticGestureKind.qunut, t0, s.t));
    if (lower) s.gesture([s.pose.withArms(after)], [r(500, 800)]);
  }

  void salam() {
    for (var i = 0; i < 2; i++) {
      final turned = s.pose.withTurn(1);
      s.gesture([
        turned,
        turned,
        s.pose.withTurn(0)
      ], [
        r(400, 650),
        r(300, 900),
        r(350, 600)
      ], kind: SyntheticGestureKind.salam);
    }
  }

  void prostrate({required PrayerState state, required int rakah}) {
    final from = s.posture;
    final target = kf.prostrating(compact: rng.nextDouble() < 0.25);
    if (from == Posture.standing) {
      s.move([
        kf.kneeling(),
        target
      ], [
        r(550, 900),
        r(450, 750)
      ], Posture.prostrating, state: state, rakah: rakah);
    } else {
      s.move([target], [r(550, 900)], Posture.prostrating,
          state: state, rakah: rakah);
    }
  }

  /// Sujood, jalsa, sujood. Ends prostrating.
  void sujoodPair(int rakah, {required bool hurried}) {
    final state = rakah == 1 ? PrayerState.sujood1 : PrayerState.sujood2;
    prostrate(state: state, rakah: rakah);
    s.hold(r(1800, 5000));
    final down = hurried ? r(350, 450) : r(600, 1000);
    s.move([kf.sitting()], [down], Posture.sitting);
    s.hold(hurried ? r(100, 250) : r(900, 3000));
    s.move([kf.prostrating(compact: rng.nextDouble() < 0.25)],
        [hurried ? r(350, 450) : r(550, 900)], Posture.prostrating);
    s.hold(r(1800, 5000));
  }

  final missedRukuRakah = rng.nextBool() ? 1 : 2;
  final hurried = c == SyntheticCase.hurriedJalsa;

  /// Ruku and i'tidal of [rakah], from standing; ends standing in i'tidal.
  void rukuItidal(int rakah) {
    final rukuState = rakah == 1 ? PrayerState.ruku1 : PrayerState.ruku2;
    final itidalState = rakah == 1 ? PrayerState.itidal1 : PrayerState.itidal2;
    if (c == SyntheticCase.raisedHandsAtRuku) {
      raise(SyntheticGestureKind.rukuRaise, sides);
    }
    final occluded = c == SyntheticCase.missedRuku && rakah == missedRukuRakah;
    final occStart = s.t;
    s.move([kf.bowing()], [r(600, 1200)], Posture.bowing,
        state: rukuState, rakah: rakah);
    s.hold(r(2000, 5500));
    final itidal = c == SyntheticCase.raisedHandsAtRuku
        ? kf.standing(sides)
        : itidalPose();
    s.move([itidal], [r(600, 1000)], Posture.standing, state: itidalState);
    if (occluded) {
      s.occlusions.add(SyntheticSpan(occStart, s.t));
      s.occlusionLowConf.add(rng.nextBool());
    }
    if (c == SyntheticCase.raisedHandsAtRuku) {
      raise(SyntheticGestureKind.rukuRaise, sides);
    }
    s.hold(r(800, 3500));
  }

  // ---- Before the prayer.
  if (c == SyntheticCase.iqamahWait) {
    s.hold(r(30000, 45000));
  } else {
    s.hold(r(1000, 4000));
  }

  // ---- Takbir.
  if (c == SyntheticCase.missedTakbir) {
    // Folding the hands without a raise: the wrist never reaches the takbir
    // height. Everything until the first ruku stays `waiting`.
    s.gesture([s.pose.withArms(folded)], [r(500, 900)]);
    s.hold(long(40000, 120000, 2500));
  } else {
    raise(SyntheticGestureKind.takbir, folded);
    s.takbirs.add(s.t);
    s.hold(takbirHoldMs, state: PrayerState.takbir, rakah: 0);
    // Opening dua, Al-Fatiha, Ameen, surah 1.
    s.hold(long(40000, 120000, 2500), state: PrayerState.qiyam1, rakah: 1);
  }

  // ---- Rak'ah 1.
  rukuItidal(1);
  sujoodPair(1, hurried: hurried);

  // ---- Rise for rak'ah 2.
  if (c == SyntheticCase.briefSittingBeforeRakah2) {
    s.move([kf.sitting()], [r(600, 1000)], Posture.sitting);
    s.hold(r(800, 2500));
  }
  s.move([standFolded()], [r(900, 1400)], Posture.standing,
      state: PrayerState.qiyam2, rakah: 2);
  s.hold(long(30000, 100000, 2500));
  if (c == SyntheticCase.malikiQunut) {
    qunut(after: folded, lower: true);
    s.hold(r(300, 800));
  }

  // ---- Rak'ah 2.
  rukuItidal(2);
  if (c == SyntheticCase.shafiiQunut) {
    qunut(after: sides, lower: false);
  }
  sujoodPair(2, hurried: hurried);

  // ---- Final sitting.
  s.move([kf.sitting()], [r(700, 1100)], Posture.sitting,
      state: PrayerState.finalSitting);
  final tashahhud = c == SyntheticCase.longTashahhud
      ? r(100000, 170000)
      : long(20000, 50000, 6000);
  s.hold(tashahhud);
  void sahw() {
    prostrate(state: PrayerState.finalSitting, rakah: 2);
    s.hold(r(1800, 4000));
    s.move([kf.sitting()], [r(600, 1000)], Posture.sitting);
    s.hold(r(800, 2500));
    prostrate(state: PrayerState.finalSitting, rakah: 2);
    s.hold(r(1800, 4000));
    s.move([kf.sitting()], [r(600, 1000)], Posture.sitting);
  }

  if (c == SyntheticCase.sahwBeforeSalam) {
    sahw();
    s.hold(r(800, 2000));
  }
  salam();
  if (c == SyntheticCase.sahwAfterSalam) {
    s.hold(r(500, 1500));
    sahw();
    s.hold(long(5000, 15000, 2000));
    salam();
  }
  s.hold(r(500, 2500));

  // ---- Stand up: done.
  s.move([kf.standing(sides)], [r(1000, 1600)], Posture.standing,
      state: PrayerState.done);
  s.hold(r(1000, 3000));
  return s;
}

// ---------------------------------------------------------------------------
// Rendering

List<PoseFrame> _render(
    _Script script, _Body body, math.Random rng, SyntheticOptions o) {
  final end = script.t;
  final phase = [for (var i = 0; i < 4; i++) _u(rng, 0, 2 * math.pi)];

  // Child: a window, walking in and out, standing still or copying the user.
  _Body? child;
  var childStart = 0, childEnd = 0, childLag = 0;
  var childCopies = false;
  var childX = 0.0, childEnterX = 0.0;
  late _Pose childStand;
  var childFirst = false;
  if (o.child) {
    child = _Body.child(rng, body);
    final len = (end * _u(rng, 0.25, 0.6)).round();
    childStart = _ms(rng, end * 0.05, math.max(end * 0.05 + 1, end - len));
    childEnd = math.min(end, childStart + len);
    childLag = _ms(rng, 400, 1500);
    childCopies = rng.nextBool();
    childX = _u(rng, 60, _imageW - 60.0);
    childEnterX = rng.nextBool() ? -0.15 * _imageW : 1.15 * _imageW;
    childStand = _Keyframes(child, rng).standing(_Pose(upper: 178, fore: 180));
    childFirst = rng.nextBool();
  }

  final period = 1000 / o.fps;
  final nz = _Noise(rng);
  final frames = <PoseFrame>[];
  double rollAt(int t) =>
      o.tiltDeg +
      (o.tiltDriftDeg == 0
          ? 0
          : o.tiltDriftDeg * math.sin(t / 47000 * 2 * math.pi + phase[0]));
  final roll0 = rollAt(0);
  var seg = 0;
  var prevT = -1;
  var dropLeft = 0;
  for (var i = 0;; i++) {
    var t = i == 0 ? 0 : (i * period + nz.gauss() * o.timingJitterMs).round();
    if (t <= prevT) t = prevT + 1;
    if (t >= end) break;
    if (i > 0 && o.frameSkipRate > 0 && rng.nextDouble() < o.frameSkipRate) {
      continue;
    }
    prevT = t;
    // Landmarks rotate by the full roll; the written tilt is relative to the
    // session start.
    final tilt = rollAt(t);
    final tiltOut = ((tilt - roll0) * 100).roundToDouble() / 100;

    if (dropLeft == 0 &&
        o.frameDropoutRate > 0 &&
        rng.nextDouble() < o.frameDropoutRate) {
      dropLeft =
          rng.nextDouble() < 0.7 ? 1 + rng.nextInt(4) : 5 + rng.nextInt(16);
    }
    seg = script.segAt(t, seg);
    var occluded = false, lowConf = false;
    for (var k = 0; k < script.occlusions.length; k++) {
      if (script.occlusions[k].contains(t)) {
        occluded = true;
        lowConf = script.occlusionLowConf[k];
      }
    }
    if (dropLeft > 0 || (occluded && !lowConf)) {
      if (dropLeft > 0) dropLeft--;
      frames.add(PoseFrame(
          tMs: t,
          landmarks: null,
          imageW: _imageW,
          imageH: _imageH,
          tiltDeg: tiltOut));
      continue;
    }

    final pose = script.poseAt(t, seg).sway(t.toDouble(), phase);
    final people = <List<Landmark>>[
      _person(body, pose, body.toeX, nz, o, tilt, lowConf: lowConf),
    ];
    if (child != null && t >= childStart && t < childEnd) {
      const walk = 1500;
      double x = childX;
      if (t - childStart < walk) {
        x = childEnterX + (childX - childEnterX) * (t - childStart) / walk;
      } else if (childEnd - t < walk) {
        x = childEnterX + (childX - childEnterX) * (childEnd - t) / walk;
      }
      final cp = childCopies && t - childLag >= 0
          ? script.poseAt(t - childLag, script.segAtBinary(t - childLag))
          : childStand;
      final hipX = x + child.facing * 0.1 * child.h;
      if (hipX >= 0 && hipX <= _imageW) {
        final p = _person(child, cp.sway(t + 777.0, phase), x, nz, o, tilt);
        if (childFirst) {
          people.insert(0, p);
        } else {
          people.add(p);
        }
        if (rng.nextDouble() < 0.03) childFirst = !childFirst;
      }
    }
    frames.add(PoseFrame(
      tMs: t,
      landmarks: people.length == 1 ? people.single : null,
      people: List.unmodifiable(people),
      imageW: _imageW,
      imageH: _imageH,
      tiltDeg: tiltOut,
    ));
  }
  return frames;
}

double _round(double v, int places) {
  final k = places == 2 ? 100.0 : 1000.0;
  return (v * k).roundToDouble() / k;
}

List<Landmark> _person(_Body b, _Pose pose, double toeX, _Noise nz,
    SyntheticOptions o, double tilt,
    {bool lowConf = false}) {
  final sk = _Skeleton(b, pose);
  const cx = _imageW / 2, cy = _imageH / 2;
  final cosT = math.cos(-tilt * _deg), sinT = math.sin(-tilt * _deg);
  final scale = b.h / 450;
  final out = <Landmark>[];
  for (var i = 0; i < LandmarkIndex.count; i++) {
    final far = _isFar(i, b.facing);
    final w = sk.at(i);
    final wy = math.max(0.0, w.y); // nothing below the floor
    var x = toeX + b.facing * w.x;
    var y = b.floorY - wy;
    var conf = b.baseConf[i];
    var sigma = o.pixelNoise;
    if (far) {
      x += b.farOffset.x;
      y += b.farOffset.y;
      sigma += 1.5 * scale * (o.pixelNoise > 0 ? 1 : 0);
    }
    if (o.kneesHidden) {
      if (i == LandmarkIndex.leftKnee || i == LandmarkIndex.rightKnee) {
        conf = _u(nz.rng, 0.15, 0.5) * (far ? 0.7 : 1);
        sigma += 6 * scale;
      } else if (i > LandmarkIndex.rightKnee) {
        // Ankles, heels, feet: below the hem, only a mild drop.
        conf = math.min(conf, _u(nz.rng, 0.5, 0.8));
        sigma += 1.5 * scale;
      }
    }
    if (lowConf) {
      conf = _u(nz.rng, 0.02, 0.3);
      sigma += 10 * scale;
    }
    if (o.landmarkDropoutRate > 0 &&
        nz.rng.nextDouble() < o.landmarkDropoutRate) {
      conf = _u(nz.rng, 0, 0.1);
      sigma += 15 * scale;
    }
    if (o.confJitter > 0) conf += nz.gauss() * o.confJitter;
    if (sigma > 0) {
      x += nz.gauss() * sigma;
      y += nz.gauss() * sigma;
    }
    if (tilt != 0) {
      final dx = x - cx, dy = y - cy;
      x = cx + dx * cosT - dy * sinT;
      y = cy + dx * sinT + dy * cosT;
    }
    final z = (far ? 0.15 : -0.15) * scale;
    out.add(Landmark(_round(x, 2), _round(y, 2), _round(z, 3),
        _round(conf.clamp(0.0, 1.0), 3)));
  }
  return List.unmodifiable(out);
}
