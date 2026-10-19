import 'dart:math' as math;

import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Scoring on hand-built labels and events
// ---------------------------------------------------------------------------

LabelInterval iv(int s, int e, PrayerState st, {Posture? p}) {
  final rakah = switch (st) {
    PrayerState.waiting || PrayerState.takbir => 0,
    PrayerState.qiyam1 ||
    PrayerState.ruku1 ||
    PrayerState.itidal1 ||
    PrayerState.sujood1 =>
      1,
    _ => 2,
  };
  final posture = p ??
      switch (st) {
        PrayerState.ruku1 || PrayerState.ruku2 => Posture.bowing,
        PrayerState.sujood1 || PrayerState.sujood2 => Posture.prostrating,
        PrayerState.finalSitting => Posture.sitting,
        _ => Posture.standing,
      };
  return LabelInterval(
      startMs: s, endMs: e, posture: posture, state: st, rakah: rakah);
}

/// waiting, takbir at 1000, qiyam1 1800-10000, ruku1, itidal1, sujood1,
/// qiyam2 20000-30000 (standing from 20300), ruku2 ..., finalSitting.
LabelSet labels({bool takbir = true}) => LabelSet(
      recording: 'x.recording.ndjson',
      takbirTimesMs: takbir ? const [1000] : const [],
      intervals: [
        iv(0, 1000, PrayerState.waiting),
        iv(1000, 1800, takbir ? PrayerState.takbir : PrayerState.waiting),
        iv(1800, 10000, takbir ? PrayerState.qiyam1 : PrayerState.waiting),
        iv(10000, 13000, PrayerState.ruku1),
        iv(13000, 15000, PrayerState.itidal1),
        iv(15000, 20000, PrayerState.sujood1),
        iv(20000, 20300, PrayerState.qiyam2, p: Posture.unknown),
        iv(20300, 30000, PrayerState.qiyam2),
        iv(30000, 33000, PrayerState.ruku2),
        iv(33000, 35000, PrayerState.itidal2),
        iv(35000, 40000, PrayerState.sujood2),
        iv(40000, 50000, PrayerState.finalSitting),
      ],
    );

const toFinal = [
  StateChanged(40500,
      from: PrayerState.sujood2, to: PrayerState.finalSitting, rakah: 2),
];

ReplayResult scoreOf(List<PrayerEvent> events,
        {LabelSet? l, bool strict = false}) =>
    score(l ?? labels(), [...events, ...toFinal],
        name: 'x', endMs: 50000, strict: strict);

// ---------------------------------------------------------------------------
// The pipeline on synthetic prayers
// ---------------------------------------------------------------------------

const timeScale = 0.05;

/// Every case x [seeds] seeds, clean and perturbed, plus a random batch.
List<SyntheticPrayer> dataset({int seeds = 4, int batch = 100}) => [
      for (final c in SyntheticCase.values)
        for (var s = 1; s <= seeds; s++) ...[
          generateSyntheticPrayer(c,
              seed: s,
              options: const SyntheticOptions.clean(timeScale: timeScale)),
          generateSyntheticPrayer(c,
              seed: s,
              options: SyntheticOptions.random(math.Random(s * 1009 + c.index),
                  timeScale: timeScale),
              name: 'synthetic-${c.name}-s$s-perturbed'),
        ],
      ...generateSyntheticBatch(batch, seed: 7777, timeScale: timeScale),
    ];

/// True when [o] happened while the user could not be seen at the bow: a
/// stretch of readings with no raw values began before the grace ran out,
/// and playback stopped within one early-stop hold (plus a frame) of the
/// first reading with raw values after it, or by the 2 s lost-tracking rule.
///
/// The state machine cannot stop for a bow it never sees (a missed ruku with
/// the frames dropped, or a frame dropout burst over the bow); it pauses the
/// recitation after 0.6 s without body data instead, and paused time is not
/// playing time, so the zero-overrun test below must hold too.
bool unobservedBow(ReplayResult r, Overrun o, {int graceMs = defaultGraceMs}) {
  int? blindFrom;
  for (final x in r.readings) {
    if (x.tMs > o.untilMs) break;
    final raw = x.hipHeightRatio != null || x.torsoAngleDeg != null;
    if (!raw) {
      blindFrom ??= x.tMs;
      continue;
    }
    final from = blindFrom;
    blindFrom = null;
    if (from != null &&
        from <= o.leftQiyamMs + graceMs &&
        x.tMs >= o.leftQiyamMs &&
        o.untilMs <= x.tMs + 200 + 100) {
      return true;
    }
  }
  // Still blind at the stop: lost tracking.
  return blindFrom != null &&
      blindFrom <= o.leftQiyamMs + graceMs &&
      r.events.any((e) => e is TrackingLost && e.tMs == o.untilMs);
}

