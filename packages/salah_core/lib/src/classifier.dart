/// Rule-based posture classifier and takbir hand-raise detector. See
/// docs/SPEC.md, section "Pose detection and classification".
///
/// One [PoseFrame] in, one [PostureReading] out. The classifier is stateful
/// (near-side lock, calibration, person tracking, takbir detection) and must
/// be [RuleBasedClassifier.reset] per session.
///
/// ## Geometry
///
/// * All points are in pixels, rotated by `frame.tiltDeg` about the image
///   centre to undo the phone's roll since session start (the recording
///   format's tilt is relative to the session start, so a constant roll
///   present from the start is not removed; a few degrees of it only shifts
///   the torso angle by the same few degrees).
/// * Distances are divided by the 2D shoulder–hip length of the same frame.
/// * **Hip height** = near ankle y − near hip y (image y grows downwards),
///   divided by the torso length. [PostureReading.hipHeightRatio] is that
///   value divided by the calibrated standing value (1.0 = standing).
/// * **Torso angle** = shoulder→hip line against vertical, unsigned, in
///   degrees (0 upright, 90 level, over 90 when the shoulder is below the
///   hip).
/// * **Head drop** = (nose y − hip y) / torso length; positive when the nose
///   is below the hip.
/// * **Knee angle** = hip–knee–ankle, used only when the knee's confidence is
///   at least [ClassifierConfig.kneeConf], and then only as a veto.
///
/// ## Near side
///
/// The side facing the camera is locked during the first frames of the
/// session from landmark visibility (the near side is seen with much higher
/// confidence) and the nose direction (the nose points away from the ear
/// towards the facing direction; facing right in the unmirrored image shows
/// the right side). Until it is locked, each frame uses the side with the
/// higher summed confidence. Far-side landmarks are used only for hip height
/// (far hip or far ankle, when the near one is not visible) and only at
/// confidence [ClassifierConfig.farConf] or more. The far wrist is also used,
/// at that confidence, as a veto for one-handed raises (see "Takbir").
///
/// ## Calibration
///
/// The standing hip height (and the torso length, for person selection) is
/// the median over *steady standing* frames: torso under
/// [ClassifierConfig.steadyTorsoDeg], hip height changing less than
/// [ClassifierConfig.steadyDelta] torso lengths since the previous frame,
/// mean confidence at least [ClassifierConfig.minMeanConf], hip height at
/// least [ClassifierConfig.calibrationMinPrior] of the prior (and at least
/// [ClassifierConfig.standHip] of an existing calibration), and the knee
/// straight when it is visible. These frames do not need to be classified
/// standing, so calibration also works with the knees hidden.
///
/// * Before the first takbir it follows the last
///   [ClassifierConfig.calibrationWindowMs] of steady standing (needs
///   [ClassifierConfig.minCalibrationSamples] samples), so a missed takbir
///   still calibrates from the standing before the prayer.
/// * On the first detected takbir raise at time T it is recomputed from the
///   steady standing in [T − window, T + [ClassifierConfig.takbirCalibAfterMs]]
///   and then frozen for the session. If that window holds too few steady
///   samples (noise, dropouts, a takbir straight after appearing), nothing is
///   frozen: it carries on as without a takbir.
/// * Without a takbir it freezes once the user has been classified bowing or
///   prostrating for [ClassifierConfig.freezeAfterFrames] frames in a row.
///
/// **Before calibration** the hip height is compared with an anthropometric
/// prior ([ClassifierConfig.priorStandingNorm] torso lengths, the typical
/// ankle-to-hip height of an adult) instead. [PostureReading.hipHeightRatio]
/// stays null until calibration, because the state machine should only act
/// on calibrated values. Standing before calibration needs the knee seen at
/// [ClassifierConfig.kneeConf] or more and straight, torso under
/// [ClassifierConfig.uncalibratedStandTorsoDeg] and hip height at least
/// [ClassifierConfig.uncalibratedStandHip] of the prior; with the knees
/// hidden it is unknown until calibration (normally under a second of steady
/// standing). Sitting and prostrating use the prior directly: sitting is
/// about 0.2 of standing and the prior's error a few tenths at most.
///
/// ## Rules (spec "Starting rules", checked in this order)
///
/// 1. Prostrating: hip < [ClassifierConfig.prostrateHip] and head drop ≥
///    [ClassifierConfig.prostrateDrop].
/// 2. Sitting: hip ≤ [ClassifierConfig.sitHip] and torso <
///    [ClassifierConfig.sitTorsoDeg].
/// 3. Standing: hip ≥ [ClassifierConfig.standHip] and torso <
///    [ClassifierConfig.standTorsoDeg]. Never from the torso alone: no hip
///    height, no standing.
/// 4. Bowing: hip ≥ [ClassifierConfig.bowHip], torso in
///    [[ClassifierConfig.bowTorsoMinDeg], [ClassifierConfig.bowTorsoMaxDeg]]
///    and the head roughly level with the hips.
/// 5. Otherwise unknown.
///
/// A visible knee (confidence ≥ 0.7) vetoes standing or bowing when bent
/// below [ClassifierConfig.kneeStraightDeg], and sitting or prostrating when
/// straighter than [ClassifierConfig.kneeBentDeg]; a veto gives unknown. Any
/// landmark under [ClassifierConfig.minLandmarkConf] counts as not visible.
/// The reading's confidence is the mean confidence of the landmarks used;
/// below [ClassifierConfig.minMeanConf] the posture is unknown (the raw values
/// are still reported).
///
/// ## Person selection
///
/// When several people are detected the user is the one whose torso length
/// is within [ClassifierConfig.torsoTolerance] of the calibrated length and
/// whose hip is closest to the user's last hip position; if two people fit
/// about equally, or the only fit is far from where the user was a moment
/// ago, the frame is unknown with null raw values (lost tracking). Before
/// calibration the clearly largest person (torso ≥
/// [ClassifierConfig.uncalibratedSizeRatio] × the next) is taken, otherwise
/// unknown. A single detected person is also rejected once calibrated if the
/// torso length does not fit.
///
/// ## Takbir
///
/// The wrist height is measured along the torso axis: 0 at the hip, 1 at the
/// shoulder. The *smoothed* level is the mean over the last
/// [ClassifierConfig.takbirSmoothFrames] frames. An event fires
/// (`takbirRaise == true`) on the frame where a raise completes:
///
/// 1. the near wrist is below the near elbow (arm down), then
/// 2. within [ClassifierConfig.takbirWindowMs] of the last arm-down frame the
///    smoothed level reaches [ClassifierConfig.takbirLevel] and stays there
///    for at least [ClassifierConfig.takbirMinAboveFrames] frames, then
/// 3. it comes down by [ClassifierConfig.takbirDrop] from its smoothed peak
///    (and below [ClassifierConfig.takbirLevel]), still within the window,
///
/// and, judged when it comes down, the raise **stands out from the resting
/// level**:
///
/// * the smoothed peak is at least [ClassifierConfig.takbirMinRise] (0.35)
///   above the lowest smoothed level since the last arm-down frame (the
///   level the hands rose from), and
/// * the highest single-frame (unsmoothed) level during the raise, the
///   frames in the smoothing window when it started included, is at least
///   [ClassifierConfig.takbirMinRawPeak] (0.68).
///
/// Why: hands folded on the chest rest at 0.55–0.62 of hip→shoulder, just
/// under the 0.65 level, and pixel noise of 5 px or more pushed the 3-frame
/// mean over it and back down by 0.1, firing a takbir while the user waited
/// (iqamah, or a missed takbir). Folded hands only come "down" past the
/// elbow by noise, from about the level they rest at, so noise alone does
/// not lift them 0.35 above it; a real takbir rises from the arms at the
/// sides through the elbow and keeps climbing (typically 0.6 or more above
/// the level where the wrist crossed the elbow, about 0.4 for a raise to the
/// chest with a high elbow). The larger drop
/// (0.17 instead of 0.1) rejects most of the act of folding the hands with
/// heavy noise on top. Tuned on held-out synthetic seeds: chest raises peak
/// at 0.68–0.80 and a chest raise that ends folded on the chest drops only
/// 0.16–0.2, which is why the raw peak is 0.68 (not 0.75) and the drop 0.17
/// (not 0.2). Folding the hands under 7–8 px of noise can still very rarely
/// look like a chest-height takbir (about 2 in 150 prayers at 6–8 px,
/// against 10–31 in 150 with the old rule).
///
/// The user must be upright throughout (torso under
/// [ClassifierConfig.takbirMaxTorsoDeg], hip height at least
/// [ClassifierConfig.takbirMinHip]), so arm movements while bowing, going
/// down or sitting never count. After an event (or an aborted raise) the arm
/// must go below the elbow again before the next one. Holding the hands up
/// for more than the window (qunut, scratching the head, adjusting a cap) is
/// not a raise. If the far wrist is seen at confidence ≥ 0.7 during the raise
/// it must rise too (to [ClassifierConfig.takbirFarLevel]), which rejects
/// brief one-handed movements; when the far arm is hidden a brief one-handed
/// raise to the chest or above within 2 s is indistinguishable and does fire.
/// Raises at ruku and in short qunut-like movements also fire; the state
/// machine ignores raises after the first.
library;

