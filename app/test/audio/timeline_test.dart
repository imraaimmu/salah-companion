import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/audio/timeline.dart';
import 'package:salah_core/salah_core.dart';

AyahClip clip(int surah, int ayah, int ms) => AyahClip(
  assetPath: 'a/$surah-$ayah',
  surah: surah,
  ayah: ayah,
  duration: Duration(milliseconds: ms),
);

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  // Al-Fatiha shortened to 2 ayahs to keep the expectations readable.
  final plan = RecitationPlan(
    clips: [
      clip(1, 6, 2000),
      clip(1, 7, 3000),
      clip(108, 1, 1500),
      clip(108, 2, 2500),
    ],
    preRoll: ms(6000),
    gapAfterAyah: ms(1000),
    gapAfterFatiha: ms(1500),
  );

  test('pre-roll, ayahs, gaps and the longer Ameen gap', () {
    final t = RecitationTimeline.fromPlan(plan);
    expect(t.segments.map((s) => s.toString()), [
      'Silence(6000 ms @ 0)',
      'Clip(1:6 @ 6000)',
      'Silence(1000 ms @ 8000)',
      'Clip(1:7 @ 9000)',
      'Silence(2500 ms @ 12000)', // gapAfterAyah + gapAfterFatiha
      'Clip(108:1 @ 14500)',
      'Silence(1000 ms @ 16000)',
      'Clip(108:2 @ 17000)', // nothing after the last ayah
    ]);
    expect(t.total, ms(19500));
  });

  test('zero pre-roll and zero gaps leave no silent entries', () {
    final t = RecitationTimeline.fromPlan(
      RecitationPlan(
        clips: plan.clips,
        preRoll: Duration.zero,
        gapAfterAyah: Duration.zero,
        gapAfterFatiha: Duration.zero,
      ),
    );
    expect(t.segments.every((s) => !s.isSilence), isTrue);
    expect(t.segments, hasLength(4));
  });

  test('Ameen gap applies even with no ayah gap', () {
    final t = RecitationTimeline.fromPlan(
      RecitationPlan(
        clips: plan.clips,
        preRoll: Duration.zero,
        gapAfterAyah: Duration.zero,
      ),
    );
    expect(t.segments.where((s) => s.isSilence).single.duration, ms(1500));
    expect(t.segments[2].isSilence, isTrue);
  });

  test('long silences are split into chunks of at most maxSilence', () {
    final t = RecitationTimeline.fromPlan(
      RecitationPlan(
        clips: [clip(1, 1, 1000)],
        preRoll: ms(18000),
        gapAfterAyah: ms(1000),
      ),
      maxSilence: const Duration(seconds: 10),
    );
    expect(t.segments.map((s) => s.duration), [ms(10000), ms(8000), ms(1000)]);
    expect(t.segments[2].start, ms(18000));
    expect(
      () => RecitationTimeline.fromPlan(plan, maxSilence: Duration.zero),
      throwsArgumentError,
    );
  });

  test('an empty plan gives an empty timeline', () {
    final t = RecitationTimeline.fromPlan(
      RecitationPlan(
        clips: const [],
        preRoll: ms(6000),
        gapAfterAyah: ms(1000),
      ),
    );
    expect(t.isEmpty, isTrue);
    expect(t.total, Duration.zero);
    expect(t.resumePointFor(3, ms(5)), const ResumePoint(0, Duration.zero));
  });

  group('resume point', () {
    final t = RecitationTimeline.fromPlan(plan);

    test('mid-ayah resumes from the start of that ayah', () {
      expect(
        t.resumePointFor(3, ms(2400)),
        const ResumePoint(3, Duration.zero),
      );
      expect(
        t.resumePointFor(1, Duration.zero),
        const ResumePoint(1, Duration.zero),
      );
    });

    test('in a gap or the pre-roll, only the remaining silence is kept', () {
      expect(t.resumePointFor(0, ms(4200)), ResumePoint(0, ms(4200)));
      expect(t.resumePointFor(4, ms(700)), ResumePoint(4, ms(700)));
    });

    test('out-of-range input is clamped', () {
      expect(t.resumePointFor(-1, ms(10)), const ResumePoint(0, Duration.zero));
      expect(t.resumePointFor(99, ms(10)), const ResumePoint(7, Duration.zero));
      expect(t.resumePointFor(0, ms(-5)), const ResumePoint(0, Duration.zero));
      expect(t.resumePointFor(4, ms(9999)), ResumePoint(4, ms(2500)));
    });

    test('the clip at or after an index', () {
      expect(t.clipAtOrAfter(0)!.ayah, 6);
      expect(t.clipAtOrAfter(4)!.surah, 108);
      expect(t.clipAtOrAfter(7)!.ayah, 2);
      expect(t.clipAtOrAfter(8), isNull);
    });
  });

  group('volume ramp', () {
    test('300 ms in 20 ms steps ends exactly at the target', () {
      final r = volumeRamp(1, 0, ms(300));
      expect(r, hasLength(15));
      expect(r.last, 0);
      for (var i = 1; i < r.length; i++) {
        expect(r[i], lessThan(r[i - 1]));
      }
    });

    test('fade in from a partial volume', () {
      final r = volumeRamp(0.5, 1, ms(100), step: ms(25));
      expect(r, [0.625, 0.75, 0.875, 1.0]);
    });

    test('zero duration jumps to the target', () {
      expect(volumeRamp(1, 0, Duration.zero), [0]);
    });
  });
}