void main() {
  group('score', () {
    test('a clean run scores perfectly', () {
      final r = scoreOf(const [
        StartRecitation(2000, rakah: 1),
        StopRecitation(10300),
        StartRecitation(21000, rakah: 2),
        StopRecitation(30250),
      ]);
      expect(r.wrongTimeAudio, isFalse);
      expect(r.missed, isEmpty);
      expect(r.eligibleQiyam, hasLength(2));
      expect(r.startLatencyMs, {1: 200, 2: 1000});
      expect(r.startFromStandingMs, {1: 200, 2: 700});
      expect(r.stopLatencyMs, {1: 300, 2: 250});
      expect(r.rakahCountOk, isTrue);
      expect(r.problems, isEmpty);
      // Both recitations played a little past the label: reported at
      // grace 0, not wrong-time.
      expect(r.overrunsAtZeroGrace.map((o) => o.overrunMs), [300, 250]);
      expect(ReplaySummary([r]).overrunsAtZeroGrace, 2);
    });

    test('a start outside its own qiyam is wrong-time', () {
      final r = scoreOf(const [
        StartRecitation(14000, rakah: 2), // i'tidal 1
        StopRecitation(14100),
      ]);
      expect(r.wrongStarts.single.labelState, PrayerState.itidal1);
      expect(r.wrongTimeAudio, isTrue);
      // Neither qiyam got its recitation.
      expect(r.missed, hasLength(2));
    });

    test('playing past the grace after the label left qiyam is an overrun', () {
      final ok = scoreOf(const [
        StartRecitation(21000, rakah: 2),
        StopRecitation(30500), // exactly the 500 ms default grace
      ]);
      expect(ok.overruns, isEmpty);
      expect(ok.overrunsAtZeroGrace.single.overrunMs, 500);
      final late = scoreOf(const [
        StartRecitation(21000, rakah: 2),
        StopRecitation(30900),
      ]);
      expect(late.overruns.single.overrunMs, 400);
      expect(late.overruns.single.leftQiyamMs, 30000);
      expect(late.overruns.single.labelState, PrayerState.ruku2);
      expect(late.worstOverrunMs, 400);
      expect(late.wrongTimeAudio, isTrue);
      // A 1 s grace (the spec's bowing-to-silence target) still accepts it.
      final lenient = score(
          labels(),
          const [
            StartRecitation(21000, rakah: 2),
            StopRecitation(30900),
            ...toFinal
          ],
          name: 'x',
          endMs: 50000,
          graceMs: 1000);
      expect(lenient.overruns, isEmpty);
    });

    test('no stop: plays until the session ends (or the last reading)', () {
      final r = scoreOf(const [
        StartRecitation(21000, rakah: 2),
        SessionEnded(33000, reason: EndReason.timeout),
      ]);
      expect(r.overruns.single.overrunMs, 2500);
      final r2 = score(labels(), const [StartRecitation(21000, rakah: 2)],
          name: 'x', endMs: 32000);
      expect(r2.overruns.single.overrunMs, 1500);
    });

    test(
        'rak\'ah 1 starting in the labelled takbir standing is early, '
        'not wrong-time (unless strict)', () {
      const events = [StartRecitation(1550, rakah: 1), StopRecitation(10200)];
      final r = scoreOf(events);
      expect(r.wrongTimeAudio, isFalse);
      expect(r.earlyStartsMs, [250]);
      expect(r.earlyBeyondTolerance, 0);
      expect(r.startLatencyMs[1], -250);
      expect(r.missed.map((q) => q.rakah), [2]);

      final far = scoreOf(
          const [StartRecitation(1100, rakah: 1), StopRecitation(10200)]);
      expect(far.earlyStartsMs, [700]);
      expect(far.earlyBeyondTolerance, 1);
      expect(far.wrongTimeAudio, isFalse);

      final strict = scoreOf(events, strict: true);
      expect(strict.wrongStarts.single.labelState, PrayerState.takbir);
      expect(strict.missed, hasLength(2));
    });

    test('qiyam 1 counts as a rak\'ah only after a labelled takbir', () {
      final r = scoreOf(const [], l: labels(takbir: false));
      expect(r.eligibleQiyam.map((q) => q.rakah), [2]);
      expect(r.missed.map((q) => q.rakah), [2]);
    });

    test('final sitting reached or not', () {
      final r = score(labels(), const [], name: 'x', endMs: 50000);
      expect(r.rakahCountOk, isFalse);
      expect(r.problems, contains('final sitting not reached'));
    });

    test('a stop long before the label leaves qiyam is cut short', () {
      final r = scoreOf(const [
        StartRecitation(21000, rakah: 2),
        StopRecitation(25000),
      ]);
      expect(r.prematureStops, 1);
      expect(r.stopLatencyMs[2], -5000);
      expect(r.wrongTimeAudio, isFalse);
    });

    test('unobservedBow: only overruns while the user was not seen', () {
      PostureReading seen(int t) => PostureReading(
          tMs: t,
          posture: Posture.standing,
          confidence: 0.9,
          hipHeightRatio: 1,
          torsoAngleDeg: 2);
      ReplayResult run(bool blind) => score(labels(),
          const [StartRecitation(21000, rakah: 2), StopRecitation(31400)],
          name: 'x',
          endMs: 50000,
          readings: [
            for (var t = 29000; t < 32000; t += 67)
              blind && t >= 29800 && t < 31200
                  ? PostureReading.unknown(t)
                  : seen(t),
          ]);
      final observed = run(false);
      expect(unobservedBow(observed, observed.overruns.single), isFalse);
      final hidden = run(true);
      expect(unobservedBow(hidden, hidden.overruns.single), isTrue);
    });

    test('paused time is silent: no overrun, and stop latency from silence',
        () {
      // Paused at 30200 (just after the bow), stopped for good at 32000.
      final r = scoreOf(const [
        StartRecitation(21000, rakah: 2),
        PauseRecitation(30200, rakah: 2),
        StopRecitation(32000),
      ]);
      expect(r.overruns, isEmpty);
      expect(r.pauses, 1);
      expect(r.resumes, 0);
      expect(r.stopLatencyMs[2], 200);
      expect(r.wrongTimeAudio, isFalse);
    });

    test('a resume inside qiyam continues playing; overruns count after it',
        () {
      final ok = scoreOf(const [
        StartRecitation(21000, rakah: 2),
        PauseRecitation(25000, rakah: 2),
        ResumeRecitation(26000, rakah: 2),
        StopRecitation(30300),
      ]);
      expect(ok.wrongTimeAudio, isFalse);
      expect(ok.resumes, 1);
      expect(ok.prematureStops, 0);
      final late = scoreOf(const [
        StartRecitation(21000, rakah: 2),
        PauseRecitation(25000, rakah: 2),
        ResumeRecitation(26000, rakah: 2),
        StopRecitation(31000),
      ]);
      expect(late.overruns.single.overrunMs, 500);
    });

    test('a resume outside qiyam is wrong-time audio', () {
      final r = scoreOf(const [
        StartRecitation(21000, rakah: 2),
        PauseRecitation(29800, rakah: 2),
        ResumeRecitation(33500, rakah: 2), // i'tidal 2
        StopRecitation(33600),
      ]);
      expect(r.wrongResumes.single.labelState, PrayerState.itidal2);
      expect(r.wrongTimeAudio, isTrue);
      expect(r.problems, contains('resumed outside qiyam'));
      // Playing 33500-33600 is past the grace too.
      expect(r.overruns.single.overrunMs, 100);
    });

    test('paused then stopped for good mid-qiyam is cut short', () {
      final r = scoreOf(const [
        StartRecitation(21000, rakah: 2),
        PauseRecitation(24000, rakah: 2),
        StopRecitation(25500),
      ]);
      expect(r.prematureStops, 1);
      expect(r.stopLatencyMs[2], -6000);
    });

    test('percentile is nearest-rank', () {
      expect(percentile([], 50), isNull);
      expect(percentile([5], 90), 5);
      expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90), 9);
      expect(percentile([10, 1, 5], 50), 5);
    });
  });

  group('replay', () {
    const header = RecordingHeader(
      engine: 'test',
      model: 'test',
      fps: 15,
      orientation: 'portrait',
      side: 'left',
      device: 'test',
      imageW: 480,
      imageH: 640,
    );
    PoseFrame empty(int t) =>
        PoseFrame(tMs: t, landmarks: null, imageW: 480, imageH: 640);

    test('heartbeats only where frames are missing for more than 100 ms', () {
      ReplayResult run(List<int> ts) => replay(
          Recording(header: header, frames: [for (final t in ts) empty(t)]),
          labels(),
          options: const ReplayOptions(keepReadings: true));
      expect(run([0, 67, 133, 200]).heartbeats, 0);
      expect(run([0, 100, 200]).heartbeats, 0);
      expect(run([0, 150]).heartbeats, 1);
      // Never stamped at (or after) the next frame's time: lastFrameT + k*100
      // strictly before it.
      expect(run([0, 200]).heartbeats, 1);
      expect(run([0, 201]).heartbeats, 2);
      final r = run([0, 67, 400]);
      expect(r.heartbeats, 3);
      expect(r.frames, 3);
      expect([for (final x in r.readings) x.tMs], [0, 67, 167, 267, 367, 400]);
    });

    test('runs the synthetic pipeline end to end', () {
      final p = generateSyntheticPrayer(SyntheticCase.normal,
          seed: 1, options: const SyntheticOptions.clean(timeScale: 0.05));
      final r = replay(p.recording, p.labels, name: p.name);
      expect(r.name, p.name);
      expect(r.problems, isEmpty);
      expect(r.events.whereType<StartRecitation>().map((e) => e.rakah), [1, 2]);
      expect(r.finalState, PrayerState.done);
      expect(r.endReason, EndReason.completed);
    });
  });

  group('accuracy on synthetic prayers', () {
    late List<ReplayResult> results;
    late ReplaySummary summary;

    /// The random batch alone: independent seeds and timings. (In the case
    /// matrix every case with the same seed shares the same random timings,
    /// so its latencies are strongly correlated.)
    late ReplaySummary batch;

    setUpAll(() {
      results = [
        for (final p in dataset())
          replay(p.recording, p.labels,
              name: p.name, options: const ReplayOptions(keepReadings: true)),
      ];
      summary = ReplaySummary(results);
      batch = ReplaySummary(results.sublist(results.length - 100));
    });

    test('dataset size', () {
      // 13 cases x 4 seeds x clean/perturbed + 100 random prayers.
      expect(summary.prayers, 204);
      expect(summary.rakahs, greaterThan(380));
    });

    test('zero wrong-time starts', () {
      final wrong = [
        for (final r in results)
          for (final w in r.wrongStarts) '${r.name}: $w',
      ];
      expect(wrong, isEmpty);
    });

    test('no recitation still playing past the grace while the user is seen',
        () {
      final unexplained = [
        for (final r in results)
          for (final o in r.overruns)
            if (!unobservedBow(r, o)) '${r.name}: $o',
      ];
      expect(unexplained, isEmpty);
    });

    test(
        'zero wrong-time audio, including bows the camera never saw '
        '(spec target)', () {
      // Blind spots pause the recitation after 0.6 s without body data, so
      // overruns are measured on playing time only and must be 0.
      final overruns = [
        for (final r in results)
          for (final o in r.overruns) '${r.name}: $o',
      ];
      expect(overruns, isEmpty);
      final resumes = [
        for (final r in results)
          for (final w in r.wrongResumes) '${r.name}: $w',
      ];
      expect(resumes, isEmpty);
      expect(summary.wrongTimePrayers, 0);
    });

    test('blind spots are exercised: some pauses, resumes only after them', () {
      expect(summary.pauses, greaterThan(0));
      expect(summary.resumes, lessThanOrEqualTo(summary.pauses));
    });

    test('missed qiyam at most 1% of rak\'ahs (spec 2%)', () {
      // Measured: 0 of 1000 (cases x 20 seeds), 4 of 1000 (520-prayer
      // batch); each miss is a takbir raise lost in a dropout.
      expect(summary.missedRate, lessThanOrEqualTo(0.01));
    });

    test('final sitting reached exactly when labelled, in 99% of prayers', () {
      // Measured: 0 of 520 and 1 of 520 (dropouts in a 6 s tashahhud).
      expect(
          summary.rakahCountWrong / summary.prayers, lessThanOrEqualTo(0.01));
    });

    test('rak\'ah 1 starts within 0.3 s of the labelled qiyam 1 (p90)', () {
      final abs = [for (final v in batch.startLatencies(1)) v.abs()];
      // Spec: opening-dua pause +/- 0.3 s. Measured p90 of |latency| 0.20 s
      // on 520 random prayers. The earliest start, 0.31 s before the label,
      // is the classifier firing the takbir mid-lowering.
      expect(percentile(abs, 90), lessThanOrEqualTo(300));
      expect(summary.maxEarlyMs, lessThanOrEqualTo(350));
    });

    test('rak\'ah 2 starts within 0.8 s of the 0.8 s hold (p90)', () {
      // Spec: at most 1.0 s after the hold. Measured p90 from the qiyam2
      // label (middle of the rise) 1.46-1.51 s, i.e. hold + 0.7 s.
      expect(summary.startP(2, 90), lessThanOrEqualTo(800 + 800));
      expect(summary.startP(2, 50), greaterThanOrEqualTo(800));
    });

    test('bow to stop within 0.4 s (p90; spec 1.0 s)', () {
      // Measured p90 0.26-0.28 s, all prayers included.
      expect(summary.stopP(90), lessThanOrEqualTo(400));
      // A blind span over 1 s mid-qiyam (a dropout burst) now stops the
      // recitation for good instead of resuming it, since a fast ruku fits
      // in ~2 s: audio cut short, never wrong-time. Measured: 1 of 204.
      expect(summary.prematureStops, lessThanOrEqualTo(summary.prayers ~/ 100));
    });
  });
}