import 'dart:math' as math;

import 'interfaces.dart';
import 'pose.dart';
import 'posture.dart';

/// Thresholds of [RuleBasedClassifier]. The defaults are the spec's starting
/// rules plus values tuned on the synthetic generator.
class ClassifierConfig {
  // Landmark confidence.
  final double minLandmarkConf;
  final double minMeanConf;
  final double farConf;
  final double kneeConf;

  // Posture rules (hip height as a fraction of standing, angles in degrees).
  final double standHip;
  final double standTorsoDeg;
  final double bowHip;
  final double bowTorsoMinDeg;
  final double bowTorsoMaxDeg;
  final double bowDropMin;
  final double bowDropMax;
  final double prostrateHip;
  final double prostrateDrop;
  final double sitHip;
  final double sitTorsoDeg;
  final double kneeStraightDeg;
  final double kneeBentDeg;

  // Before calibration.
  final double priorStandingNorm;
  final double uncalibratedStandHip;
  final double uncalibratedStandTorsoDeg;

  // Calibration.
  final int calibrationWindowMs;
  final int minCalibrationSamples;
  final double steadyTorsoDeg;
  final double steadyDelta;
  final int takbirCalibAfterMs;
  final int freezeAfterFrames;
  final double calibrationMinPrior;

  // Person selection.
  final double torsoTolerance;
  final double uncalibratedSizeRatio;
  final double maxHipJump;
  final int hipMemoryMs;

