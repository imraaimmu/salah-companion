import 'dart:math' as math;

import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

const fast = 0.05;

/// Near-side landmark indices for a recording's header side.
class Near {
  final int shoulder, hip, ankle;
  Near(String side)
      : shoulder = side == 'left'
            ? LandmarkIndex.leftShoulder
            : LandmarkIndex.rightShoulder,
        hip = side == 'left' ? LandmarkIndex.leftHip : LandmarkIndex.rightHip,
        ankle =
            side == 'left' ? LandmarkIndex.leftAnkle : LandmarkIndex.rightAnkle;
}

/// Shoulder->hip line against vertical, in degrees (0 upright, 90 level,
/// over 90 when the shoulder is below the hip).
double torsoAngle(List<Landmark> p, Near n) {
  final dx = p[n.shoulder].x - p[n.hip].x;
  final dy = p[n.hip].y - p[n.shoulder].y; // up is positive
  return math.atan2(dx.abs(), dy) * 180 / math.pi;
}

/// Ankle y minus hip y, in pixels (the spec's hip height before dividing by
/// the calibrated standing value).
double hipGap(List<Landmark> p, Near n) => p[n.ankle].y - p[n.hip].y;

double torsoLength(List<Landmark> p, Near n) {
  final dx = p[n.shoulder].x - p[n.hip].x;
  final dy = p[n.shoulder].y - p[n.hip].y;
  return math.sqrt(dx * dx + dy * dy);
}

void expectValid(SyntheticPrayer s) {
  final rec = s.encodeRecordingText();
  final lab = s.encodeLabelsText();
  expect(validateRecording(rec), isEmpty, reason: '${s.name} recording');
  expect(validateLabels(lab), isEmpty, reason: '${s.name} labels');
  // Every frame time is labelled.
  for (final f in s.recording.frames) {
    expect(s.labels.intervalAt(f.tMs), isNotNull,
        reason: '${s.name}: frame ${f.tMs} not labelled');
  }
  // Labels start at 0 and touch each other.
  final iv = s.labels.intervals;
  expect(iv.first.startMs, 0);
  for (var i = 1; i < iv.length; i++) {
    expect(iv[i].startMs, iv[i - 1].endMs);
  }
  expect(decodeLabels(lab).recording, s.recordingFileName);
}

/// Contiguous runs of the same state (and rak'ah).
List<(PrayerState, int, int)> stateRuns(LabelSet l) =>
    [for (final r in stateRakahRuns(l)) (r.$1, r.$3, r.$4)];

/// Contiguous runs of the same (state, rak'ah): (state, rak'ah, start, end).
List<(PrayerState, int, int, int)> stateRakahRuns(LabelSet l) {
  final runs = <(PrayerState, int, int, int)>[];
  for (final iv in l.intervals) {
    if (runs.isNotEmpty &&
        runs.last.$1 == iv.state &&
        runs.last.$2 == iv.rakah) {
      runs[runs.length - 1] = (iv.state, iv.rakah, runs.last.$3, iv.endMs);
    } else {
      runs.add((iv.state, iv.rakah, iv.startMs, iv.endMs));
    }
  }
  return runs;
}

const qiyam = PrayerState.qiyam;
const ruku = PrayerState.ruku;
const itidal = PrayerState.itidal;
const sujood = PrayerState.sujood;

int labelledMs(LabelSet l, bool Function(LabelInterval) where) =>
    l.intervals.where(where).fold(0, (a, iv) => a + iv.endMs - iv.startMs);

