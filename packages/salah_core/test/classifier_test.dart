import 'dart:math' as math;

import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Hand-built frames
//
// A figure is given in body coordinates: x forward (the facing direction),
// y up, pixels. It is rendered like the synthetic generator: x = 240 +
// facing * wx, y = 600 - wy, near side at high confidence, far side (offset
// by a few pixels) at low confidence.

typedef P = (double, double);

class Fig {
  P ankle, knee, hip, shoulder, elbow, wrist, ear, nose;
  Fig({
    required this.ankle,
    required this.knee,
    required this.hip,
    required this.shoulder,
    required this.elbow,
    required this.wrist,
    required this.ear,
    required this.nose,
  });

  Fig copy() => Fig(
      ankle: ankle,
      knee: knee,
      hip: hip,
      shoulder: shoulder,
      elbow: elbow,
      wrist: wrist,
      ear: ear,
      nose: nose);
}

/// Torso 150 px, standing hip height (ankle -> hip) 240 px: 1.6 torso
/// lengths. Arms down: wrist below the elbow.
Fig standingFig() => Fig(
      ankle: (0, 10),
      knee: (0, 130),
      hip: (0, 250),
      shoulder: (0, 400),
      elbow: (0, 320),
      wrist: (0, 240),
      ear: (0, 465),
      nose: (20, 470),
    );

/// Sitting on the heels: hip height 30 px (0.125 of standing), torso upright.
Fig sittingFig() => Fig(
      ankle: (-60, 40),
      knee: (80, 15),
      hip: (-20, 70),
      shoulder: (-10, 220),
      elbow: (10, 150),
      wrist: (60, 90),
      ear: (-5, 285),
      nose: (15, 290),
    );

/// Sujood: hip height 90 px (0.375), nose 0.73 torso lengths below the hip.
Fig prostratingFig() => Fig(
      ankle: (-60, 40),
      knee: (40, 15),
      hip: (20, 130),
      shoulder: (160, 60),
      elbow: (190, 20),
      wrist: (220, 5),
      ear: (230, 30),
      nose: (240, 15),
    );

/// Ruku: hips at standing height, torso about 88 degrees, head level.
Fig bowingFig() => Fig(
      ankle: (0, 10),
      knee: (5, 130),
      hip: (-10, 250),
      shoulder: (140, 255),
      elbow: (130, 180),
      wrist: (20, 140),
      ear: (200, 250),
      nose: (215, 230),
    );

class Conf {
  final double near, far, knee, ankle, nose;
  final double? farAnkle, farWrist;
  const Conf({
    this.near = 0.95,
    this.far = 0.4,
    this.knee = 0.95,
    this.ankle = 0.95,
    this.nose = 0.95,
    this.farAnkle,
    this.farWrist,
  });
}

bool _isLeft(int i) => (i >= 1 && i <= 3) || (i >= 7 && i.isOdd);

List<Landmark> render(Fig f,
    {int facing = 1,
    double x0 = 240,
    double y0 = 600,
    double scale = 1,
    Conf conf = const Conf(),
    P? farWristPos,
    double rollDeg = 0}) {
  // Facing right shows the right side.
  bool far(int i) =>
      i != LandmarkIndex.nose && (facing > 0 ? _isLeft(i) : !_isLeft(i));
  P at(int i) => switch (i) {
        0 => f.nose,
        >= 1 && <= 6 || 9 || 10 => f.nose,
        7 || 8 => f.ear,
        11 || 12 => f.shoulder,
        13 || 14 => f.elbow,
        15 || 16 || 17 || 18 || 19 || 20 || 21 || 22 => f.wrist,
        23 || 24 => f.hip,
        25 || 26 => f.knee,
        _ => f.ankle,
      };
  final r = -rollDeg * math.pi / 180;
  final out = <Landmark>[];
  for (var i = 0; i < LandmarkIndex.count; i++) {
    final isFar = far(i);
    var p = at(i);
    if (isFar &&
        farWristPos != null &&
        (i == LandmarkIndex.leftWrist || i == LandmarkIndex.rightWrist)) {
      p = farWristPos;
    }
    var x = x0 + facing * p.$1 * scale + (isFar ? -facing * 4 : 0);
    var y = y0 - p.$2 * scale + (isFar ? 1 : 0);
    if (rollDeg != 0) {
      final dx = x - 240, dy = y - 320;
      x = 240 + dx * math.cos(r) - dy * math.sin(r);
      y = 320 + dx * math.sin(r) + dy * math.cos(r);
    }
    final isKnee = i == LandmarkIndex.leftKnee || i == LandmarkIndex.rightKnee;
    final isAnkle =
        i == LandmarkIndex.leftAnkle || i == LandmarkIndex.rightAnkle;
    final isWrist =
        i == LandmarkIndex.leftWrist || i == LandmarkIndex.rightWrist;
    double c;
    if (isFar) {
      c = isAnkle && conf.farAnkle != null
          ? conf.farAnkle!
          : (isWrist && conf.farWrist != null ? conf.farWrist! : conf.far);
    } else if (isKnee) {
      c = conf.knee;
    } else if (isAnkle) {
      c = conf.ankle;
    } else if (i == LandmarkIndex.nose) {
      c = conf.nose;
    } else {
      c = conf.near;
    }
    out.add(Landmark(x, y, 0, c));
  }
  return out;
}

PoseFrame frameOf(int tMs, List<List<Landmark>> people, {double tilt = 0}) =>
    PoseFrame(
      tMs: tMs,
      landmarks: people.length == 1 ? people.single : null,
      people: people,
      imageW: 480,
      imageH: 640,
      tiltDeg: tilt,
    );