  // Takbir.
  final double takbirLevel;
  final double takbirFarLevel;
  final double takbirDrop;

  /// Smoothed peak minus the lowest smoothed level since the last arm-down
  /// frame (the level the hands rose from) must be at least this.
  final double takbirMinRise;

  /// The highest unsmoothed wrist level during the raise must be at least
  /// this.
  final double takbirMinRawPeak;
  final int takbirWindowMs;
  final int takbirMinAboveFrames;
  final int takbirSmoothFrames;
  final double takbirMaxTorsoDeg;
  final double takbirMinHip;

  const ClassifierConfig({
    this.minLandmarkConf = 0.3,
    this.minMeanConf = 0.5,
    this.farConf = 0.7,
    this.kneeConf = 0.7,
    this.standHip = 0.8,
    this.standTorsoDeg = 20,
    this.bowHip = 0.6,
    this.bowTorsoMinDeg = 55,
    this.bowTorsoMaxDeg = 100,
    this.bowDropMin = -0.7,
    this.bowDropMax = 1.0,
    this.prostrateHip = 0.6,
    this.prostrateDrop = 0.4,
    this.sitHip = 0.35,
    this.sitTorsoDeg = 35,
    this.kneeStraightDeg = 140,
    this.kneeBentDeg = 130,
    this.priorStandingNorm = 1.7,
    this.uncalibratedStandHip = 0.85,
    this.uncalibratedStandTorsoDeg = 15,
    this.calibrationWindowMs = 3000,
    this.minCalibrationSamples = 8,
    this.steadyTorsoDeg = 15,
    this.steadyDelta = 0.05,
    this.takbirCalibAfterMs = 1000,
    this.freezeAfterFrames = 3,
    this.calibrationMinPrior = 0.7,
    this.torsoTolerance = 0.2,
    this.uncalibratedSizeRatio = 1.25,
    this.maxHipJump = 2.0,
    this.hipMemoryMs = 2000,
    this.takbirLevel = 0.65,
    this.takbirFarLevel = 0.6,
    this.takbirDrop = 0.17,
    this.takbirMinRise = 0.35,
    this.takbirMinRawPeak = 0.68,
    this.takbirWindowMs = 2000,
    this.takbirMinAboveFrames = 2,
    this.takbirSmoothFrames = 3,
    this.takbirMaxTorsoDeg = 30,
    this.takbirMinHip = 0.7,
  });
}