void main() {
  group('every case', () {
    // Dhuhr and Asr script exactly like Isha (4 rak'ahs); they are covered
    // by the batch and label tests below.
    for (final (prayer, c) in [
      for (final p in [Prayer.fajr, Prayer.maghrib, Prayer.isha])
        for (final c in SyntheticCase.forPrayer(p)) (p, c),
    ]) {
      final name = '${prayer.name} ${c.name}';
      test('$name is valid (default options)', () {
        final s = generateSyntheticPrayer(c,
            seed: 7,
            prayer: prayer,
            options: const SyntheticOptions(timeScale: fast));
        expectValid(s);
        expect(s.labels.prayer, prayer);
        expect(decodeLabels(s.encodeLabelsText()).prayer, prayer);
      });
      test('$name is valid (heavy perturbations)', () {
        expectValid(generateSyntheticPrayer(c,
            seed: 11,
            prayer: prayer,
            options: const SyntheticOptions(
              timeScale: fast,
              timingJitterMs: 10,
              frameSkipRate: 0.05,
              pixelNoise: 5,
              confJitter: 0.2,
              landmarkDropoutRate: 0.05,
              frameDropoutRate: 0.02,
              kneesHidden: true,
              tiltDeg: 4,
              tiltDriftDeg: 1,
              child: true,
            )));
      });
    }
  });

  test('default timeScale gives realistic lengths', () {
    final s = generateSyntheticPrayer(SyntheticCase.normal, seed: 3);
    expectValid(s);
    final total = s.labels.intervals.last.endMs;
    expect(total, greaterThan(120000));
    expect(total, lessThan(600000));
    final q1 = labelledMs(
        s.labels, (iv) => iv.state == PrayerState.qiyam && iv.rakah == 1);
    expect(q1, inInclusiveRange(40000, 125000));
  });

  test('default timeScale: a realistic four-rak\'ah prayer', () {
    final s = generateSyntheticPrayer(SyntheticCase.normal,
        seed: 3, prayer: Prayer.isha);
    expectValid(s);
    final total = s.labels.intervals.last.endMs;
    expect(total, greaterThan(240000));
    expect(total, lessThan(900000));
    for (final k in [3, 4]) {
      // Al-Fatiha only: 20-50 s.
      final ms = labelledMs(
          s.labels, (iv) => iv.state == PrayerState.qiyam && iv.rakah == k);
      expect(ms, inInclusiveRange(20000, 52000), reason: 'rak\'ah $k');
    }
    final middle = labelledMs(
        s.labels,
        (iv) =>
            iv.state == PrayerState.middleSitting &&
            iv.posture == Posture.sitting);
    expect(middle, inInclusiveRange(5000, 41000));
  });

  test('cases that do not apply to a prayer are refused', () {
    expect(
        () => generateSyntheticPrayer(SyntheticCase.shafiiQunut,
            prayer: Prayer.dhuhr),
        throwsArgumentError);
    expect(
        () => generateSyntheticPrayer(SyntheticCase.missedMiddleSitting,
            prayer: Prayer.fajr),
        throwsArgumentError);
    expect(SyntheticCase.forPrayer(Prayer.fajr), hasLength(14));
    expect(SyntheticCase.forPrayer(Prayer.maghrib), hasLength(15));
  });

  group('determinism', () {
    test('same seed, same text', () {
      for (final c in [SyntheticCase.normal, SyntheticCase.childInFrame]) {
        const o = SyntheticOptions(
            timeScale: fast, landmarkDropoutRate: 0.01, frameDropoutRate: 0.01);
        final a = generateSyntheticPrayer(c, seed: 42, options: o);
        final b = generateSyntheticPrayer(c, seed: 42, options: o);
        expect(a.encodeRecordingText(), b.encodeRecordingText());
        expect(a.encodeLabelsText(), b.encodeLabelsText());
      }
    });
    test('different seed, different text', () {
      const o = SyntheticOptions(timeScale: fast);
      final a =
          generateSyntheticPrayer(SyntheticCase.normal, seed: 1, options: o);
      final b =
          generateSyntheticPrayer(SyntheticCase.normal, seed: 2, options: o);
      expect(a.encodeRecordingText(), isNot(b.encodeRecordingText()));
      expect(a.encodeLabelsText(), isNot(b.encodeLabelsText()));
    });
    test('batch is deterministic', () {
      final a = generateSyntheticBatch(14, seed: 5, timeScale: fast)
          .map((s) => s.encodeRecordingText())
          .toList();
      final b = generateSyntheticBatch(14, seed: 5, timeScale: fast)
          .map((s) => s.encodeRecordingText())
          .toList();
      expect(a, b);
    });
  });

  test('500 perturbed sequences from one seed', () {
    var n = 0;
    final cases = <SyntheticCase>{};
    for (final s in generateSyntheticBatch(500, seed: 2026, timeScale: fast)) {
      cases.add(s.scenario);
      expect(s.recording.frames, isNotEmpty);
      expect(s.labels.intervals.first.startMs, 0);
      expect(s.labels.intervalAt(s.recording.frames.last.tMs), isNotNull);
      var badConf = 0;
      for (final f in s.recording.frames) {
        for (final p in f.people) {
          for (final l in p) {
            if (!(l.conf >= 0 && l.conf <= 1)) badConf++;
          }
        }
      }
      expect(badConf, 0, reason: s.name);
      if (n % 25 == 0) expectValid(s);
      n++;
    }
    expect(n, 500);
    expect(cases, SyntheticCase.forPrayer(Prayer.fajr).toSet());
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a batch over every prayer cycles prayers, then each prayer\'s cases',
      () {
    final batch = generateSyntheticBatch(Prayer.values.length * 6,
            seed: 31, timeScale: fast, prayers: Prayer.values)
        .toList();
    for (var i = 0; i < batch.length; i++) {
      final p = Prayer.values[i % Prayer.values.length];
      expect(batch[i].prayer, p);
      expect(batch[i].labels.prayer, p);
      final cases = SyntheticCase.forPrayer(p);
      expect(
          batch[i].scenario, cases[(i ~/ Prayer.values.length) % cases.length]);
      expect(batch[i].name, contains(p == Prayer.fajr ? '-' : '-${p.name}-'));
    }
    // The Fajr-only batch is unchanged by the other prayers' existence.
    final fajr = generateSyntheticBatch(3, seed: 31, timeScale: fast).toList();
    expect(fajr.map((s) => s.scenario), [
      SyntheticCase.normal,
      SyntheticCase.iqamahWait,
      SyntheticCase.missedTakbir
    ]);
    expect(fajr.first.name, startsWith('synthetic-0001-normal-s'));
  });

  group('geometry (spec starting rules) on clean frames', () {
    for (final (seed, facing) in [(1, 1), (2, -1), (3, 1), (4, -1), (5, 1)]) {
      for (final c in [
        SyntheticCase.normal,
        SyntheticCase.briefSittingBeforeRakah2,
        SyntheticCase.sahwAfterSalam,
      ]) {
        test('${c.name} seed $seed facing $facing', () {
          final s = generateSyntheticPrayer(c,
              seed: seed,
              options: SyntheticOptions.clean(timeScale: fast, facing: facing));
          final n = Near(s.recording.header.side);
          expect(s.recording.header.side, facing > 0 ? 'right' : 'left');
          // Calibrate hip height on the waiting standing frames.
          final standGaps = [
            for (final f in s.recording.frames)
              if (s.labels.stateAt(f.tMs) == PrayerState.waiting)
                hipGap(f.people.single, n)
          ]..sort();
          final standing = standGaps[standGaps.length ~/ 2];
          final seen = <Posture>{};
          for (final f in s.recording.frames) {
            final p = f.people.single;
            final posture = s.labels.postureAt(f.tMs)!;
            final hh = hipGap(p, n) / standing;
            final torso = torsoAngle(p, n);
            final why = 't=${f.tMs} $posture hip $hh torso $torso';
            seen.add(posture);
            switch (posture) {
              case Posture.standing:
                expect(torso, lessThan(20), reason: why);
                expect(hh, inInclusiveRange(0.9, 1.1), reason: why);
              case Posture.bowing:
                expect(torso, inInclusiveRange(55, 100), reason: why);
                expect(hh, greaterThanOrEqualTo(0.6), reason: why);
              case Posture.prostrating:
                expect(hh, lessThan(0.6), reason: why);
                final drop = p[LandmarkIndex.nose].y - p[n.hip].y;
                expect(drop, greaterThan(0.4 * torsoLength(p, n)),
                    reason: '$why nose drop $drop');
              case Posture.sitting:
                expect(hh, lessThanOrEqualTo(0.35), reason: why);
                expect(torso, lessThan(35), reason: why);
              case Posture.unknown:
                break;
            }
            // Everything stays roughly inside the portrait frame.
            final outside =
                p.where((l) => l.x < -20 || l.x > 500 || l.y < 0 || l.y > 640);
            expect(outside, isEmpty, reason: why);
          }
          expect(seen, Posture.values.toSet());
        });
      }
    }
  });

  group('labels follow the scenario', () {
    const o = SyntheticOptions(timeScale: fast);
    SyntheticPrayer gen(SyntheticCase c, [int seed = 9]) =>
        generateSyntheticPrayer(c, seed: seed, options: o);

    test('normal: full sequence, two qiyam, one takbir', () {
      final s = gen(SyntheticCase.normal);
      final runs = stateRakahRuns(s.labels).map((r) => (r.$1, r.$2)).toList();
      expect(runs, [
        (PrayerState.waiting, 0),
        (PrayerState.takbir, 0),
        (qiyam, 1),
        (ruku, 1),
        (itidal, 1),
        (sujood, 1),
        (qiyam, 2),
        (ruku, 2),
        (itidal, 2),
        (sujood, 2),
        (PrayerState.finalSitting, 2),
        (PrayerState.done, 2),
      ]);
      final qiyamStanding = s.labels.intervals
          .where((iv) => iv.state == qiyam && iv.posture == Posture.standing);
      expect(qiyamStanding, hasLength(2));
      expect(s.labels.takbirTimesMs, hasLength(1));
      final t = s.labels.takbirTimesMs.single;
      expect(s.labels.stateAt(t - 1), PrayerState.waiting);
      expect(s.labels.stateAt(t), PrayerState.takbir);
      expect(s.labels.stateAt(t + takbirHoldMs), qiyam);
      expect(s.labels.intervalAt(t + takbirHoldMs)!.rakah, 1);
      expect(s.gestures.where((g) => g.kind == SyntheticGestureKind.takbir),
          hasLength(1));
      // Rak'ah numbers.
      for (final iv in s.labels.intervals) {
        if (iv.rakah == 0) {
          expect(iv.state, anyOf(PrayerState.waiting, PrayerState.takbir));
        }
      }
      // Four prostrations, three sittings (two jalsas and the final).
      int count(Posture p) =>
          s.labels.intervals.where((iv) => iv.posture == p).length;
      expect(count(Posture.prostrating), 4);
      expect(count(Posture.sitting), 3);
      expect(count(Posture.bowing), 2);
    });

    test('iqamah: 30 s or more of waiting standing', () {
      final s = gen(SyntheticCase.iqamahWait);
      expect(s.labels.takbirTimesMs.single, greaterThanOrEqualTo(30000));
      expect(
          labelledMs(
              s.labels,
              (iv) =>
                  iv.state == PrayerState.waiting &&
                  iv.posture == Posture.standing),
          greaterThanOrEqualTo(30000));
    });

    test('missed takbir: no takbir event, no takbir or qiyam1 state', () {
      for (var seed = 0; seed < 5; seed++) {
        final s = gen(SyntheticCase.missedTakbir, seed);
        expect(s.labels.takbirTimesMs, isEmpty);
        expect(s.gestures.where((g) => g.kind == SyntheticGestureKind.takbir),
            isEmpty);
        final states = s.labels.intervals.map((iv) => iv.state).toSet();
        expect(states, isNot(contains(PrayerState.takbir)));
        expect(
            s.labels.intervals
                .where((iv) => iv.state == qiyam && iv.rakah == 1),
            isEmpty);
        expect(stateRakahRuns(s.labels)[1].$1, ruku);
        expect(stateRakahRuns(s.labels)[1].$2, 1);
      }
    });

    test('Shafi\'i qunut is in i\'tidal 2, Maliki qunut in qiyam 2', () {
      final sh = gen(SyntheticCase.shafiiQunut);
      final q1 =
          sh.gestures.singleWhere((g) => g.kind == SyntheticGestureKind.qunut);
      (PrayerState, int) at(SyntheticPrayer p, int t) =>
          (p.labels.stateAt(t)!, p.labels.intervalAt(t)!.rakah);
      expect(at(sh, q1.startMs), (itidal, 2));
      expect(at(sh, q1.endMs - 1), (itidal, 2));
      final ma = gen(SyntheticCase.malikiQunut);
      final q2 =
          ma.gestures.singleWhere((g) => g.kind == SyntheticGestureKind.qunut);
      expect(at(ma, q2.startMs), (qiyam, 2));
      expect(at(ma, q2.endMs - 1), (qiyam, 2));
      expect(ma.labels.takbirTimesMs, hasLength(1));
      expect(sh.labels.takbirTimesMs, hasLength(1));
    });

    test('raised hands at ruku: four extra raises, one takbir event', () {
      final s = gen(SyntheticCase.raisedHandsAtRuku);
      final raises =
          s.gestures.where((g) => g.kind == SyntheticGestureKind.rukuRaise);
      expect(
          raises.map((g) => (
                s.labels.stateAt(g.startMs),
                s.labels.intervalAt(g.startMs)!.rakah
              )),
          [(qiyam, 1), (itidal, 1), (qiyam, 2), (itidal, 2)]);
      expect(s.labels.takbirTimesMs, hasLength(1));
    });

    test('brief sitting before rak\'ah 2 is labelled sujood1 sitting', () {
      final s = gen(SyntheticCase.briefSittingBeforeRakah2);
      final sitting = s.labels.intervals
          .where((iv) =>
              iv.posture == Posture.sitting &&
              iv.state == sujood &&
              iv.rakah == 1)
          .toList();
      expect(sitting, hasLength(2)); // jalsa + the brief sitting
      final q2 = s.labels.intervals
          .firstWhere((iv) => iv.state == qiyam && iv.rakah == 2);
      expect(q2.startMs, greaterThan(sitting.last.endMs));
      expect(
          s.labels.intervals
              .where((iv) =>
                  iv.startMs >= sitting.last.endMs && iv.endMs <= q2.startMs)
              .every((iv) => iv.posture == Posture.unknown),
          isTrue);
    });

    test('hurried jalsa: every jalsa sitting is under 0.5 s', () {
      for (var seed = 0; seed < 5; seed++) {
        final s = gen(SyntheticCase.hurriedJalsa, seed);
        final jalsas = s.labels.intervals
            .where((iv) => iv.posture == Posture.sitting && iv.state == sujood);
        expect(jalsas, hasLength(2));
        for (final j in jalsas) {
          expect(j.endMs - j.startMs, lessThan(500));
        }
      }
    });

    test('missed ruku: bowing frames are dropped or low confidence', () {
      for (var seed = 0; seed < 6; seed++) {
        final s = gen(SyntheticCase.missedRuku, seed);
        expect(s.occlusions, hasLength(1));
        final span = s.occlusions.single;
        final st = s.labels.stateAt(span.startMs + 1);
        expect(st, anyOf(qiyam, PrayerState.waiting));
        var bowingFrames = 0;
        for (final f in s.recording.frames) {
          if (s.labels.postureAt(f.tMs) != Posture.bowing) continue;
          final hidden = span.contains(f.tMs);
          if (!hidden) continue;
          bowingFrames++;
          if (f.people.isNotEmpty) {
            final mean = f.people.single.fold(0.0, (a, l) => a + l.conf) / 33;
            expect(mean, lessThan(0.4));
          }
        }
        expect(bowingFrames, greaterThan(10));
        // The other ruku is visible.
        final visible = s.recording.frames.where((f) =>
            s.labels.postureAt(f.tMs) == Posture.bowing &&
            !span.contains(f.tMs) &&
            f.people.isNotEmpty);
        expect(visible, isNotEmpty);
      }
    });

    test('long tashahhud: final sitting 100–180 s', () {
      final s = gen(SyntheticCase.longTashahhud);
      final ms = labelledMs(
          s.labels,
          (iv) =>
              iv.state == PrayerState.finalSitting &&
              iv.posture == Posture.sitting);
      expect(ms, inInclusiveRange(100000, 180000));
    });

    test('sujood al-sahw before and after salam', () {
      for (final (c, after) in [
        (SyntheticCase.sahwBeforeSalam, false),
        (SyntheticCase.sahwAfterSalam, true),
      ]) {
        final s = gen(c);
        final sahw = s.labels.intervals
            .where((iv) =>
                iv.state == PrayerState.finalSitting &&
                iv.posture == Posture.prostrating)
            .toList();
        expect(sahw, hasLength(2), reason: c.name);
        final salams = s.gestures
            .where((g) => g.kind == SyntheticGestureKind.salam)
            .toList();
        expect(salams, hasLength(after ? 4 : 2));
        if (after) {
          expect(sahw.first.startMs, greaterThan(salams[1].endMs));
          expect(sahw.last.endMs, lessThan(salams[2].startMs));
        } else {
          expect(sahw.last.endMs, lessThan(salams.first.startMs));
        }
        expect(stateRuns(s.labels).last.$1, PrayerState.done);
      }
    });

    group('three- and four-rak\'ah prayers', () {
      SyntheticPrayer genP(SyntheticCase c, Prayer p, [int seed = 9]) =>
          generateSyntheticPrayer(c, seed: seed, prayer: p, options: o);

      for (final p in [Prayer.dhuhr, Prayer.asr, Prayer.maghrib, Prayer.isha]) {
        final n = p.rakahCount;
        test('${p.name} normal: N rak\'ahs, middle sitting after rak\'ah 2',
            () {
          final s = genP(SyntheticCase.normal, p);
          expect(stateRakahRuns(s.labels).map((r) => (r.$1, r.$2)).toList(), [
            (PrayerState.waiting, 0),
            (PrayerState.takbir, 0),
            for (var k = 1; k <= n; k++) ...[
              (qiyam, k),
              (ruku, k),
              (itidal, k),
              (sujood, k),
              if (k == 2) (PrayerState.middleSitting, 2),
            ],
            (PrayerState.finalSitting, n),
            (PrayerState.done, n),
          ]);
          int count(Posture q) =>
              s.labels.intervals.where((iv) => iv.posture == q).length;
          expect(count(Posture.prostrating), 2 * n);
          expect(count(Posture.bowing), n);
          // n jalsas, the middle and the final sitting.
          expect(count(Posture.sitting), n + 2);
          final middle = s.labels.intervals.singleWhere((iv) =>
              iv.state == PrayerState.middleSitting &&
              iv.posture == Posture.sitting);
          expect(middle.endMs - middle.startMs, greaterThanOrEqualTo(5000));
        });
      }

      test('short middle tashahhud: 3.5-5.5 s of sitting', () {
        for (var seed = 0; seed < 5; seed++) {
          final s = genP(SyntheticCase.shortMiddleTashahhud, Prayer.isha, seed);
          final ms = labelledMs(
              s.labels,
              (iv) =>
                  iv.state == PrayerState.middleSitting &&
                  iv.posture == Posture.sitting);
          expect(ms, inInclusiveRange(3500, 5800));
        }
      });

      test('stand with raise: one hand raise, at the start of qiyam 3', () {
        for (final p in [Prayer.maghrib, Prayer.dhuhr]) {
          final s = genP(SyntheticCase.standWithRaise, p);
          final g = s.gestures
              .singleWhere((g) => g.kind == SyntheticGestureKind.riseRaise);
          expect(s.labels.stateAt(g.startMs), qiyam);
          expect(s.labels.intervalAt(g.startMs)!.rakah, 3);
          expect(s.labels.takbirTimesMs, hasLength(1));
          expect(s.labels.takbirTimesMs.single, lessThan(g.startMs));
        }
      });

      test('missed middle sitting: most of it hidden', () {
        for (var seed = 0; seed < 5; seed++) {
          final s = genP(SyntheticCase.missedMiddleSitting, Prayer.dhuhr, seed);
          final span = s.occlusions.single;
          final sit = s.labels.intervals.singleWhere((iv) =>
              iv.state == PrayerState.middleSitting &&
              iv.posture == Posture.sitting);
          expect(span.startMs, greaterThanOrEqualTo(sit.startMs));
          expect(span.endMs, lessThanOrEqualTo(sit.endMs));
          // What stays visible of the sitting is under 3 s in total.
          final visible =
              (sit.endMs - sit.startMs) - (span.endMs - span.startMs);
          expect(visible, lessThan(3200));
          expect(span.endMs - span.startMs, lessThan(8000));
        }
      });

      test('missed ruku may be in any rak\'ah', () {
        final rakahs = <int>{};
        for (var seed = 0; seed < 20; seed++) {
          final s = genP(SyntheticCase.missedRuku, Prayer.isha, seed);
          rakahs.add(s.labels.intervalAt(s.occlusions.single.startMs)!.rakah);
        }
        expect(rakahs, {1, 2, 3, 4});
      });

      test('brief sitting before rak\'ahs 2 and 4 (not before 3)', () {
        final s = genP(SyntheticCase.briefSittingBeforeRakah2, Prayer.isha);
        final bySujood = <int, int>{};
        for (final iv in s.labels.intervals) {
          if (iv.state == sujood && iv.posture == Posture.sitting) {
            bySujood[iv.rakah] = (bySujood[iv.rakah] ?? 0) + 1;
          }
        }
        expect(bySujood, {1: 2, 2: 1, 3: 2, 4: 1});
      });

      test('raised hands at ruku also raise when standing for rak\'ah 3', () {
        final s = genP(SyntheticCase.raisedHandsAtRuku, Prayer.asr);
        expect(
            s.gestures.where((g) => g.kind == SyntheticGestureKind.rukuRaise),
            hasLength(8));
        expect(
            s.gestures.where((g) => g.kind == SyntheticGestureKind.riseRaise),
            hasLength(1));
      });

      test('sahw and final sitting carry rak\'ah N', () {
        final s = genP(SyntheticCase.sahwAfterSalam, Prayer.maghrib);
        expect(
            s.labels.intervals
                .where((iv) => iv.state == PrayerState.finalSitting)
                .map((iv) => iv.rakah)
                .toSet(),
            {3});
      });
    });

    test('child in frame: a second, smaller person for a while', () {
      final s = gen(SyntheticCase.childInFrame);
      final two =
          s.recording.frames.where((f) => f.people.length == 2).toList();
      expect(two.length, greaterThan(30));
      for (final f in two) {
        expect(f.landmarks, isNull);
      }
      final one = s.recording.frames.where((f) => f.people.length == 1);
      expect(one, isNotEmpty);
      // The child is shorter: compare shoulder-ankle spans on one frame.
      double span(List<Landmark> p) =>
          (p[LandmarkIndex.leftAnkle].y - p[LandmarkIndex.leftShoulder].y)
              .abs();
      final f = two[two.length ~/ 2];
      final spans = f.people.map(span).toList()..sort();
      expect(spans.first, lessThan(spans.last));
    });
  });

  group('hands-first descent', () {
    test('the case sets the option; batches draw it at random', () {
      final s = generateSyntheticPrayer(SyntheticCase.handsFirstDescent,
          seed: 3, options: const SyntheticOptions.clean(timeScale: fast));
      expect(s.options.handsFirstDescent, isTrue);
      expect(const SyntheticOptions().handsFirstDescent, isFalse);
      final batch =
          generateSyntheticBatch(200, seed: 9, timeScale: fast).toList();
      final drawn = batch
          .where((p) =>
              p.options.handsFirstDescent &&
              p.scenario != SyntheticCase.handsFirstDescent)
          .length;
      expect(drawn, inInclusiveRange(10, 60));
    });

    test(
        'each descent from i\'tidal passes through a ruku-like pose with the '
        'hips high for about 0.5-1.0 s', () {
      for (final prayer in [Prayer.fajr, Prayer.isha]) {
        for (final seed in [1, 2, 3]) {
          final s = generateSyntheticPrayer(SyntheticCase.handsFirstDescent,
              seed: seed,
              prayer: prayer,
              options: const SyntheticOptions.clean(timeScale: fast));
          expectValid(s);
          final n = Near(s.recording.header.side);
          final frames = s.recording.frames;
          final standGap = hipGap(frames.first.landmarks!, n);
          final runs = stateRakahRuns(s.labels);
          var descents = 0;
          for (final (state, rakah, start, end) in runs) {
            if (state != itidal) continue;
            // From the i'tidal into the first prostrating label of sujood.
            final sujoodPr = s.labels.intervals.firstWhere((iv) =>
                iv.state == sujood &&
                iv.rakah == rakah &&
                iv.posture == Posture.prostrating);
            var bowMs = 0;
            var prev = start;
            for (final f in frames) {
              if (f.tMs < start || f.tMs >= sujoodPr.startMs) continue;
              final l = f.landmarks!;
              final a = torsoAngle(l, n);
              if (a >= 55 && a <= 95 && hipGap(l, n) >= 0.85 * standGap) {
                bowMs += f.tMs - prev;
              }
              prev = f.tMs;
            }
            expect(bowMs, inInclusiveRange(350, 1400),
                reason: '${s.name} rak\'ah $rakah');
            expect(end, lessThan(sujoodPr.startMs));
            descents++;
          }
          expect(descents, prayer.rakahCount, reason: s.name);
        }
      }
    });
  });

  group('perturbations', () {
    test('batch pixelNoise override: same seeds, only the noise changes', () {
      final base = generateSyntheticBatch(6, seed: 3, timeScale: 0.05).toList();
      final loud =
          generateSyntheticBatch(6, seed: 3, timeScale: 0.05, pixelNoise: 6)
              .toList();
      for (var i = 0; i < 6; i++) {
        expect(loud[i].options.pixelNoise, 6);
        expect(loud[i].name, base[i].name);
        expect(loud[i].options.kneesHidden, base[i].options.kneesHidden);
        expect(loud[i].options.frameSkipRate, base[i].options.frameSkipRate);
      }
    });

    test('tilt is written relative to session start; landmarks use full roll',
        () {
      final flat = generateSyntheticPrayer(SyntheticCase.normal,
          seed: 4, options: const SyntheticOptions.clean(timeScale: fast));
      final tilted = generateSyntheticPrayer(SyntheticCase.normal,
          seed: 4,
          options: const SyntheticOptions(
              timeScale: fast,
              tiltDeg: 3,
              pixelNoise: 0,
              confJitter: 0,
              timingJitterMs: 0));
      // A constant roll is the session-start roll: written tilt stays 0.
      expect(tilted.recording.frames.every((f) => f.tiltDeg == 0), isTrue);
      expect(flat.recording.frames.every((f) => f.tiltDeg == 0), isTrue);
      final a = flat.recording.frames.first.people.single;
      final b = tilted.recording.frames.first.people.single;
      expect(
          b[LandmarkIndex.nose].x, isNot(closeTo(a[LandmarkIndex.nose].x, 1)));
      // Undo by rotating +tilt about the frame centre.
      const t = 3 * math.pi / 180;
      for (final i in [0, 11, 12, 23, 24, 27, 28]) {
        final dx = b[i].x - 240, dy = b[i].y - 320;
        final x = 240 + dx * math.cos(t) - dy * math.sin(t);
        final y = 320 + dx * math.sin(t) + dy * math.cos(t);
        expect(x, closeTo(a[i].x, 0.05));
        expect(y, closeTo(a[i].y, 0.05));
      }
    });

    test('drifting tilt starts at 0 and follows the drift', () {
      final s = generateSyntheticPrayer(SyntheticCase.normal,
          seed: 4,
          options: const SyntheticOptions(
              timeScale: fast, tiltDeg: 3, tiltDriftDeg: 1.5));
      final tilts = s.recording.frames.map((f) => f.tiltDeg).toList();
      expect(tilts.first, 0);
      expect(tilts.any((t) => t != 0), isTrue);
      // Drift amplitude 1.5 around the start roll: never more than 3 away.
      expect(tilts.every((t) => t.abs() <= 3.0 + 1e-9), isTrue);
    });

    test('frame dropouts write empty people; timing jitter stays increasing',
        () {
      final s = generateSyntheticPrayer(SyntheticCase.normal,
          seed: 8,
          options: const SyntheticOptions(
              timeScale: fast,
              frameDropoutRate: 0.03,
              timingJitterMs: 12,
              frameSkipRate: 0.05));
      expect(s.recording.frames.where((f) => f.people.isEmpty), isNotEmpty);
      final ts = s.recording.frames.map((f) => f.tMs).toList();
      for (var i = 1; i < ts.length; i++) {
        expect(ts[i], greaterThan(ts[i - 1]));
      }
      final gaps = [for (var i = 1; i < ts.length; i++) ts[i] - ts[i - 1]];
      expect(gaps.where((g) => g > 100), isNotEmpty); // skipped frames
    });

    test('knees hidden lowers knee confidence, feet only mildly; far side less',
        () {
      final s = generateSyntheticPrayer(SyntheticCase.normal,
          seed: 6,
          options: const SyntheticOptions(
              timeScale: fast, kneesHidden: true, facing: 1));
      final n = Near('right');
      for (final f in s.recording.frames.take(50)) {
        final p = f.people.single;
        expect(p[LandmarkIndex.rightKnee].conf, lessThan(0.65));
        for (final i in [
          LandmarkIndex.rightAnkle,
          LandmarkIndex.rightHeel,
          LandmarkIndex.rightFootIndex,
        ]) {
          expect(p[i].conf, inInclusiveRange(0.35, 0.95));
        }
        expect(p[n.shoulder].conf, greaterThan(0.7));
        expect(p[LandmarkIndex.leftShoulder].conf, lessThan(0.75));
      }
    });
  });
}