PoseFrame one(int tMs, Fig f,
        {int facing = 1, Conf conf = const Conf(), double tilt = 0}) =>
    frameOf(tMs, [render(f, facing: facing, conf: conf)], tilt: tilt);

/// Feeds [n] standing frames at 15 fps from [t0]; returns the next time.
int feedStanding(RuleBasedClassifier c,
    {int t0 = 0, int n = 30, int facing = 1}) {
  var t = t0;
  for (var i = 0; i < n; i++) {
    c.classify(one(t, standingFig(), facing: facing));
    t += 67;
  }
  return t;
}

/// A calibrated classifier (calibration frozen by a short bow).
RuleBasedClassifier calibrated({int facing = 1}) {
  final c = RuleBasedClassifier();
  var t = feedStanding(c, facing: facing);
  for (var i = 0; i < 5; i++) {
    c.classify(one(t, bowingFig(), facing: facing));
    t += 67;
  }
  return c;
}

/// Wrist at [level] of hip -> shoulder (0 at the hip, 1 at the shoulder) in
/// [standingFig], elbow at [elbowLevel].
Fig armsAt(double level, {double elbowLevel = 0.47}) => standingFig()
  ..wrist = (15, 250 + 150 * level)
  ..elbow = (8, 250 + 150 * elbowLevel);