/// Which body side faces the camera.
enum BodySide { left, right }

/// The spec's angle rules on one frame of landmarks, plus the takbir event.
/// See the library documentation.
class RuleBasedClassifier implements PostureClassifier {
  final ClassifierConfig config;

  RuleBasedClassifier({this.config = const ClassifierConfig()});

  // Near side.
  BodySide? _side;
  int _votesLeft = 0;
  int _votesRight = 0;

  // Calibration.
  final List<_Sample> _samples = [];
  double? _calHipNorm;
  double? _calTorsoPx;
  int? _takbirT;
  bool _frozen = false;
  int _nonStandingRun = 0;
  double? _prevHipNorm;

  // Person tracking.
  _Pt? _lastHip;
  int? _lastHipT;

  // Takbir.
  final List<double> _levels = [];
  int? _armDownT;
  bool _raised = false;
  double _peak = 0;
  double _rawPeak = 0;
  double _base = 0;
  int _aboveFrames = 0;
  int _farSeen = 0;
  int _farHigh = 0;

  /// The locked near side, or null while still deciding.
  BodySide? get nearSide => _side;

  /// Whether a standing calibration exists.
  bool get isCalibrated => _calHipNorm != null;

  /// Calibrated standing hip height in torso lengths, or null.
  double? get calibratedHipNorm => _calHipNorm;

  /// Calibrated torso length in pixels, or null.
  double? get calibratedTorsoPx => _calTorsoPx;

  /// Whether the calibration is frozen for the session.
  bool get isCalibrationFrozen => _frozen;

  @override
  void reset() {
    _side = null;
    _votesLeft = 0;
    _votesRight = 0;
    _samples.clear();
    _calHipNorm = null;
    _calTorsoPx = null;
    _takbirT = null;
    _frozen = false;
    _nonStandingRun = 0;
    _prevHipNorm = null;
    _lastHip = null;
    _lastHipT = null;
    _resetTakbir();
  }

  @override
  PostureReading classify(PoseFrame frame) {
    final t = frame.tMs;
    final raw = frame.people.isNotEmpty
        ? frame.people
        : (frame.landmarks != null
            ? [frame.landmarks!]
            : const <List<Landmark>>[]);
    if (raw.isEmpty) return PostureReading.unknown(t);

    final cx = frame.imageW / 2, cy = frame.imageH / 2;
    final a = frame.tiltDeg * math.pi / 180;
    final cosA = math.cos(a), sinA = math.sin(a);
    final people = [
      for (final p in raw)
        if (p.length >= LandmarkIndex.count) _Person(p, cx, cy, cosA, sinA)
    ];
    if (people.isEmpty) return PostureReading.unknown(t);

    final user = _select(people, t);
    if (user == null) return PostureReading.unknown(t);
    final side = _side ?? user.visibleSide();
    if (_side == null) _voteSide(user);
    final f = _features(user, side);
    if (f == null) return PostureReading.unknown(t);

    _lastHip = f.hip;
    _lastHipT = t;

    final posture = _classify(f);
    _updateCalibration(f, posture, t);
    final takbir = _updateTakbir(f, user, side, t);

    final cal = _calHipNorm;
    return PostureReading(
      tMs: t,
      posture: posture,
      confidence: f.meanConf,
      takbirRaise: takbir,
      hipHeightRatio:
          (f.hipNorm != null && cal != null) ? f.hipNorm! / cal : null,
      torsoAngleDeg: f.torsoDeg,
    );
  }

  // -------------------------------------------------------------------------
  // Person selection and side lock

