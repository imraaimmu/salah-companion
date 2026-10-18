import 'dart:math';

import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

const s = Posture.standing;
const b = Posture.bowing;
const p = Posture.prostrating;
const u = Posture.unknown;

/// Frame time at 15 fps.
int ft(int i) => (i * 1000 / 15).round();

PostureReading r(int t, Posture posture,
        {double conf = 0.9, bool takbir = false}) =>
    posture == u && !takbir
        ? PostureReading.unknown(t)
        : PostureReading(
            tMs: t,
            posture: posture,
            confidence: posture == u ? 0 : conf,
            takbirRaise: takbir,
            hipHeightRatio: 1.0,
            torsoAngleDeg: 5.0,
          );

/// 15 fps frames of [postures], starting at frame index [from].
List<PostureReading> frames(List<Posture> postures, {int from = 0}) => [
      for (var i = 0; i < postures.length; i++) r(ft(from + i), postures[i]),
    ];

List<PostureReading> run(MajoritySmoother sm, List<PostureReading> raw) =>
    [for (final x in raw) sm.add(x)];

int changes(List<PostureReading> out) {
  var n = 0;
  for (var i = 1; i < out.length; i++) {
    if (out[i].posture != out[i - 1].posture) n++;
  }
  return n;
}

void main() {
  group('construction', () {
    test('defaults', () {
      final sm = MajoritySmoother();
      expect(sm.windowMs, 500);
      expect(sm.switchShare, 0.6);
      expect(sm.current, u);
    });

    test('rejects invalid settings', () {
      expect(() => MajoritySmoother(windowMs: 0), throwsArgumentError);
      expect(() => MajoritySmoother(switchShare: 0.5), throwsArgumentError);
      expect(() => MajoritySmoother(switchShare: 1.1), throwsArgumentError);
      expect(() => MajoritySmoother(releaseShare: -0.1), throwsArgumentError);
      expect(() => MajoritySmoother(releaseShare: 0.6), throwsArgumentError);
      expect(() => MajoritySmoother(unknownWeight: 0), throwsArgumentError);
      expect(() => MajoritySmoother(minKnownWeight: 0), throwsArgumentError);
      expect(() => MajoritySmoother(maxSpanMs: 0), throwsArgumentError);
      expect(() => MajoritySmoother(maxSpanMs: 600), throwsArgumentError);
    });
  });

  group('steady posture', () {
    test('passes through from the first frame with full confidence', () {
      final out = run(MajoritySmoother(), frames(List.filled(60, s)));
      for (final o in out) {
        expect(o.posture, s);
        expect(o.confidence, closeTo(1.0, 1e-9));
      }
    });

    test('keeps tMs, hipHeightRatio and torsoAngleDeg of the raw frame', () {
      final sm = MajoritySmoother();
      sm.add(r(0, s));
      final raw = PostureReading(
          tMs: 67,
          posture: b,
          confidence: 0.4,
          hipHeightRatio: 0.73,
          torsoAngleDeg: 81.5);
      final o = sm.add(raw);
      expect(o.tMs, 67);
      expect(o.hipHeightRatio, 0.73);
      expect(o.torsoAngleDeg, 81.5);
      expect(o.posture, s, reason: 'one low-confidence frame cannot switch');
      expect(o.confidence, inInclusiveRange(0.0, 1.0));
    });

    test('confidence is the output posture share of the window', () {
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(15, s)));
      final o = sm.add(r(ft(15), b));
      expect(o.posture, s);
      // One 67 ms bowing frame at 0.9 in a 500 ms window of 0.9 weight.
      expect(o.confidence, closeTo(1 - 67 / 500, 0.01));
    });
  });

  group('flicker', () {
    test('single-frame flicker to every other posture is suppressed', () {
      for (final other in [b, p, Posture.sitting, u]) {
        final seq = List.filled(45, s);
        seq[20] = other;
        final out = run(MajoritySmoother(), frames(seq));
        expect(out.map((o) => o.posture), everyElement(s),
            reason: 'flicker to $other');
      }
    });

    test('two-frame flicker at full confidence is suppressed', () {
      final seq = List.filled(45, s);
      seq[20] = b;
      seq[21] = b;
      final out = run(MajoritySmoother(), frames(seq));
      expect(out.map((o) => o.posture), everyElement(s));
    });

    test('repeated isolated flickers are suppressed', () {
      final seq = [for (var i = 0; i < 150; i++) i % 5 == 3 ? b : s];
      final out = run(MajoritySmoother(), frames(seq));
      expect(out.map((o) => o.posture), everyElement(s));
    });
  });

  group('transitions', () {
    test('a real transition switches within about half the window', () {
      final seq = [...List.filled(30, s), ...List.filled(30, b)];
      final out = run(MajoritySmoother(), frames(seq));
      final changeT = ft(30);
      final firstB = out.firstWhere((o) => o.posture == b).tMs;
      expect(firstB - changeT, inInclusiveRange(200, 350));
      // No switching back, no extra changes.
      expect(changes(out), 1);
      expect(out.last.posture, b);
      expect(out.last.confidence, closeTo(1.0, 1e-9));
    });

    test('full prayer-like sequence follows every transition once', () {
      final seq = [
        ...List.filled(30, s),
        ...List.filled(30, b),
        ...List.filled(30, s),
        ...List.filled(30, p),
        ...List.filled(30, Posture.sitting),
        ...List.filled(30, p),
      ];
      final out = run(MajoritySmoother(), frames(seq));
      expect(changes(out), 5);
      final distinct = <Posture>[];
      for (final o in out) {
        if (distinct.isEmpty || distinct.last != o.posture) {
          distinct.add(o.posture);
        }
      }
      expect(distinct, [s, b, s, p, Posture.sitting, p]);
    });

    test('never lags a transition by more than the window', () {
      final seq = [...List.filled(30, s), ...List.filled(30, p)];
      final out = run(MajoritySmoother(), frames(seq));
      final firstP = out.firstWhere((o) => o.posture == p).tMs;
      expect(firstP - ft(30), lessThanOrEqualTo(500));
    });

    test('lower-confidence new posture still switches within the window', () {
      final raw = [
        for (var i = 0; i < 30; i++) r(ft(i), s, conf: 0.9),
        for (var i = 30; i < 60; i++) r(ft(i), b, conf: 0.5),
      ];
      final out = run(MajoritySmoother(), raw);
      final firstB = out.firstWhere((o) => o.posture == b).tMs;
      expect(firstB - ft(30), lessThanOrEqualTo(500));
      expect(changes(out), 1);
    });
  });

  group('time share rule', () {
    PostureReading c(int i, Posture posture, double conf) =>
        r(ft(i), posture, conf: conf);

    test('standing under half the time never outputs standing after sitting',
        () {
      // Jalsa at modest confidence, then a mix of confident standing misreads
      // and unknown: standing out-weighs everything but covers < 50% of time.
      final patterns = [
        [s, s, s, u, u, u, u], // 3/7 standing
        [u, s, u, u, s, u, s], // 3/7
        [s, u, s, u, Posture.sitting, u], // 2/6
        [s, s, Posture.sitting, u, s, u, u], // 3/7
      ];
      for (final pat in patterns) {
        final raw = [
          for (var i = 0; i < 45; i++) c(i, Posture.sitting, 0.6),
          for (var i = 45; i < 300; i++)
            pat[(i - 45) % pat.length] == u
                ? PostureReading.unknown(ft(i))
                : c(
                    i,
                    pat[(i - 45) % pat.length],
                    pat[(i - 45) % pat.length] == s ? 0.95 : 0.6,
                  ),
        ];
        final out = run(MajoritySmoother(), raw);
        expect(out.map((o) => o.posture), everyElement(isNot(s)),
            reason: 'pattern $pat');
      }
    });

    test('four standing frames do not flip a sitting output', () {
      final raw = [
        for (var i = 0; i < 45; i++) c(i, Posture.sitting, 0.6),
        for (var i = 45; i < 49; i++) c(i, s, 0.95),
        for (var i = 49; i < 70; i++) c(i, Posture.sitting, 0.6),
      ];
      final out = run(MajoritySmoother(), raw);
      expect(out.map((o) => o.posture), everyElement(Posture.sitting));
    });

    test('a real sitting -> standing transition still switches in the window',
        () {
      final raw = [
        for (var i = 0; i < 45; i++) c(i, Posture.sitting, 0.6),
        for (var i = 45; i < 90; i++) c(i, s, 0.95),
      ];
      final out = run(MajoritySmoother(), raw);
      final firstS = out.firstWhere((o) => o.posture == s).tMs;
      expect(firstS - ft(45), inInclusiveRange(200, 400));
      expect(changes(out), 1);
    });

    test('clean transitions between all postures still switch in the window',
        () {
      for (final from in [s, b, p, Posture.sitting]) {
        for (final to in [s, b, p, Posture.sitting]) {
          if (from == to) continue;
          final out = run(MajoritySmoother(),
              frames([...List.filled(30, from), ...List.filled(30, to)]));
          final first = out.firstWhere((o) => o.posture == to).tMs;
          expect(first - ft(30), inInclusiveRange(200, 350),
              reason: '$from -> $to');
          expect(changes(out), 1, reason: '$from -> $to');
        }
      }
    });
  });

  group('latency', () {
    test('raw torso angle exceeds 35 degrees while output is still standing',
        () {
      PostureReading f(int i, Posture posture, double torso, double hip) =>
          PostureReading(
              tMs: ft(i),
              posture: posture,
              confidence: 0.9,
              hipHeightRatio: hip,
              torsoAngleDeg: torso);
      final raw = [
        for (var i = 0; i < 30; i++) f(i, s, 5, 1.0),
        // Bowing starts: torso swings past 35 degrees within two frames.
        for (var i = 30; i < 45; i++) f(i, b, i == 30 ? 30 : 60, 0.95),
      ];
      final out = run(MajoritySmoother(), raw);
      final lagging = [
        for (final o in out)
          if (o.posture == s && o.torsoAngleDeg! > 35) o,
      ];
      // Several frames, spanning more than the spec's 0.2 s stop hold, where
      // the raw angle already says "not standing" but the posture does not.
      expect(lagging.length, greaterThanOrEqualTo(3));
      expect(lagging.last.tMs - lagging.first.tMs, greaterThanOrEqualTo(130));
      expect(out.last.posture, b);
    });
  });

  group('noise', () {
    test('alternating noise at 50/50 does not thrash', () {
      final seq = [
        ...List.filled(30, s),
        for (var i = 0; i < 150; i++) i.isEven ? b : s,
      ];
      final out = run(MajoritySmoother(), frames(seq));
      expect(out.map((o) => o.posture), everyElement(s));
    });

    test('alternating noise starting from bowing keeps bowing', () {
      final seq = [
        ...List.filled(30, b),
        for (var i = 0; i < 150; i++) i.isEven ? s : b,
      ];
      final out = run(MajoritySmoother(), frames(seq));
      expect(out.map((o) => o.posture), everyElement(b));
    });

    test('seeded random 50/50 noise changes far less often than raw', () {
      final rnd = Random(42);
      final seq = [for (var i = 0; i < 1500; i++) rnd.nextBool() ? s : b];
      final raw = frames(seq);
      final out = run(MajoritySmoother(), raw);
      var rawChanges = 0;
      for (var i = 1; i < raw.length; i++) {
        if (raw[i].posture != raw[i - 1].posture) rawChanges++;
      }
      expect(rawChanges, greaterThan(600));
      // i.i.d. coin flips do produce genuine 60% runs; the smoother follows
      // only those, so it changes several times less often than raw and
      // every output segment lasts at least a fifth of the window.
      expect(changes(out), lessThan(rawChanges ~/ 5));
      var lastChange = out.first.tMs;
      for (var i = 1; i < out.length; i++) {
        if (out[i].posture != out[i - 1].posture) {
          if (lastChange != out.first.tMs) {
            expect(out[i].tMs - lastChange, greaterThanOrEqualTo(100));
          }
          lastChange = out[i].tMs;
        }
      }
    });

    test('small confidence sway while standing never changes output', () {
      final rnd = Random(7);
      final raw = [
        ...frames(List.filled(15, s)),
        for (var i = 15; i < 300; i++)
          rnd.nextDouble() < 0.15
              ? r(ft(i), b, conf: 0.3 + 0.3 * rnd.nextDouble())
              : r(ft(i), s, conf: 0.6 + 0.4 * rnd.nextDouble()),
      ];
      final out = run(MajoritySmoother(), raw);
      expect(out.map((o) => o.posture), everyElement(s));
    });
  });

  group('takbir passthrough', () {
    test('takbir flag passes through on a steady posture', () {
      final seq = frames(List.filled(30, s));
      seq[12] = r(ft(12), s, takbir: true);
      final out = run(MajoritySmoother(), seq);
      for (var i = 0; i < out.length; i++) {
        expect(out[i].takbirRaise, i == 12);
      }
    });

    test('takbir passes through mid-transition, before the switch', () {
      final raw = frames([...List.filled(30, s), ...List.filled(30, b)]);
      raw[31] = r(ft(31), b, takbir: true);
      final out = run(MajoritySmoother(), raw);
      expect(out[31].posture, s, reason: 'posture not switched yet');
      expect(out[31].takbirRaise, isTrue);
      expect(out.where((o) => o.takbirRaise).length, 1);
    });

    test('takbir passes through on a flicker frame that is voted away', () {
      final raw = frames(List.filled(30, s));
      raw[15] = r(ft(15), b, takbir: true);
      final out = run(MajoritySmoother(), raw);
      expect(out[15].posture, s);
      expect(out[15].takbirRaise, isTrue);
    });

    test('takbir passes through on an unknown frame', () {
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(10, s)));
      final o = sm.add(PostureReading(
          tMs: ft(10), posture: u, confidence: 0, takbirRaise: true));
      expect(o.takbirRaise, isTrue);
      expect(o.posture, s);
    });
  });

  group('unknown', () {
    test('sustained unknown (heartbeats only) becomes unknown', () {
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(30, s)));
      final lostAt = ft(29);
      final out = [
        for (var t = lostAt + 100; t <= lostAt + 2000; t += 100)
          sm.add(PostureReading.unknown(t)),
      ];
      final firstU = out.firstWhere((o) => o.posture == u).tMs;
      expect(firstU - lostAt, inInclusiveRange(300, 500));
      expect(out.last.posture, u);
      expect(out.last.confidence, closeTo(1.0, 1e-9));
      expect(changes(out), 1);
    });

    test('short dropout of 200 ms does not lose the posture', () {
      final seq = List.filled(45, s);
      for (var i = 20; i < 23; i++) {
        seq[i] = u;
      }
      final out = run(MajoritySmoother(), frames(seq));
      expect(out.map((o) => o.posture), everyElement(s));
    });

    test('heartbeats interleaved with real frames do not out-vote them', () {
      final raw = <PostureReading>[
        ...frames(List.filled(150, s)),
        for (var t = 50; t < ft(150); t += 100) PostureReading.unknown(t),
      ]..sort((a, c) => a.tMs.compareTo(c.tMs));
      final out = run(MajoritySmoother(), raw);
      expect(out.map((o) => o.posture), everyElement(s));
    });

    test('unknown at 50/50 with a real posture keeps the real posture', () {
      final seq = [
        ...List.filled(30, s),
        for (var i = 0; i < 150; i++) i.isEven ? u : s,
      ];
      final out = run(MajoritySmoother(), frames(seq));
      expect(out.map((o) => o.posture), everyElement(s));
    });

    test('recovers from unknown when tracking returns', () {
      final sm = MajoritySmoother();
      run(sm, [for (var t = 0; t <= 1000; t += 100) PostureReading.unknown(t)]);
      expect(sm.current, u);
      final out = [for (var i = 0; i < 20; i++) sm.add(r(1000 + ft(i + 1), p))];
      final firstP = out.firstWhere((o) => o.posture == p).tMs;
      expect(firstP - 1000, lessThanOrEqualTo(500));
      expect(out.last.posture, p);
    });

    test('split between new posture and unknown releases the old one', () {
      // Standing, then bowing interleaved with dropouts: bowing never reaches
      // 0.6 of the window, but standing has no support left.
      final seq = [
        ...List.filled(30, s),
        for (var i = 0; i < 60; i++) i % 3 == 0 ? b : (i % 3 == 1 ? u : b),
      ];
      final out = run(MajoritySmoother(), frames(seq));
      expect(out.last.posture, b);
    });

    test('mostly unknown with sparse low-confidence frames becomes unknown',
        () {
      final seq = [
        ...List.filled(30, s),
        for (var i = 0; i < 60; i++) i % 4 == 0 ? b : u,
      ];
      final raw = frames(seq);
      for (var i = 30; i < raw.length; i++) {
        if (raw[i].posture == b) raw[i] = r(raw[i].tMs, b, conf: 0.3);
      }
      final out = run(MajoritySmoother(), raw);
      expect(out.last.posture, u);
    });
  });

  group('irregular timing', () {
    test('jittered frame intervals keep steady posture and one switch', () {
      final rnd = Random(3);
      final raw = <PostureReading>[];
      var t = 0;
      for (var i = 0; i < 120; i++) {
        raw.add(r(t, i < 60 ? s : b));
        t += 30 + rnd.nextInt(70); // 30..99 ms
      }
      final out = run(MajoritySmoother(), raw);
      expect(changes(out), 1);
      final firstB = out.firstWhere((o) => o.posture == b).tMs;
      expect(firstB - raw[60].tMs, inInclusiveRange(150, 400));
    });

    test('a burst of many frames counts only for the time it spans', () {
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(30, s)));
      var t = ft(29);
      final out = <PostureReading>[];
      // Ten bowing frames inside 20 ms: a frame-count vote would switch.
      for (var i = 0; i < 10; i++) {
        t += 2;
        out.add(sm.add(r(t, b)));
      }
      out.add(sm.add(r(t + 66, s)));
      expect(out.map((o) => o.posture), everyElement(s));
    });

    test('duplicate timestamps are accepted', () {
      final sm = MajoritySmoother();
      sm.add(r(0, s));
      sm.add(r(0, s));
      final o = sm.add(r(0, b));
      expect(o.posture, s);
      expect(sm.add(r(67, s)).posture, s);
    });

    test('heartbeat-only gap of 1 s during a held pose becomes unknown', () {
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(30, p)));
      final gapStart = ft(29);
      final hb = [
        for (var t = gapStart + 100; t <= gapStart + 1000; t += 100)
          sm.add(PostureReading.unknown(t)),
      ];
      expect(hb.last.posture, u);
      final back = [
        for (var i = 1; i <= 15; i++) sm.add(r(gapStart + 1000 + ft(i), p)),
      ];
      expect(back.last.posture, p);
      expect(back.firstWhere((o) => o.posture == p).tMs - (gapStart + 1000),
          lessThanOrEqualTo(500));
    });

    test('a stream gap with no readings counts as unknown, then recovers', () {
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(30, s)));
      final resume = ft(29) + 1000;
      final first = sm.add(r(resume, s));
      expect(first.posture, u, reason: 'nothing was observed during the gap');
      final out = [for (var i = 1; i <= 10; i++) sm.add(r(resume + ft(i), s))];
      final firstS = out.firstWhere((o) => o.posture == s).tMs;
      expect(firstS - resume, lessThanOrEqualTo(500));
      expect(out.last.posture, s);
    });

    test('a single frame after a gap cannot flip to a new posture', () {
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(30, s)));
      final o = sm.add(r(ft(29) + 1000, b));
      expect(o.posture, isNot(b));
    });

    test('out-of-order reading throws and leaves state unchanged', () {
      final sm = MajoritySmoother();
      final a = run(sm, frames(List.filled(10, s)));
      expect(() => sm.add(r(ft(8), b)), throwsArgumentError);
      final next = sm.add(r(ft(10), s));
      final fresh = MajoritySmoother();
      final expected = run(fresh, frames(List.filled(11, s))).last;
      expect(next, expected);
      expect(a.last.posture, s);
    });
  });

  group('reset', () {
    test('reset clears window, output and time ordering', () {
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(30, b)));
      expect(sm.current, b);
      sm.reset();
      expect(sm.current, u);
      // Earlier timestamps are accepted again and old votes are gone.
      final out = run(sm, frames(List.filled(5, s)));
      expect(out.first.posture, s);
      expect(out.first.confidence, closeTo(1.0, 1e-9));
    });

    test('output after reset equals a fresh smoother', () {
      final rnd = Random(11);
      final seq = [
        for (var i = 0; i < 200; i++) Posture.values[rnd.nextInt(5)],
      ];
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(50, p)));
      sm.reset();
      expect(run(sm, frames(seq)), run(MajoritySmoother(), frames(seq)));
    });
  });

  group('stream API', () {
    List<PostureReading> scenario() {
      final rnd = Random(5);
      final raw = <PostureReading>[];
      var t = 0;
      for (var i = 0; i < 400; i++) {
        final base = [s, b, s, p, Posture.sitting, p, s][(i ~/ 60) % 7];
        final x = rnd.nextDouble();
        final posture = x < 0.1 ? u : (x < 0.2 ? b : base);
        raw.add(r(t, posture,
            conf: 0.4 + 0.6 * rnd.nextDouble(), takbir: i % 97 == 5));
        t += 40 + rnd.nextInt(60);
      }
      return raw;
    }

    test('stream output equals the sync API', () async {
      final raw = scenario();
      final sync = run(MajoritySmoother(), raw);
      final streamed =
          await MajoritySmoother().smooth(Stream.fromIterable(raw)).toList();
      expect(streamed, sync);
      expect(streamed.where((o) => o.takbirRaise).length,
          raw.where((o) => o.takbirRaise).length);
    });

    test('smooth resets state at stream start', () async {
      final raw = scenario();
      final sm = MajoritySmoother();
      run(sm, frames(List.filled(50, Posture.sitting), from: 10000));
      final streamed = await sm.smooth(Stream.fromIterable(raw)).toList();
      expect(streamed, run(MajoritySmoother(), raw));
    });

    test('out-of-order reading is clamped, not a stream error', () async {
      final late = PostureReading(
          tMs: ft(5),
          posture: b,
          confidence: 1,
          takbirRaise: true,
          hipHeightRatio: 0.7,
          torsoAngleDeg: 70);
      final raw = [
        ...frames(List.filled(10, s)),
        late,
        ...frames(List.filled(10, s), from: 10),
      ];
      final out =
          await MajoritySmoother().smooth(Stream.fromIterable(raw)).toList();
      expect(out, hasLength(raw.length));
      // Clamped to the previous tMs, so output time never goes backwards.
      expect(out[10].tMs, ft(9));
      for (var i = 1; i < out.length; i++) {
        expect(out[i].tMs, greaterThanOrEqualTo(out[i - 1].tMs));
      }
      // Pass-through fields survive; the late reading carries no vote.
      expect(out[10].takbirRaise, isTrue);
      expect(out[10].torsoAngleDeg, 70);
      expect(out[10].hipHeightRatio, 0.7);
      expect(out.map((o) => o.posture), everyElement(s));
      expect(out[10].confidence, closeTo(1.0, 1e-9));
      // Everything after equals a stream without the late reading.
      final without = [...raw]..removeAt(10);
      final ref = run(MajoritySmoother(), without);
      expect(out.sublist(11), ref.sublist(10));
    });

    test('add still throws for out-of-order readings', () {
      final sm = MajoritySmoother();
      sm.add(r(100, s));
      expect(() => sm.add(r(50, s)), throwsArgumentError);
    });
  });
}