/// [lm] with Gaussian pixel noise of standard deviation [sigma] on x and y.
List<Landmark> jitter(List<Landmark> lm, math.Random rng, double sigma) {
  double g() {
    final u = 1 - rng.nextDouble(), v = rng.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  return [
    for (final l in lm)
      Landmark(l.x + sigma * g(), l.y + sigma * g(), l.z, l.conf)
  ];
}

/// A takbir-like raise: arms down, up to [peak] over [upMs], held [holdMs],
/// down to [rest] over [downMs]. Returns the readings with takbirRaise set.
List<int> raiseEvents(
  RuleBasedClassifier c, {
  required int t0,
  double peak = 1.2,
  double rest = -0.07,
  int upMs = 400,
  int holdMs = 200,
  int downMs = 400,
  int facing = 1,
  Fig Function(double level)? fig,
  Conf conf = const Conf(),
  P? farWristPos,
  List<Landmark> Function(List<Landmark>)? noise,
}) {
  final events = <int>[];
  final make = fig ?? (double l) => armsAt(l, elbowLevel: l > 0.8 ? 0.7 : 0.47);
  var t = t0;
  void emit(double level) {
    final lm = render(make(level),
        facing: facing, conf: conf, farWristPos: farWristPos);
    final r = c.classify(frameOf(t, [noise == null ? lm : noise(lm)]));
    if (r.takbirRaise) events.add(t);
    t += 67;
  }

  for (var i = 0; i < 5; i++) {
    emit(-0.07);
  }
  final up = (upMs / 67).ceil(), hold = (holdMs / 67).ceil();
  final down = (downMs / 67).ceil();
  for (var i = 1; i <= up; i++) {
    emit(-0.07 + (peak + 0.07) * i / up);
  }
  for (var i = 0; i < hold; i++) {
    emit(peak);
  }
  for (var i = 1; i <= down; i++) {
    emit(peak + (rest - peak) * i / down);
  }
  for (var i = 0; i < 15; i++) {
    emit(rest);
  }
  return events;
}

// ---------------------------------------------------------------------------
// Evaluation on generated prayers

class Confusion {
  final m = List.generate(5, (_) => List.filled(5, 0));

  void add(Posture label, Posture out) => m[label.index][out.index]++;

  int row(Posture p) => m[p.index].reduce((a, b) => a + b);
  int get total =>
      [for (final p in Posture.values) row(p)].reduce((a, b) => a + b);
  int get correct =>
      [for (var i = 0; i < 5; i++) m[i][i]].reduce((a, b) => a + b);
  double get accuracy => correct / total;
  double recall(Posture p) => m[p.index][p.index] / row(p);
  int count(Posture label, Posture out) => m[label.index][out.index];

  /// Standing read as sitting plus sitting read as standing, as a fraction
  /// of standing and sitting frames.
  double get standSit =>
      (count(Posture.standing, Posture.sitting) +
          count(Posture.sitting, Posture.standing)) /
      (row(Posture.standing) + row(Posture.sitting));

  String table(String title) {
    String cell(Object v) => '$v'.padLeft(8);
    final b = StringBuffer()
      ..writeln('$title: accuracy ${(100 * accuracy).toStringAsFixed(2)} % '
          'over $total labelled frames; stand<->sit '
          '${(100 * standSit).toStringAsFixed(3)} %; sujood recall '
          '${(100 * recall(Posture.prostrating)).toStringAsFixed(2)} %')
      ..writeln('label \\ out '
          '${Posture.values.map((p) => cell(p.name.substring(0, 5))).join()}');
    for (final l in Posture.values.take(4)) {
      b.writeln(
          '${l.name.padRight(12)}${Posture.values.map((o) => cell(count(l, o))).join()}');
    }
    return b.toString();
  }
}

/// Per-frame classifier output against labels that are not unknown.
Confusion evaluate(Iterable<SyntheticPrayer> prayers) {
  final cm = Confusion();
  for (final s in prayers) {
    final c = RuleBasedClassifier();
    for (final f in s.recording.frames) {
      final r = c.classify(f);
      final label = s.labels.postureAt(f.tMs);
      if (label != null && label != Posture.unknown) cm.add(label, r.posture);
    }
  }
  return cm;
}

List<int> takbirDetections(SyntheticPrayer s) {
  final c = RuleBasedClassifier();
  return [
    for (final f in s.recording.frames)
      if (c.classify(f).takbirRaise) f.tMs
  ];
}

const fast = 0.05;

List<SyntheticPrayer> cases(int seedBase, SyntheticOptions Function(int) opts,
        {int perCase = 1}) =>
    [
      for (var k = 0; k < perCase; k++)
        for (final c in SyntheticCase.values)
          generateSyntheticPrayer(c,
              seed: seedBase + 100 * k + c.index, options: opts(k)),
    ];

void main() {
  group('rules on hand-built frames', () {
    test('heartbeat and empty frames are unknown with null raw values', () {
      final c = RuleBasedClassifier();
      expect(c.classify(const PoseFrame.heartbeat(100)),
          const PostureReading.unknown(100));
      expect(c.classify(frameOf(167, const [])),
          const PostureReading.unknown(167));
    });

    test('standing before calibration: standing, ratio null, torso reported',
        () {
      final c = RuleBasedClassifier();
      final r = c.classify(one(0, standingFig()));
      expect(r.posture, Posture.standing);
      expect(r.hipHeightRatio, isNull);
      expect(r.torsoAngleDeg, closeTo(0, 0.01));
      expect(r.confidence, closeTo(0.95, 1e-9));
      expect(c.isCalibrated, isFalse);
    });

    test('steady standing calibrates: ratio 1.0, torso length learned', () {
      final c = RuleBasedClassifier();
      final t = feedStanding(c, n: 12);
      expect(c.isCalibrated, isTrue);
      expect(c.calibratedHipNorm, closeTo(240 / 150, 1e-9));
      expect(c.calibratedTorsoPx, closeTo(150, 1e-9));
      final r = c.classify(one(t, standingFig()));
      expect(r.posture, Posture.standing);
      expect(r.hipHeightRatio, closeTo(1.0, 1e-9));
    });

    test('knees hidden: unknown before calibration, standing after', () {
      final c = RuleBasedClassifier();
      const noKnee = Conf(knee: 0.2);
      final first = c.classify(one(0, standingFig(), conf: noKnee));
      expect(first.posture, Posture.unknown);
      expect(first.hipHeightRatio, isNull);
      expect(first.torsoAngleDeg, closeTo(0, 0.01));
      var t = 0;
      for (var i = 0; i < 12; i++) {
        c.classify(one(t += 67, standingFig(), conf: noKnee));
      }
      expect(c.isCalibrated, isTrue);
      final r = c.classify(one(t += 67, standingFig(), conf: noKnee));
      expect(r.posture, Posture.standing);
      expect(r.hipHeightRatio, closeTo(1, 1e-9));
      // Sitting is recognised before calibration too (from the prior).
      final c2 = RuleBasedClassifier();
      expect(c2.classify(one(0, sittingFig(), conf: noKnee)).posture,
          Posture.sitting);
    });

    test('too few standing frames do not calibrate', () {
      final c = RuleBasedClassifier();
      feedStanding(c, n: 5);
      expect(c.isCalibrated, isFalse);
    });

    for (final facing in [1, -1]) {
      test('each posture, facing ${facing > 0 ? 'right' : 'left'}', () {
        final c = calibrated(facing: facing);
        expect(c.nearSide, facing > 0 ? BodySide.right : BodySide.left);
        var t = 5000;
        PostureReading cls(Fig f) =>
            c.classify(one(t += 67, f, facing: facing));

        final st = cls(standingFig());
        expect(st.posture, Posture.standing);
        expect(st.hipHeightRatio, closeTo(1, 1e-9));

        final bw = cls(bowingFig());
        expect(bw.posture, Posture.bowing);
        expect(bw.torsoAngleDeg, closeTo(88.1, 0.2));
        // Same hip height, torso length 150.08 px instead of 150.
        expect(
            bw.hipHeightRatio, closeTo(150 / math.sqrt(150 * 150 + 25), 1e-9));

        final pr = cls(prostratingFig());
        expect(pr.posture, Posture.prostrating);
        // Torso length here is sqrt(140^2 + 70^2) px.
        expect(pr.hipHeightRatio,
            closeTo(90 / math.sqrt(140 * 140 + 70 * 70) / 1.6, 1e-9));

        final si = cls(sittingFig());
        expect(si.posture, Posture.sitting);
        // Torso length here is sqrt(10^2 + 150^2) px.
        expect(si.hipHeightRatio,
            closeTo(30 / math.sqrt(10 * 10 + 150 * 150) / 1.6, 1e-9));
        expect(si.torsoAngleDeg, lessThan(5));
      });
    }

    test('standing needs torso under 20 degrees', () {
      final c = calibrated();
      // Lean the torso 25 degrees forward about the hip.
      final f = standingFig()
        ..shoulder = (
          150 * math.sin(25 * math.pi / 180),
          250 + 150 * math.cos(25 * math.pi / 180)
        )
        ..ear = (80, 460)
        ..nose = (100, 465);
      final r = c.classify(one(9000, f));
      expect(r.torsoAngleDeg, closeTo(25, 0.01));
      expect(r.posture, Posture.unknown);
      final f19 = standingFig()
        ..shoulder = (
          150 * math.sin(19 * math.pi / 180),
          250 + 150 * math.cos(19 * math.pi / 180)
        );
      expect(c.classify(one(9067, f19)).posture, Posture.standing);
    });

    test('hip height between sitting and standing is unknown', () {
      final c = calibrated();
      for (final ratio in [0.4, 0.6, 0.75]) {
        // Upright, hips at [ratio] of standing (half-risen, kneeling).
        final hipY = 10 + 240 * ratio;
        final f = Fig(
          ankle: (-60, 10),
          knee: (60, 15),
          hip: (0, hipY),
          shoulder: (0, hipY + 150),
          elbow: (0, hipY + 70),
          wrist: (0, hipY - 10),
          ear: (0, hipY + 215),
          nose: (20, hipY + 220),
        );
        final r = c.classify(one(9000, f, conf: const Conf(knee: 0.2)));
        expect(r.posture, Posture.unknown, reason: 'ratio $ratio');
        expect(r.hipHeightRatio, closeTo(ratio, 1e-9));
      }
    });

    test('hip height thresholds: 0.8 stands, 0.35 sits', () {
      final c = calibrated();
      Fig upright(double ratio) {
        final hipY = 10 + 240 * ratio;
        return Fig(
          ankle: (0, 10),
          knee: (0, (hipY + 10) / 2),
          hip: (0, hipY),
          shoulder: (0, hipY + 150),
          elbow: (0, hipY + 70),
          wrist: (0, hipY - 10),
          ear: (0, hipY + 215),
          nose: (20, hipY + 220),
        );
      }

      const noKnee = Conf(knee: 0.2);
      expect(c.classify(one(9000, upright(0.81), conf: noKnee)).posture,
          Posture.standing);
      expect(c.classify(one(9067, upright(0.79), conf: noKnee)).posture,
          Posture.unknown);
      expect(c.classify(one(9134, upright(0.34), conf: noKnee)).posture,
          Posture.sitting);
      expect(c.classify(one(9201, upright(0.36), conf: noKnee)).posture,
          Posture.unknown);
    });

    test('prostrating needs the nose 0.4 torso lengths below the hip', () {
      final c = calibrated();
      // Torso length here is ~156.5 px; nose 115 px below the hip = 0.73.
      expect(
          c.classify(one(9000, prostratingFig())).posture, Posture.prostrating);
      // Head raised: nose 0.3 torso lengths below the hip.
      final f = prostratingFig()
        ..nose = (240, 130 - 0.3 * 156.5)
        ..ear = (230, 130 - 0.3 * 156.5 + 10);
      expect(c.classify(one(9067, f)).posture, Posture.unknown);
    });

    test('bowing needs torso 55..100 degrees and hips high', () {
      final c = calibrated();
      Fig lean(double deg) => bowingFig()
        ..shoulder = (
          -10 + 150 * math.sin(deg * math.pi / 180),
          250 + 150 * math.cos(deg * math.pi / 180)
        );
      expect(c.classify(one(9000, lean(56))).posture, Posture.bowing);
      expect(c.classify(one(9067, lean(99))).posture, Posture.bowing);
      expect(c.classify(one(9134, lean(50))).posture, Posture.unknown);
      expect(c.classify(one(9201, lean(105))).posture, Posture.unknown);
    });

    test('never standing from the torso alone: no ankle, no standing', () {
      final c = calibrated();
      final r = c.classify(
          one(9000, standingFig(), conf: const Conf(ankle: 0.1, knee: 0.1)));
      expect(r.posture, Posture.unknown);
      expect(r.hipHeightRatio, isNull);
      expect(r.torsoAngleDeg, closeTo(0, 0.01));
    });

    test('far ankle is used for hip height only at confidence >= 0.7', () {
      final c = calibrated();
      final ok = c.classify(one(9000, standingFig(),
          conf: const Conf(ankle: 0.1, farAnkle: 0.8)));
      expect(ok.posture, Posture.standing);
      // The far ankle is drawn 1 px lower.
      expect(ok.hipHeightRatio, closeTo(241 / 240, 1e-6));
      final low = c.classify(one(9067, standingFig(),
          conf: const Conf(ankle: 0.1, farAnkle: 0.65)));
      expect(low.hipHeightRatio, isNull);
      expect(low.posture, Posture.unknown);
    });

    test('mean confidence under 0.5 is unknown, raw values still reported', () {
      final c = calibrated();
      final r = c.classify(one(9000, standingFig(),
          conf: const Conf(near: 0.45, ankle: 0.45, nose: 0.45, knee: 0.45)));
      expect(r.posture, Posture.unknown);
      expect(r.confidence, closeTo(0.45, 1e-9));
      expect(r.hipHeightRatio, closeTo(1, 1e-9));
      expect(r.torsoAngleDeg, closeTo(0, 0.01));
    });

    test('knee angle vetoes only when the knee is seen at >= 0.7', () {
      final c = calibrated();
      // Standing geometry but the knee drawn far forward (bent ~100 deg).
      final bent = standingFig()..knee = (100, 130);
      expect(c.classify(one(9000, bent)).posture, Posture.unknown);
      expect(c.classify(one(9067, bent, conf: const Conf(knee: 0.6))).posture,
          Posture.standing);
      // Sitting with a straight knee (impossible): vetoed.
      final straight = sittingFig()..knee = (-40, 55);
      expect(c.classify(one(9134, straight)).posture, Posture.unknown);
      expect(
          c.classify(one(9201, straight, conf: const Conf(knee: 0.5))).posture,
          Posture.sitting);
    });

    test('tilt is corrected with frame.tiltDeg', () {
      final c = calibrated();
      final rolled = render(standingFig(), rollDeg: 12);
      final raw = c.classify(frameOf(9000, [rolled]));
      expect(raw.torsoAngleDeg, closeTo(12, 0.01));
      final fixed = c.classify(frameOf(9067, [rolled], tilt: 12));
      expect(fixed.torsoAngleDeg, closeTo(0, 0.01));
      expect(fixed.posture, Posture.standing);
      expect(fixed.hipHeightRatio, closeTo(1, 1e-9));
    });

    test('near side locks from visibility and nose direction', () {
      for (final facing in [1, -1]) {
        final c = RuleBasedClassifier();
        expect(c.nearSide, isNull);
        feedStanding(c, n: 6, facing: facing);
        expect(c.nearSide, facing > 0 ? BodySide.right : BodySide.left);
      }
    });

    test('far-side landmarks never drive the posture', () {
      final c = calibrated();
      // Far side drawn as if sitting (a left/right swap on the hidden side).
      final near = render(standingFig());
      final farSit = render(sittingFig());
      final mixed = [
        for (var i = 0; i < LandmarkIndex.count; i++)
          _isLeft(i) ? farSit[i] : near[i]
      ];
      final r = c.classify(frameOf(9000, [mixed]));
      expect(r.posture, Posture.standing);
      expect(r.hipHeightRatio, closeTo(1, 1e-9));
    });

    test('reset clears side lock and calibration', () {
      final c = calibrated();
      expect(c.isCalibrated, isTrue);
      c.reset();
      expect(c.isCalibrated, isFalse);
      expect(c.nearSide, isNull);
      expect(c.classify(one(0, standingFig())).hipHeightRatio, isNull);
    });
  });

  group('calibration', () {
    test('missed takbir: calibrates from standing, freezes at the first bow',
        () {
      final c = RuleBasedClassifier();
      var t = feedStanding(c, n: 40);
      expect(c.isCalibrated, isTrue);
      expect(c.isCalibrationFrozen, isFalse);
      for (var i = 0; i < 4; i++) {
        c.classify(one(t += 67, bowingFig()));
      }
      expect(c.isCalibrationFrozen, isTrue);
      // Standing taller later (e.g. on tiptoe) does not move the calibration.
      final tall = standingFig()
        ..hip = (0, 270)
        ..shoulder = (0, 420)
        ..elbow = (0, 340)
        ..wrist = (0, 260);
      for (var i = 0; i < 30; i++) {
        c.classify(one(t += 67, tall));
      }
      expect(c.calibratedHipNorm, closeTo(1.6, 1e-9));
    });

    test('follows the latest standing before the takbir, then freezes', () {
      final c = RuleBasedClassifier();
      // A long wait standing slightly differently first.
      final early = standingFig()
        ..hip = (0, 235)
        ..shoulder = (0, 385)
        ..elbow = (0, 305)
        ..wrist = (0, 225);
      var t = 0;
      for (var i = 0; i < 60; i++) {
        c.classify(one(t += 67, early));
      }
      expect(c.calibratedHipNorm, closeTo(225 / 150, 1e-9));
      t = feedStanding(c, t0: t, n: 60);
      expect(c.calibratedHipNorm, closeTo(1.6, 1e-9));
      final events = raiseEvents(c, t0: t);
      expect(events, hasLength(1));
      // Frozen after T + 1 s: standing differently changes nothing.
      for (var i = 0; i < 40; i++) {
        c.classify(one(events.single + 1500 + 67 * i, early));
      }
      expect(c.isCalibrationFrozen, isTrue);
      expect(c.calibratedHipNorm, closeTo(1.6, 1e-9));
    });

    test(
        'takbir without enough steady standing: keeps calibrating instead '
        'of freezing uncalibrated (knees hidden)', () {
      // Regression (replay harness, batch seed 7777 #123): a noisy, small
      // user raised the hands under a second after appearing. The window
      // around the takbir had fewer than 8 steady frames, the calibration was
      // frozen while still null, and with the knees hidden nothing was ever
      // classified standing again: both recitations were missed.
      final c = RuleBasedClassifier();
      const noKnee = Conf(knee: 0.2);
      var n = 0;
      // Ankle jitter of 12 px (0.08 torso lengths) between frames: no frame
      // is steady, so the raise itself cannot calibrate.
      Fig jittery(double level) =>
          armsAt(level, elbowLevel: 0.47)..ankle = (0, (n++).isEven ? 10 : 22);
      final events =
          raiseEvents(c, t0: 0, fig: jittery, conf: noKnee, rest: -0.07);
      expect(events, hasLength(1));
      expect(c.isCalibrated, isFalse);
      // Steady standing in qiyam afterwards (more than 1 s after the takbir).
      var t = events.single + 2000;
      for (var i = 0; i < 20; i++) {
        c.classify(one(t += 67, standingFig(), conf: noKnee));
      }
      expect(c.isCalibrated, isTrue);
      final r = c.classify(one(t += 67, standingFig(), conf: noKnee));
      expect(r.posture, Posture.standing);
      expect(r.hipHeightRatio, closeTo(1, 1e-9));
      // It still freezes at the first bow, as after a missed takbir.
      for (var i = 0; i < 4; i++) {
        c.classify(one(t += 67, bowingFig(), conf: noKnee));
      }
      expect(c.isCalibrationFrozen, isTrue);
    });

    test('never calibrates from sitting', () {
      final c = RuleBasedClassifier();
      var t = 0;
      for (var i = 0; i < 60; i++) {
        final r = c.classify(one(t += 67, sittingFig()));
        expect(r.posture, Posture.sitting);
      }
      expect(c.isCalibrated, isFalse);
    });
  });

  group('person selection', () {
    List<Landmark> user(Fig f) => render(f);
    List<Landmark> child(Fig f, {double x0 = 400}) =>
        render(f, x0: x0, scale: 0.6, facing: -1);

    test('follows the user past a smaller child', () {
      final c = calibrated();
      var t = 6000;
      for (final f in [standingFig(), bowingFig(), prostratingFig()]) {
        for (final order in [0, 1]) {
          final people = [user(f), child(standingFig())];
          final r = c.classify(
              frameOf(t += 67, order == 0 ? people : people.reversed.toList()));
          expect(r.posture, isNot(Posture.unknown));
          expect(r.hipHeightRatio, isNotNull);
        }
      }
      // The child copying sujood does not turn the user's standing into it.
      final r = c.classify(frameOf(
          t += 67, [child(prostratingFig(), x0: 100), user(standingFig())]));
      expect(r.posture, Posture.standing);
    });

    test('a single person of the wrong size is lost tracking', () {
      final c = calibrated();
      final r = c.classify(frameOf(6000, [child(standingFig())]));
      expect(r, const PostureReading.unknown(6000));
    });

    test('two people of the user\'s size at similar distance: unknown', () {
      final c = calibrated();
      final r = c.classify(frameOf(6000, [
        render(standingFig(), x0: 200),
        render(standingFig(), x0: 280),
      ]));
      expect(r, const PostureReading.unknown(6000));
    });

    test('a same-size second person far away does not confuse it', () {
      final c = calibrated();
      final r = c.classify(frameOf(6000, [
        render(standingFig(), x0: 450, facing: -1),
        render(standingFig()),
      ]));
      expect(r.posture, Posture.standing);
      expect(r.hipHeightRatio, closeTo(1, 1e-9));
    });

    test('before calibration: the clearly largest person, else unknown', () {
      final c = RuleBasedClassifier();
      final r =
          c.classify(frameOf(0, [child(standingFig()), user(standingFig())]));
      expect(r.posture, Posture.standing);
      final c2 = RuleBasedClassifier();
      final r2 = c2.classify(frameOf(0, [
        render(standingFig(), x0: 120),
        render(standingFig(), x0: 360, scale: 0.9),
      ]));
      expect(r2, const PostureReading.unknown(0));
    });
  });

  group('takbir raise', () {
    test('raises to ears, shoulders and chest fire once, on the way down', () {
      for (final peak in [1.25, 0.95, 0.72]) {
        for (final facing in [1, -1]) {
          final c = RuleBasedClassifier();
          final t = feedStanding(c, n: 20, facing: facing);
          final ev = raiseEvents(c, t0: t, peak: peak, facing: facing);
          expect(ev, hasLength(1), reason: 'peak $peak facing $facing');
          // 5 rest frames + 6 up + 3 hold, then the first frames down.
          final downStart = t + 67 * (5 + 6 + 3);
          expect(ev.single - downStart, inInclusiveRange(0, 67 * 6));
        }
      }
    });

    test('raise ending in folded hands (chest) still fires', () {
      final c = RuleBasedClassifier();
      final t = feedStanding(c, n: 20);
      expect(raiseEvents(c, t0: t, peak: 0.8, rest: 0.55), hasLength(1));
    });

    test('folding the hands on the chest without a raise does not fire', () {
      final c = RuleBasedClassifier();
      final t = feedStanding(c, n: 20);
      // Rises to 0.62 and stays there.
      expect(
          raiseEvents(c, t0: t, peak: 0.62, rest: 0.62, holdMs: 3000), isEmpty);
    });

    test('folded hands with 6-8 px noise for 30 s: no takbir', () {
      // Review finding: hands folded on the chest rest at 0.60-0.62 of
      // hip -> shoulder, just under the 0.65 level, and pixel noise of 5 px
      // or more pushed the 3-frame mean over it and back down: a takbir
      // during the iqamah wait. The old rule (no rise/raw-peak test, drop
      // 0.1) must fire here, or the test proves nothing.
      const oldRule = ClassifierConfig(
          takbirMinRise: 0, takbirMinRawPeak: 0, takbirDrop: 0.1);
      var oldFired = 0;
      for (final noise in [6.0, 7.0, 8.0]) {
        for (var seed = 0; seed < 5; seed++) {
          for (final cfg in [const ClassifierConfig(), oldRule]) {
            final c = RuleBasedClassifier(config: cfg);
            final rng = math.Random(seed * 10 + noise.round());
            var t = feedStanding(c, n: 20);
            final ev = <int>[];
            // 30 s at 15 fps, wrist folded at 0.61 (elbow at 0.35, so noise
            // also puts the wrist below the elbow now and then).
            for (var i = 0; i < 450; i++) {
              final lm =
                  jitter(render(armsAt(0.61, elbowLevel: 0.35)), rng, noise);
              if (c.classify(frameOf(t, [lm])).takbirRaise) ev.add(t);
              t += 67;
            }
            if (identical(cfg, oldRule)) {
              oldFired += ev.length;
            } else {
              expect(ev, isEmpty, reason: 'noise $noise px, seed $seed');
            }
          }
        }
      }
      expect(oldFired, greaterThan(0));
    });

    test('real raises still fire with 6 px noise, ending at rest or folded',
        () {
      var fired = 0, n = 0;
      for (final peak in [1.25, 0.95, 0.8]) {
        for (final rest in [-0.07, 0.4, 0.58]) {
          for (var seed = 0; seed < 10; seed++) {
            final rng = math.Random(seed);
            final c = RuleBasedClassifier();
            final t = feedStanding(c, n: 20);
            n++;
            if (raiseEvents(c,
                t0: t,
                peak: peak,
                rest: rest,
                noise: (lm) => jitter(lm, rng, 6)).isNotEmpty) {
              fired++;
            }
          }
        }
      }
      expect(fired / n, greaterThanOrEqualTo(0.95), reason: '$fired/$n');
    });

    test('synthetic missed takbir, 6-7 px noise: no event while folded', () {
      var fired = 0;
      for (var s = 0; s < 16; s++) {
        final p = generateSyntheticPrayer(SyntheticCase.missedTakbir,
            seed: 6100 + s,
            options: SyntheticOptions(
                timeScale: 0.3,
                pixelNoise: s.isEven ? 6 : 7,
                confJitter: 0.06,
                kneesHidden: s % 4 == 1));
        final firstBow = p.labels.intervals
            .firstWhere((i) => i.posture == Posture.bowing)
            .startMs;
        // The hands are folded by 4.9 s; the wait is 12-36 s at this scale.
        // (Folding the hands itself under this much noise can very rarely
        // look like a chest-height takbir; see the classifier docs.)
        fired +=
            takbirDetections(p).where((d) => d >= 5000 && d < firstBow).length;
      }
      expect(fired, 0);
    });

    test('too low (navel), too slow, or held too long does not fire', () {
      for (final (peak, up, hold, down) in [
        (0.5, 400, 200, 400), // never reaches 0.65
        (1.2, 3000, 300, 600), // over 2 s from arm down to coming down
        (1.2, 400, 3000, 400), // hands held up (qunut, scratching the head)
      ]) {
        final c = RuleBasedClassifier();
        final t = feedStanding(c, n: 20);
        expect(
            raiseEvents(c,
                t0: t, peak: peak, upMs: up, holdMs: hold, downMs: down),
            isEmpty,
            reason: 'peak $peak up $up hold $hold down $down');
      }
    });

    test('a single-frame flick up does not fire', () {
      final c = RuleBasedClassifier();
      final t = feedStanding(c, n: 20);
      expect(raiseEvents(c, t0: t, peak: 1.2, upMs: 67, holdMs: 0, downMs: 67),
          isEmpty);
    });

    test('one-handed raise is rejected when the other wrist is seen down', () {
      final c = RuleBasedClassifier();
      final t = feedStanding(c, n: 20);
      // Far wrist visible at the side, near hand goes up to the head and back
      // (adjusting a cap or hijab).
      expect(
          raiseEvents(c,
              t0: t,
              peak: 1.4,
              conf: const Conf(farWrist: 0.9),
              farWristPos: (0, 240)),
          isEmpty);
      // Both hands up (far wrist seen and raised): fires.
      final c2 = RuleBasedClassifier();
      final t2 = feedStanding(c2, n: 20);
      expect(
          raiseEvents(c2,
              t0: t2,
              peak: 1.2,
              conf: const Conf(farWrist: 0.9),
              farWristPos: (15, 250 + 150 * 1.0)),
          hasLength(1));
    });

    test('must start from arms down (below the elbow)', () {
      final c = RuleBasedClassifier();
      var t = feedStanding(c, n: 20);
      // Hands folded on the chest (above the elbow), then up and back.
      Fig folded(double l) => armsAt(l, elbowLevel: 0.35);
      // Longer than the 2 s window since the arms were last down.
      for (var i = 0; i < 40; i++) {
        c.classify(one(t += 67, folded(0.55)));
      }
      final ev = <int>[];
      for (final l in [0.7, 0.9, 1.1, 1.1, 0.9, 0.7, 0.55, 0.55]) {
        if (c.classify(one(t += 67, folded(l))).takbirRaise) ev.add(t);
      }
      expect(ev, isEmpty);
    });

    test('arm movements while not upright never fire', () {
      final c = calibrated();
      var t = 6000;
      final ev = <int>[];
      // Sitting: hands up to the face and down.
      for (final l in [0.0, 0.4, 0.9, 1.2, 1.2, 0.9, 0.4, 0.0, 0.0]) {
        final f = sittingFig()..wrist = (20, 70 + 150 * l);
        if (c.classify(one(t += 67, f)).takbirRaise) ev.add(t);
      }
      // Bowing then prostrating (hands move past the head along the torso).
      for (final f in [bowingFig(), prostratingFig(), prostratingFig()]) {
        if (c.classify(one(t += 67, f)).takbirRaise) ev.add(t);
      }
      expect(ev, isEmpty);
    });
  });

  group('evaluation on synthetic prayers', () {
    test('clean data, both facings, several seeds', () {
      final prayers = [
        for (final facing in [1, -1])
          for (var s = 0; s < 13; s++)
            generateSyntheticPrayer(SyntheticCase.values[s],
                seed: 10 + s,
                options:
                    SyntheticOptions.clean(timeScale: fast, facing: facing)),
      ];
      final cm = evaluate(prayers);
      printOnFailure(cm.table('clean'));
      print(cm.table('clean (26 prayers)'));
      // The missed-ruku case hides the person on purpose (labelled bowing).
      expect(cm.accuracy, greaterThan(0.99));
      expect(cm.standSit, 0);
      expect(cm.recall(Posture.prostrating), greaterThan(0.999));
    });

    test('default noise, every case, both facings', () {
      final cm = evaluate([
        for (final facing in [1, -1])
          ...cases(1000 + facing,
              (_) => SyntheticOptions(timeScale: fast, facing: facing))
      ]);
      print(cm.table('default noise (26 prayers)'));
      expect(cm.accuracy, greaterThan(0.98));
      expect(cm.standSit, 0);
    });

    test('knees hidden: stand/sit confusion <= 1 %, sujood recall >= 95 %', () {
      final cm = evaluate(cases(
          8000,
          (k) => SyntheticOptions(
              timeScale: fast,
              kneesHidden: true,
              pixelNoise: 1.0 + k,
              confJitter: 0.05),
          perCase: 3));
      print(cm.table('knees hidden (39 prayers)'));
      expect(cm.standSit, lessThanOrEqualTo(0.01));
      expect(cm.recall(Posture.prostrating), greaterThanOrEqualTo(0.95));
      expect(cm.accuracy, greaterThan(0.97));
    });

    test('tilt: never standing during sujood or sitting labels', () {
      final cm = evaluate(cases(
          3000,
          (k) => SyntheticOptions(
              timeScale: fast, tiltDeg: k.isEven ? 4 : -4, tiltDriftDeg: 1.5),
          perCase: 2));
      print(cm.table('tilt 4 deg + drift (26 prayers)'));
      expect(cm.count(Posture.prostrating, Posture.standing), 0);
      expect(cm.count(Posture.sitting, Posture.standing), 0);
      expect(cm.accuracy, greaterThan(0.97));
    });

    test('child in frame: never standing during sujood or sitting labels', () {
      final cm = evaluate([
        for (var s = 0; s < 20; s++)
          generateSyntheticPrayer(SyntheticCase.childInFrame,
              seed: 4000 + s,
              options: SyntheticOptions(
                  timeScale: fast, kneesHidden: s.isOdd, pixelNoise: 2)),
      ]);
      print(cm.table('child in frame (20 prayers)'));
      expect(cm.count(Posture.prostrating, Posture.standing), 0);
      expect(cm.count(Posture.sitting, Posture.standing), 0);
      expect(cm.accuracy, greaterThan(0.97));
    });

    test('random perturbation batch', () {
      final cm =
          evaluate(generateSyntheticBatch(65, seed: 11, timeScale: fast));
      print(cm.table('random batch (65 prayers, dropouts included)'));
      expect(cm.standSit, 0);
      expect(cm.count(Posture.prostrating, Posture.standing), 0);
      expect(cm.count(Posture.sitting, Posture.standing), 0);
      expect(cm.accuracy, greaterThan(0.95));
    });
  });

  group('takbir on synthetic prayers', () {
    test('detects every visible opening takbir within 500 ms', () {
      final prayers = [
        for (var k = 0; k < 4; k++)
          ...cases(
              5000 + k,
              (_) => SyntheticOptions(
                  timeScale: fast,
                  pixelNoise: [0.5, 1.5, 3.0, 4.0][k],
                  kneesHidden: k.isOdd,
                  confJitter: 0.05,
                  landmarkDropoutRate: k == 3 ? 0.01 : 0)),
      ].where((s) => s.labels.takbirTimesMs.isNotEmpty).toList();
      var hits = 0, ruku = 0, rukuFired = 0, extra = 0;
      final misses = <String>[];
      for (final s in prayers) {
        final det = takbirDetections(s);
        final tk = s.labels.takbirTimesMs.single;
        final matched = det.where((d) => (d - tk).abs() <= 500).toList();
        if (matched.isEmpty) {
          misses.add('${s.name} at $tk ms, detections $det');
        } else {
          hits++;
        }
        for (final g in s.gestures
            .where((g) => g.kind == SyntheticGestureKind.rukuRaise)) {
          ruku++;
          if (det.any((d) => d >= g.startMs && d <= g.endMs + 500)) {
            rukuFired++;
          }
        }
        // Events before the first ruku other than the takbir itself.
        final firstBow = s.labels.intervals
            .firstWhere((i) => i.posture == Posture.bowing)
            .startMs;
        extra += det
            .where((d) => (d - tk).abs() > 500 && d < firstBow - 2000)
            .length;
      }
      print('takbir: $hits/${prayers.length} detected; ruku raises fired '
          '$rukuFired/$ruku; other events before ruku $extra');
      expect(misses, isEmpty);
      expect(extra, 0);
    });

    test('missed takbir: no event before the first ruku', () {
      var fired = 0;
      for (var s = 0; s < 60; s++) {
        final p = generateSyntheticPrayer(SyntheticCase.missedTakbir,
            seed: 6000 + s,
            options: SyntheticOptions(
                timeScale: fast,
                pixelNoise: (s % 5).toDouble(),
                confJitter: 0.05,
                kneesHidden: s.isOdd));
        final firstBow = p.labels.intervals
            .firstWhere((i) => i.posture == Posture.bowing)
            .startMs;
        fired += takbirDetections(p).where((d) => d < firstBow).length;
      }
      expect(fired, 0);
    });

    test('qunut holds and salam turns do not fire', () {
      var qunut = 0, salam = 0, n = 0;
      for (var s = 0; s < 20; s++) {
        for (final c in [
          SyntheticCase.shafiiQunut,
          SyntheticCase.malikiQunut,
        ]) {
          final p = generateSyntheticPrayer(c,
              seed: 7000 + s,
              options: SyntheticOptions(
                  timeScale: fast, pixelNoise: (s % 4).toDouble()));
          final det = takbirDetections(p);
          for (final g in p.gestures) {
            final hit =
                det.any((d) => d >= g.startMs - 1000 && d <= g.endMs + 1000);
            if (g.kind == SyntheticGestureKind.qunut) {
              n++;
              if (hit) qunut++;
            }
            if (g.kind == SyntheticGestureKind.salam && hit) salam++;
          }
        }
      }
      print('qunut: $qunut of $n holds fired; salam turns fired $salam');
      expect(salam, 0);
      expect(qunut, 0);
    });
  });
}