  _Person? _select(List<_Person> people, int t) {
    final calTorso = _calTorsoPx;
    double? torsoOf(_Person p) =>
        p.torsoPx(_side ?? p.visibleSide(), config.minLandmarkConf);

    bool fits(double? len) =>
        calTorso == null ||
        (len != null &&
            (len - calTorso).abs() <= config.torsoTolerance * calTorso);

    if (people.length == 1) {
      final p = people.single;
      return fits(torsoOf(p)) ? p : null;
    }

    if (calTorso == null) {
      final sized = [
        for (final p in people)
          if (torsoOf(p) case final len?) (p, len)
      ]..sort((x, y) => y.$2.compareTo(x.$2));
      if (sized.isEmpty) return null;
      if (sized.length == 1) return sized.single.$1;
      return sized[0].$2 >= config.uncalibratedSizeRatio * sized[1].$2
          ? sized[0].$1
          : null;
    }

    final fitting = [
      for (final p in people)
        if (fits(torsoOf(p))) p
    ];
    if (fitting.isEmpty) return null;
    final last = _lastHip;
    final recent = last != null &&
        _lastHipT != null &&
        t - _lastHipT! <= config.hipMemoryMs;
    if (last == null) return fitting.length == 1 ? fitting.single : null;

    final side = _side;
    double dist(_Person p) {
      final h = p.hip(side ?? p.visibleSide());
      if (h.conf < config.minLandmarkConf) return double.infinity;
      return math.sqrt(math.pow(h.x - last.x, 2) + math.pow(h.y - last.y, 2)) /
          calTorso;
    }

    final ranked = [for (final p in fitting) (p, dist(p))]
      ..sort((x, y) => x.$2.compareTo(y.$2));
    final best = ranked.first;
    if (!best.$2.isFinite) return null;
    if (recent && best.$2 > config.maxHipJump) return null;
    if (ranked.length > 1) {
      final second = ranked[1].$2;
      // Unclear unless the best is near and clearly nearer than the next.
      if (!(best.$2 < 1.0 && second > 2 * best.$2 + 0.3)) return null;
    }
    return best.$1;
  }

  void _voteSide(_Person p) {
    final vis = p.visibilityScore();
    BodySide? byVis;
    if (vis.abs() >= 0.5) byVis = vis > 0 ? BodySide.right : BodySide.left;

    BodySide? byNose;
    final nose = p.pt(LandmarkIndex.nose);
    final le = p.pt(LandmarkIndex.leftEar), re = p.pt(LandmarkIndex.rightEar);
    final ear = le.conf >= re.conf ? le : re;
    final torso = p.torsoPx(p.visibleSide(), config.minLandmarkConf);
    if (nose.conf >= 0.5 &&
        ear.conf >= 0.5 &&
        torso != null &&
        (nose.x - ear.x).abs() > 0.05 * torso) {
      byNose = nose.x > ear.x ? BodySide.right : BodySide.left;
    }

    final vote = byVis == null
        ? byNose
        : (byNose == null || byNose == byVis ? byVis : null);
    if (vote == BodySide.left) _votesLeft++;
    if (vote == BodySide.right) _votesRight++;
    if (_votesLeft >= 5 && _votesLeft >= 4 * _votesRight) {
      _side = BodySide.left;
    } else if (_votesRight >= 5 && _votesRight >= 4 * _votesLeft) {
      _side = BodySide.right;
    }
  }

  // -------------------------------------------------------------------------
  // Features and rules

