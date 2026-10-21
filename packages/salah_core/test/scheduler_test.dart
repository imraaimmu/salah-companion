import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

Duration ms(int v) => Duration(milliseconds: v);

AyahClip clip(int surah, int ayah, int lengthMs) => AyahClip(
    assetPath: '$surah-$ayah',
    surah: surah,
    ayah: ayah,
    duration: ms(lengthMs));

/// Fatiha 1:1-1:3 (4000, 5000, 6000 ms), then 93:1-93:2 (3000, 2000 ms).
///
/// Timeline: preRoll [0, 6000) | 1:1 [6000, 10000) gap 1500 |
/// 1:2 [11500, 16500) gap 1500 | 1:3 [18000, 24000) Ameen gap 3000 |
/// 93:1 [27000, 30000) gap 1500 | 93:2 [31500, 33500). Total 33500.
final plan = RecitationPlan(
  clips: [
    clip(1, 1, 4000),
    clip(1, 2, 5000),
    clip(1, 3, 6000),
    clip(93, 1, 3000),
    clip(93, 2, 2000),
  ],
  preRoll: ms(6000),
  gapAfterAyah: ms(1500),
  gapAfterFatiha: ms(1500),
);

void main() {
  group('timeline', () {
    test('pre-roll, ayah gaps, Ameen gap after Al-Fatiha, no trailing gap', () {
      final t = RecitationScheduler.timeline(plan);
      expect(t.map((c) => c.start.inMilliseconds),
          [6000, 11500, 18000, 27000, 31500]);
      expect(
          t.map((c) => c.gapAfter.inMilliseconds), [1500, 1500, 3000, 1500, 0]);
      expect(t.map((c) => c.end.inMilliseconds),
          [10000, 16500, 24000, 30000, 33500]);
      expect(t.map((c) => c.index), [0, 1, 2, 3, 4]);
      expect(t[3].clip.surah, 93);
      expect(RecitationScheduler(plan).total, ms(33500));
      expect(RecitationScheduler(plan).clips.map((c) => c.start),
          t.map((c) => c.start));
    });

    test('the default Ameen gap is 1.5 s extra', () {
      final p = RecitationPlan(
          clips: [clip(1, 7, 1000), clip(112, 1, 1000)],
          preRoll: Duration.zero,
          gapAfterAyah: ms(700));
      final t = RecitationScheduler.timeline(p);
      expect(t.map((c) => c.start.inMilliseconds), [0, 3200]);
      expect(RecitationScheduler(p).total, ms(4200));
    });

    test('zero gaps place clips back to back', () {
      final p = RecitationPlan(
          clips: [clip(1, 1, 1234), clip(1, 2, 1), clip(94, 1, 999)],
          preRoll: ms(1500),
          gapAfterAyah: Duration.zero,
          gapAfterFatiha: Duration.zero);
      expect(RecitationScheduler.timeline(p).map((c) => c.start.inMilliseconds),
          [1500, 2734, 2735]);
      expect(RecitationScheduler(p).total, ms(3734));
    });

    test('a plan without Al-Fatiha first has no Ameen gap', () {
      final p = RecitationPlan(
          clips: [clip(93, 1, 1000), clip(1, 1, 1000), clip(93, 2, 1000)],
          preRoll: Duration.zero,
          gapAfterAyah: ms(100));
      expect(RecitationScheduler.fatihaLastIndex(p), -1);
      expect(RecitationScheduler.timeline(p).map((c) => c.gapAfter),
          [ms(100), ms(100), Duration.zero]);
    });

    test('Al-Fatiha alone ends with its last ayah', () {
      final p = RecitationPlan(
          clips: [clip(1, 1, 1000), clip(1, 2, 1000)],
          preRoll: ms(10),
          gapAfterAyah: ms(100));
      expect(RecitationScheduler.fatihaLastIndex(p), 1);
      expect(RecitationScheduler.timeline(p).map((c) => c.gapAfter),
          [ms(100), Duration.zero]);
      expect(RecitationScheduler(p).total, ms(2110));
    });

    test('an empty plan lasts its pre-roll', () {
      final p = RecitationPlan(
          clips: const [], preRoll: ms(6000), gapAfterAyah: ms(1500));
      final s = RecitationScheduler(p);
      expect(s.clips, isEmpty);
      expect(s.total, ms(6000));
      expect(s.positionAt(ms(5999)).phase, ScheduledPhase.preRoll);
      expect(s.positionAt(ms(6000)).phase, ScheduledPhase.finished);
      expect(s.positionAt(ms(6000)).clip, isNull);
      expect(s.resumePointFor(ms(7000)), ms(6000));
    });

    test('negative durations are rejected', () {
      expect(
          () => RecitationScheduler.timeline(RecitationPlan(
              clips: const [], preRoll: ms(-1), gapAfterAyah: Duration.zero)),
          throwsArgumentError);
      expect(
          () => RecitationScheduler.timeline(RecitationPlan(
              clips: [clip(1, 1, -5)],
              preRoll: Duration.zero,
              gapAfterAyah: Duration.zero)),
          throwsArgumentError);
    });
  });

  group('positionAt', () {
    final s = RecitationScheduler(plan);

    void at(int t, ScheduledPhase phase, int? index, int offset, int left) {
      final p = s.positionAt(ms(t));
      expect(p.phase, phase, reason: 't=$t');
      expect(p.clipIndex, index, reason: 't=$t');
      expect(p.offset, ms(offset), reason: 't=$t offset');
      expect(p.remaining, ms(left), reason: 't=$t remaining');
    }

    test('pre-roll', () {
      at(0, ScheduledPhase.preRoll, null, 0, 6000);
      at(5999, ScheduledPhase.preRoll, null, 5999, 1);
      at(-50, ScheduledPhase.preRoll, null, 0, 6000);
    });

    test('clips, half-open', () {
      at(6000, ScheduledPhase.clip, 0, 0, 4000);
      at(9999, ScheduledPhase.clip, 0, 3999, 1);
      at(11500, ScheduledPhase.clip, 1, 0, 5000);
      at(20000, ScheduledPhase.clip, 2, 2000, 4000);
      at(27000, ScheduledPhase.clip, 3, 0, 3000);
      at(33499, ScheduledPhase.clip, 4, 1999, 1);
    });

    test('gaps, including the Ameen gap', () {
      at(10000, ScheduledPhase.gap, 0, 0, 1500);
      at(11499, ScheduledPhase.gap, 0, 1499, 1);
      at(24000, ScheduledPhase.gap, 2, 0, 3000);
      at(25000, ScheduledPhase.gap, 2, 1000, 2000);
      at(30000, ScheduledPhase.gap, 3, 0, 1500);
    });

    test('finished', () {
      at(33500, ScheduledPhase.finished, 4, 0, 0);
      at(40000, ScheduledPhase.finished, 4, 6500, 0);
    });

    test('every millisecond is consistent with the timeline', () {
      for (var t = 0; t < 34000; t += 7) {
        final p = s.positionAt(ms(t));
        switch (p.phase) {
          case ScheduledPhase.clip:
            expect(p.clip!.start + p.offset, ms(t));
            expect(ms(t) < p.clip!.end, isTrue);
          case ScheduledPhase.gap:
            expect(p.clip!.end + p.offset, ms(t));
            expect(ms(t) < p.clip!.gapEnd, isTrue);
          case ScheduledPhase.preRoll:
            expect(p.offset, ms(t));
          case ScheduledPhase.finished:
            expect(s.total + p.offset, ms(t));
        }
      }
    });
  });

  group('resumePointFor', () {
    final s = RecitationScheduler(plan);

    test('in a clip: the start of that ayah', () {
      expect(s.resumePointFor(ms(6000)), ms(6000));
      expect(s.resumePointFor(ms(8000)), ms(6000));
      expect(s.resumePointFor(ms(16499)), ms(11500));
      expect(s.resumePointFor(ms(28000)), ms(27000));
      expect(s.resumePointFor(ms(33499)), ms(31500));
    });

    test('in the pre-roll or a gap: the paused point', () {
      expect(s.resumePointFor(ms(3000)), ms(3000));
      expect(s.resumePointFor(ms(10000)), ms(10000));
      expect(s.resumePointFor(ms(10700)), ms(10700));
      expect(s.resumePointFor(ms(26999)), ms(26999));
      expect(s.resumePointFor(ms(-10)), Duration.zero);
    });

    test('after the end: the end', () {
      expect(s.resumePointFor(ms(33500)), ms(33500));
      expect(s.resumePointFor(ms(99999)), ms(33500));
    });
  });
}