  _Features? _features(_Person p, BodySide side) {
    final c = config;
    final shoulder = p.pt(_idx(side, _J.shoulder));
    final hip = p.pt(_idx(side, _J.hip));
    if (shoulder.conf < c.minLandmarkConf || hip.conf < c.minLandmarkConf) {
      return null;
    }
    final dx = shoulder.x - hip.x, dy = shoulder.y - hip.y;
    final torsoPx = math.sqrt(dx * dx + dy * dy);
    if (torsoPx < 1e-6) return null;
    final torsoDeg = math.atan2(dx.abs(), -dy) * 180 / math.pi;

    final used = <double>[shoulder.conf, hip.conf];

    // Hip height: near hip and ankle; a far one only at farConf or more.
    final far = side == BodySide.left ? BodySide.right : BodySide.left;
    _Pt? hipH = hip;
    _Pt? ankle = p.pt(_idx(side, _J.ankle));
    if (ankle.conf < c.minLandmarkConf) {
      final fa = p.pt(_idx(far, _J.ankle));
      ankle = fa.conf >= c.farConf ? fa : null;
    }
    double? hipNorm;
    if (ankle != null) {
      hipNorm = (ankle.y - hipH.y) / torsoPx;
      used.add(ankle.conf);
    }

    // Head drop: nose, else the near ear.
    var head = p.pt(LandmarkIndex.nose);
    if (head.conf < c.minLandmarkConf) head = p.pt(_idx(side, _J.ear));
    double? drop;
    if (head.conf >= c.minLandmarkConf) {
      drop = (head.y - hip.y) / torsoPx;
      used.add(head.conf);
    }

    double? kneeDeg;
    final knee = p.pt(_idx(side, _J.knee));
    if (knee.conf >= c.kneeConf && ankle != null) {
      final ax = hip.x - knee.x, ay = hip.y - knee.y;
      final bx = ankle.x - knee.x, by = ankle.y - knee.y;
      final la = math.sqrt(ax * ax + ay * ay),
          lb = math.sqrt(bx * bx + by * by);
      if (la > 1e-6 && lb > 1e-6) {
        final cosK = ((ax * bx + ay * by) / (la * lb)).clamp(-1.0, 1.0);
        kneeDeg = math.acos(cosK) * 180 / math.pi;
        used.add(knee.conf);
      }
    }

    final mean = used.reduce((x, y) => x + y) / used.length;
    return _Features(
      torsoPx: torsoPx,
      torsoDeg: torsoDeg,
      hipNorm: hipNorm,
      drop: drop,
      kneeDeg: kneeDeg,
      meanConf: mean.clamp(0.0, 1.0),
      hip: hip,
      shoulder: shoulder,
    );
  }

  Posture _classify(_Features f) {
    final c = config;
    if (f.meanConf < c.minMeanConf) return Posture.unknown;
    final hn = f.hipNorm;
    if (hn == null) return Posture.unknown; // never from torso alone
    final cal = _calHipNorm;
    final r = hn / (cal ?? c.priorStandingNorm);
    final th = f.torsoDeg;
    final drop = f.drop;
    final knee = f.kneeDeg;
    final kneeStraight = knee == null || knee >= c.kneeStraightDeg;
    final kneeBent = knee == null || knee <= c.kneeBentDeg;

    if (r < c.prostrateHip && drop != null && drop >= c.prostrateDrop) {
      return kneeBent ? Posture.prostrating : Posture.unknown;
    }
    if (r <= c.sitHip && th < c.sitTorsoDeg) {
      return kneeBent ? Posture.sitting : Posture.unknown;
    }
    final standHip = cal == null ? c.uncalibratedStandHip : c.standHip;
    final standTorso =
        cal == null ? c.uncalibratedStandTorsoDeg : c.standTorsoDeg;
    if (r >= standHip && th < standTorso) {
      // Before calibration the hip height is only checked against a prior,
      // so standing also needs a reliably seen, straight knee.
      if (cal == null && knee == null) return Posture.unknown;
      return kneeStraight ? Posture.standing : Posture.unknown;
    }
    if (r >= c.bowHip &&
        th >= c.bowTorsoMinDeg &&
        th <= c.bowTorsoMaxDeg &&
        drop != null &&
        drop >= c.bowDropMin &&
        drop <= c.bowDropMax) {
      return kneeStraight ? Posture.bowing : Posture.unknown;
    }
    return Posture.unknown;
  }

  // -------------------------------------------------------------------------
  // Calibration

  void _updateCalibration(_Features f, Posture posture, int t) {
    final c = config;
    final hn = f.hipNorm;
    final prev = _prevHipNorm;
    _prevHipNorm = hn;
    if (_frozen) return;

    if (posture == Posture.bowing || posture == Posture.prostrating) {
      _nonStandingRun++;
      if (_calHipNorm != null &&
          _takbirT == null &&
          _nonStandingRun >= c.freezeAfterFrames) {
        _frozen = true;
        return;
      }
    } else {
      _nonStandingRun = 0;
    }

    // Steady upright frames with the hips high. Not tied to the posture
    // output: before calibration standing needs a visible knee, and the
    // calibration must also work with the knees hidden.
    final cal = _calHipNorm;
    final knee = f.kneeDeg;
    final steady = hn != null &&
        prev != null &&
        f.torsoDeg < c.steadyTorsoDeg &&
        (hn - prev).abs() < c.steadyDelta &&
        f.meanConf >= c.minMeanConf &&
        (knee == null || knee >= c.kneeStraightDeg) &&
        // Sanity against the prior, so a bad calibration cannot feed itself.
        hn / c.priorStandingNorm >= c.calibrationMinPrior &&
        (cal == null || hn / cal >= c.standHip);
    if (steady) {
      _samples.add(_Sample(t, hn, f.torsoPx));
    }

    final tk = _takbirT;
    final lo = (tk ?? t) - c.calibrationWindowMs;
    final hi = tk == null ? t : tk + c.takbirCalibAfterMs;
    _samples.removeWhere((s) => s.t < lo);
    final window = [
      for (final s in _samples)
        if (s.t <= hi) s
    ];
    if (window.length >= c.minCalibrationSamples) {
      _calHipNorm = _median([for (final s in window) s.hipNorm]);
      _calTorsoPx = _median([for (final s in window) s.torsoPx]);
    }
    if (tk != null && t > hi) {
      if (_calHipNorm != null) {
        _frozen = true;
        _samples.clear();
      } else {
        // Too little steady standing around the takbir (noise, dropouts).
        // Freezing now would leave the session uncalibrated for good: with
        // the knees hidden nothing could ever be classified standing, so
        // neither Qiyam could start. Fall back to the rolling calibration,
        // as after a missed takbir.
        _takbirT = null;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Takbir

  void _resetTakbir() {
    _levels.clear();
    _armDownT = null;
    _raised = false;
    _peak = 0;
    _rawPeak = 0;
    _base = 0;
    _aboveFrames = 0;
    _farSeen = 0;
    _farHigh = 0;
  }

  bool _updateTakbir(_Features f, _Person p, BodySide side, int t) {
    final c = config;
    final hn = f.hipNorm;
    final r = hn == null ? null : hn / (_calHipNorm ?? c.priorStandingNorm);
    // A frame without hip height (ankle not seen) neither breaks nor
    // advances a raise; a frame that is clearly not upright cancels it.
    if (f.torsoDeg >= c.takbirMaxTorsoDeg ||
        (r != null && r < c.takbirMinHip)) {
      _resetTakbir();
      return false;
    }
    if (r == null) return false;
    final elbow = p.pt(_idx(side, _J.elbow));
    final wrist = p.pt(_idx(side, _J.wrist));
    if (elbow.conf < c.minMeanConf || wrist.conf < c.minMeanConf) return false;

    double level(_Pt q) {
      final ax = f.shoulder.x - f.hip.x, ay = f.shoulder.y - f.hip.y;
      return ((q.x - f.hip.x) * ax + (q.y - f.hip.y) * ay) /
          (ax * ax + ay * ay);
    }

    final wl = level(wrist);
    final el = level(elbow);
    _levels.add(wl);
    if (_levels.length > c.takbirSmoothFrames) _levels.removeAt(0);
    final sl = _levels.reduce((x, y) => x + y) / _levels.length;

    if (!_raised) {
      if (wl < el) {
        _armDownT = t;
        _base = sl;
        return false;
      }
      // The resting level the raise starts from: the lowest smoothed level
      // since the last arm-down frame.
      if (sl < _base) _base = sl;
      final down = _armDownT;
      if (down != null && sl >= c.takbirLevel && t - down <= c.takbirWindowMs) {
        _raised = true;
        _peak = sl;
        // The frames in the smoothing window are part of the raise too.
        _rawPeak = _levels.reduce(math.max);
        _aboveFrames = 1;
        _farSeen = 0;
        _farHigh = 0;
        _observeFar(p, side, f, level);
      }
      return false;
    }

    // Raised: wait for the hands to come down within the window.
    if (t - _armDownT! > c.takbirWindowMs) {
      _raised = false;
      _armDownT = null; // the arm must go down again first
      return false;
    }
    _observeFar(p, side, f, level);
    if (sl > _peak) _peak = sl;
    if (wl > _rawPeak) _rawPeak = wl;
    if (sl >= c.takbirLevel) _aboveFrames++;
    if (sl <= _peak - c.takbirDrop && sl < c.takbirLevel) {
      final oneHanded = _farSeen >= 2 && _farHigh == 0;
      final fire = _aboveFrames >= c.takbirMinAboveFrames &&
          !oneHanded &&
          _peak - _base >= c.takbirMinRise &&
          _rawPeak >= c.takbirMinRawPeak;
      _raised = false;
      _armDownT = null;
      if (fire && _takbirT == null) _takbirT = t;
      return fire;
    }
    return false;
  }

  void _observeFar(
      _Person p, BodySide side, _Features f, double Function(_Pt) level) {
    final far = side == BodySide.left ? BodySide.right : BodySide.left;
    final w = p.pt(_idx(far, _J.wrist));
    if (w.conf < config.farConf) return;
    _farSeen++;
    if (level(w) >= config.takbirFarLevel) _farHigh++;
  }
}

// ---------------------------------------------------------------------------
// Helpers

enum _J { ear, shoulder, elbow, wrist, hip, knee, ankle }

int _idx(BodySide side, _J j) {
  final left = side == BodySide.left;
  return switch (j) {
    _J.ear => left ? LandmarkIndex.leftEar : LandmarkIndex.rightEar,
    _J.shoulder =>
      left ? LandmarkIndex.leftShoulder : LandmarkIndex.rightShoulder,
    _J.elbow => left ? LandmarkIndex.leftElbow : LandmarkIndex.rightElbow,
    _J.wrist => left ? LandmarkIndex.leftWrist : LandmarkIndex.rightWrist,
    _J.hip => left ? LandmarkIndex.leftHip : LandmarkIndex.rightHip,
    _J.knee => left ? LandmarkIndex.leftKnee : LandmarkIndex.rightKnee,
    _J.ankle => left ? LandmarkIndex.leftAnkle : LandmarkIndex.rightAnkle,
  };
}

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

class _Pt {
  final double x, y, conf;
  const _Pt(this.x, this.y, this.conf);
}

/// One detected person, tilt-corrected lazily.
class _Person {
  final List<Landmark> lm;
  final double cx, cy, cosA, sinA;
  _Person(this.lm, this.cx, this.cy, this.cosA, this.sinA);

  _Pt pt(int i) {
    final l = lm[i];
    final dx = l.x - cx, dy = l.y - cy;
    return _Pt(cx + dx * cosA - dy * sinA, cy + dx * sinA + dy * cosA, l.conf);
  }

  _Pt hip(BodySide side) => pt(_idx(side, _J.hip));

  double? torsoPx(BodySide side, double minConf) {
    final s = pt(_idx(side, _J.shoulder)), h = pt(_idx(side, _J.hip));
    if (s.conf < minConf || h.conf < minConf) return null;
    return math.sqrt(math.pow(s.x - h.x, 2) + math.pow(s.y - h.y, 2));
  }

  /// Summed right-minus-left confidence over the paired landmarks.
  double visibilityScore() {
    var s = 0.0;
    for (final j in _J.values) {
      s += lm[_idx(BodySide.right, j)].conf - lm[_idx(BodySide.left, j)].conf;
    }
    return s;
  }

  BodySide visibleSide() =>
      visibilityScore() >= 0 ? BodySide.right : BodySide.left;
}

class _Features {
  final double torsoPx;
  final double torsoDeg;
  final double? hipNorm;
  final double? drop;
  final double? kneeDeg;
  final double meanConf;
  final _Pt hip;
  final _Pt shoulder;

  const _Features({
    required this.torsoPx,
    required this.torsoDeg,
    required this.hipNorm,
    required this.drop,
    required this.kneeDeg,
    required this.meanConf,
    required this.hip,
    required this.shoulder,
  });
}

class _Sample {
  final int t;
  final double hipNorm;
  final double torsoPx;
  const _Sample(this.t, this.hipNorm, this.torsoPx);
}
