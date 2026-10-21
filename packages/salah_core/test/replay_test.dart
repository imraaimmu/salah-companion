import 'dart:math' as math;

import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Scoring on hand-built labels and events
// ---------------------------------------------------------------------------

const waiting = PrayerState.waiting;
const takbirSt = PrayerState.takbir;
const qiyam = PrayerState.qiyam;
const ruku = PrayerState.ruku;
const itidal = PrayerState.itidal;
const sujood = PrayerState.sujood;
const middle = PrayerState.middleSitting;
const finalSitting = PrayerState.finalSitting;

LabelInterval iv(int s, int e, PrayerState st, [int rakah = 0, Posture? p]) {
  final posture = p ??
      switch (st) {
        PrayerState.ruku => Posture.bowing,
        PrayerState.sujood => Posture.prostrating,
        PrayerState.middleSitting ||
        PrayerState.finalSitting =>
          Posture.sitting,
        _ => Posture.standing,
      };
  return LabelInterval(
      startMs: s, endMs: e, posture: posture, state: st, rakah: rakah);
}

/// waiting, takbir at 1000, qiyam 1 1800-10000, ruku 1, itidal 1, sujood 1,
/// qiyam 2 20000-30000 (standing from 20300), ruku 2 ..., finalSitting.
LabelSet labels({bool takbir = true}) => LabelSet(
      recording: 'x.recording.ndjson',
      takbirTimesMs: takbir ? const [1000] : const [],
      intervals: [
        iv(0, 1000, waiting),
        iv(1000, 1800, takbir ? takbirSt : waiting),
        takbir ? iv(1800, 10000, qiyam, 1) : iv(1800, 10000, waiting),
        iv(10000, 13000, ruku, 1),
        iv(13000, 15000, itidal, 1),
        iv(15000, 20000, sujood, 1),
        iv(20000, 20300, qiyam, 2, Posture.unknown),
        iv(20300, 30000, qiyam, 2),
        iv(30000, 33000, ruku, 2),
        iv(33000, 35000, itidal, 2),
        iv(35000, 40000, sujood, 2),
        iv(40000, 50000, finalSitting, 2),
      ],
    );

const toFinal = [
  StateChanged(40500, from: sujood, to: finalSitting, rakah: 2),
];

/// [labels] continued as Isha: middle sitting 40000-50000, qiyam 3
/// 50000-60000, ruku/itidal/sujood 3, qiyam 4 70000-80000, ..., final
/// sitting 90000-100000.
LabelSet ishaLabels() => LabelSet(
      recording: 'isha.recording.ndjson',
      prayer: Prayer.isha,
      takbirTimesMs: const [1000],
      intervals: [
        ...labels().intervals.where((i) => i.state != finalSitting),
        iv(40000, 50000, middle, 2),
        iv(50000, 60000, qiyam, 3),
        iv(60000, 63000, ruku, 3),
        iv(63000, 65000, itidal, 3),
        iv(65000, 70000, sujood, 3),
        iv(70000, 80000, qiyam, 4),
        iv(80000, 83000, ruku, 4),
        iv(83000, 85000, itidal, 4),
        iv(85000, 90000, sujood, 4),
        iv(90000, 100000, finalSitting, 4),
      ],
    );

/// The machine's state changes for a clean Isha against [ishaLabels].
const ishaChanges = [
  StateChanged(1000, from: waiting, to: takbirSt, rakah: 0),
  StateChanged(1800, from: takbirSt, to: qiyam, rakah: 1),
  StateChanged(10500, from: qiyam, to: ruku, rakah: 1),
  StateChanged(13000, from: ruku, to: itidal, rakah: 1),
  StateChanged(15500, from: itidal, to: sujood, rakah: 1),
  StateChanged(21000, from: sujood, to: qiyam, rakah: 2),
  StateChanged(30500, from: qiyam, to: ruku, rakah: 2),
  StateChanged(33000, from: ruku, to: itidal, rakah: 2),
  StateChanged(35500, from: itidal, to: sujood, rakah: 2),
  StateChanged(43000, from: sujood, to: middle, rakah: 2),
  StateChanged(51000, from: middle, to: qiyam, rakah: 3),
  StateChanged(60500, from: qiyam, to: ruku, rakah: 3),
  StateChanged(63000, from: ruku, to: itidal, rakah: 3),
  StateChanged(65500, from: itidal, to: sujood, rakah: 3),
  StateChanged(71000, from: sujood, to: qiyam, rakah: 4),
  StateChanged(80500, from: qiyam, to: ruku, rakah: 4),
  StateChanged(83000, from: ruku, to: itidal, rakah: 4),
  StateChanged(85500, from: itidal, to: sujood, rakah: 4),
  StateChanged(95000, from: sujood, to: finalSitting, rakah: 4),
];

List<PrayerEvent> withChanges(List<PrayerEvent> audio) =>
    [...audio, ...ishaChanges]..sort((a, b) => a.tMs.compareTo(b.tMs));

/// The machine's state changes for a clean Fajr against [labels].
final fajrChanges = [
  ...ishaChanges.where((e) => e.tMs < 40000),
  ...toFinal,
];

ReplayResult scoreOf(List<PrayerEvent> events,
        {LabelSet? l, bool strict = false}) =>
    score(l ?? labels(),
        [...events, ...fajrChanges]..sort((a, b) => a.tMs.compareTo(b.tMs)),
        name: 'x', endMs: 50000, strict: strict);

// ---------------------------------------------------------------------------
// The pipeline on synthetic prayers
// ---------------------------------------------------------------------------

const timeScale = 0.05;

/// Seeds per case, per prayer (Dhuhr and Asr script like Isha).
const seedsFor = {
  Prayer.fajr: 2,
  Prayer.maghrib: 2,
  Prayer.isha: 2,
  Prayer.dhuhr: 1,
  Prayer.asr: 1,
};

/// Every case of every prayer x its seeds, clean and perturbed, plus a
/// random batch cycling through the five prayers.
List<SyntheticPrayer> dataset({int batch = 100}) => [
      for (final p in Prayer.values)
        for (final c in SyntheticCase.forPrayer(p))
          for (var s = 1; s <= seedsFor[p]!; s++) ...[
            generateSyntheticPrayer(c,
                seed: s,
                prayer: p,
                options: const SyntheticOptions.clean(timeScale: timeScale)),
            generateSyntheticPrayer(c,
                seed: s,
                prayer: p,
                options: SyntheticOptions.random(
                    math.Random(s * 1009 + c.index),
                    timeScale: timeScale),
                name: 'synthetic-${p.name}-${c.name}-s$s-perturbed'),
          ],
      ...generateSyntheticBatch(batch,
          seed: 7777, timeScale: timeScale, prayers: Prayer.values),
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
      expect(r.wrongStarts.single.labelState, itidal);
      expect(r.wrongStarts.single.labelRakah, 1);
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
      expect(late.overruns.single.labelState, ruku);
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
      expect(r.wrongResumes.single.labelState, itidal);
      expect(r.wrongResumes.single.labelRakah, 2);
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

    test('four rak\'ahs: every start scored against its own rak\'ah', () {
      final ok = score(
          ishaLabels(),
          withChanges(const [
            StartRecitation(1900, rakah: 1),
            StopRecitation(10200),
            StartRecitation(21000, rakah: 2),
            StopRecitation(30200),
            StartRecitation(51000, rakah: 3),
            StopRecitation(60200),
            StartRecitation(71000, rakah: 4),
            StopRecitation(80200),
          ]),
          name: 'isha',
          endMs: 100000);
      expect(ok.prayer, Prayer.isha);
      expect(ok.problems, isEmpty);
      expect(ok.eligibleQiyam.map((q) => q.rakah), [1, 2, 3, 4]);
      expect(ok.startLatencyMs, {1: 100, 2: 1000, 3: 1000, 4: 1000});
      expect(ok.rakahCountOk, isTrue);
      expect(ReplaySummary([ok]).startP(3, 50), 1000);

      // Rak'ah 3's recitation in rak'ah 4's qiyam: wrong-time (the wrong
      // rak'ah), and both qiyams count as missed.
      final wrong = score(
          ishaLabels(),
          withChanges(const [
            StartRecitation(72000, rakah: 3),
            StopRecitation(80200),
          ]),
          name: 'isha',
          endMs: 100000);
      expect(wrong.wrongStarts.single.labelState, qiyam);
      expect(wrong.wrongStarts.single.labelRakah, 4);
      expect(wrong.missed.map((q) => q.rakah), [1, 2, 3, 4]);
      // A start in the middle sitting is wrong-time.
      final sitting = score(
          ishaLabels(),
          withChanges(
              const [StartRecitation(45000, rakah: 3), StopRecitation(45100)]),
          name: 'isha',
          endMs: 100000);
      expect(sitting.wrongStarts.single.labelState, middle);
    });

    test(
        'rak\'ah count: the machine\'s rak\'ah at the end of every '
        'labelled sujood', () {
      // A machine one rak'ah behind from the middle sitting on:
      // mismatches at the end of sujood 3 and 4.
      final behind = [
        for (final e in ishaChanges)
          if (e.tMs > 45000)
            StateChanged(e.tMs, from: e.from, to: e.to, rakah: e.rakah - 1)
          else
            e,
      ];
      final r = score(ishaLabels(), behind, name: 'isha', endMs: 100000);
      expect(r.reachedFinal, isTrue);
      expect(r.rakahCountOk, isFalse);
      expect(r.rakahMismatches.map((m) => (m.labelRakah, m.machineRakah)),
          [(3, 2), (4, 3)]);
      expect(r.problems, contains('rak\'ah count off'));
      // Frozen (lost tracking) at a sujood end: not judged there.
      final frozen = score(
          ishaLabels(),
          [
            ...ishaChanges.where((e) => e.tMs < 65000),
            const TrackingLost(66000),
            const TrackingRestored(71000),
            ...ishaChanges.where((e) => e.tMs >= 71000),
          ],
          name: 'isha',
          endMs: 100000);
      // The sujood 3 label ends at 69999, while frozen in itidal 3 (rak'ah
      // 3 anyway): fine either way; nothing reported.
      expect(frozen.rakahMismatches, isEmpty);
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

    test('replays each prayer with a machine for the labels\' prayer', () {
      for (final prayer in Prayer.values) {
        final p = generateSyntheticPrayer(SyntheticCase.normal,
            seed: 1,
            prayer: prayer,
            options: const SyntheticOptions.clean(timeScale: 0.05));
        final r = replay(p.recording, p.labels, name: p.name);
        expect(r.prayer, prayer);
        expect(r.problems, isEmpty, reason: prayer.name);
        expect(r.events.whereType<StartRecitation>().map((e) => e.rakah),
            [for (var k = 1; k <= prayer.rakahCount; k++) k],
            reason: prayer.name);
        expect(
            r.events
                .whereType<StateChanged>()
                .where((e) => e.to == PrayerState.middleSitting),
            hasLength(prayer.hasMiddleSitting ? 1 : 0));
        expect(r.endReason, EndReason.completed);
      }
    });
  });

  test(
      'a final tashahhud the 5 s hold never confirms still ends as done '
      '(synthetic-0213-asr-normal of --batch 300 --seed 9090, before the '
      'hands-first case existed)', () {
    // The options SyntheticOptions.random drew for that prayer.
    const options = SyntheticOptions(
      timeScale: 0.05,
      timingJitterMs: 2.2545646195753193,
      frameSkipRate: 0.027177924922789566,
      pixelNoise: 3.776511298044234,
      confJitter: 0.022174062215894807,
      frameDropoutRate: 0.005253826331550852,
    );
    final p = generateSyntheticPrayer(SyntheticCase.normal,
        seed: 1698651982, prayer: Prayer.asr, options: options);
    final r = replay(p.recording, p.labels, name: p.name);
    expect(r.finalState, PrayerState.done);
    expect(r.endReason, EndReason.completed);
    expect(r.wrongTimeAudio, isFalse);
    expect(r.events.whereType<StartRecitation>().map((e) => e.rakah),
        [1, 2, 3, 4]);
    expect(r.rakahCountOk, isTrue);
    // The machine never confirmed the final sitting: it was filled in when
    // the user got up from sujood.
    final fsAt = r.events
        .whereType<StateChanged>()
        .singleWhere((e) => e.to == PrayerState.finalSitting);
    expect(fsAt.from, PrayerState.sujood);
    expect(r.events.whereType<SessionEnded>().single.tMs, fsAt.tMs);
  });

  test(
      'hands-first descent: the bow on the way down to sujood is no second '
      'ruku, every rak\'ah recites', () {
    for (final prayer in Prayer.values) {
      for (final seed in [1, 2, 3]) {
        for (final options in const [
          SyntheticOptions.clean(timeScale: 0.05),
          SyntheticOptions(timeScale: 0.05),
        ]) {
          final p = generateSyntheticPrayer(SyntheticCase.handsFirstDescent,
              seed: seed, prayer: prayer, options: options);
          final m = SalahStateMachine(prayer: prayer);
          final r = replay(p.recording, p.labels,
              name: p.name,
              machine: m,
              options: const ReplayOptions(keepReadings: true));
          expect(r.problems, isEmpty, reason: p.name);
          expect(m.countUncertain, isFalse, reason: p.name);
          expect(r.events.whereType<StartRecitation>().map((e) => e.rakah),
              [for (var k = 1; k <= prayer.rakahCount; k++) k],
              reason: p.name);
          // The descent really shows a smoothed bow in i'tidal (what used
          // to be taken for a second ruku).
          final changes = r.events.whereType<StateChanged>().toList();
          var state = PrayerState.waiting;
          var ci = 0;
          int? since;
          var longest = 0;
          for (final x in r.readings) {
            while (ci < changes.length && changes[ci].tMs <= x.tMs) {
              state = changes[ci++].to;
            }
            if (state == PrayerState.itidal && x.posture == Posture.bowing) {
              since ??= x.tMs;
              if (x.tMs - since > longest) longest = x.tMs - since;
            } else {
              since = null;
            }
          }
          expect(longest, greaterThanOrEqualTo(500), reason: p.name);
        }
      }
    }
  });

  group('accuracy on synthetic prayers', () {
    late List<ReplayResult> results;
    late ReplaySummary summary;

    /// Everything but [SyntheticCase.missedMiddleSitting], whose rak'ah 3
    /// is silent by design (the middle sitting cannot be confirmed).
    late ReplaySummary ordinary;

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
      ordinary = ReplaySummary([
        for (final r in results)
          if (!r.name.contains('missedMiddleSitting')) r
      ]);
      batch = ReplaySummary(results.sublist(results.length - 100));
    });

    test('dataset size', () {
      // (14 Fajr cases x 2 + 15 cases x (2 + 2 + 1 + 1)) seeds x
      // clean/perturbed + 100 random prayers.
      expect(summary.prayers, (14 * 2 + 15 * 6) * 2 + 100);
      expect(summary.rakahs, greaterThan(900));
      for (final p in Prayer.values) {
        expect(results.where((r) => r.prayer == p), isNotEmpty);
      }
    });

    test('zero wrong-time audio for every prayer', () {
      for (final p in Prayer.values) {
        final s = ReplaySummary([
          for (final r in results)
            if (r.prayer == p) r
        ]);
        expect(s.wrongStarts + s.overruns + s.wrongResumes, 0, reason: p.name);
      }
    });

    test(
        'an unconfirmed middle sitting leaves rak\'ah 3 silent, not '
        'rak\'ah 4', () {
      final m = [
        for (final r in results)
          if (r.name.contains('missedMiddleSitting')) r
      ];
      expect(m, isNotEmpty);
      for (final r in m) {
        expect(r.wrongTimeAudio, isFalse, reason: r.name);
        expect(r.rakahCountOk, isTrue, reason: r.name);
      }
      final missed3 = m.where((r) => r.missed.any((q) => q.rakah == 3)).length;
      expect(missed3, greaterThan(m.length ~/ 2));
      expect(m.where((r) => r.missed.any((q) => q.rakah == 4)).length,
          lessThanOrEqualTo(m.length ~/ 10));
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

    test('missed qiyam at most 1.5% of rak\'ahs (spec 2%)', () {
      // Measured with the harness (all prayers, missedMiddleSitting left
      // out): about 0.5% (matrix 10 seeds and the 520-prayer batch); most
      // misses are a takbir raise lost in a dropout, a few a middle
      // sitting too broken to confirm.
      expect(ordinary.missedRate, lessThanOrEqualTo(0.015));
    });

    test('rak\'ah count right in 99% of prayers', () {
      // Final sitting reached exactly when labelled, and the machine in
      // the labelled rak'ah at the end of every sujood. Measured: 0 of
      // 1380 (matrix) and 0 of 520 (batch).
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

    test('rak\'ahs 2-4 start within 0.8 s of the 0.8 s hold (p90)', () {
      // Spec: at most 1.0 s after the hold. Measured p90 from the qiyam
      // label (middle of the rise) 1.39-1.52 s, i.e. hold + 0.7 s.
      for (final k in [2, 3, 4]) {
        expect(summary.startP(k, 90), lessThanOrEqualTo(800 + 800),
            reason: 'rak\'ah $k');
        expect(summary.startP(k, 50), greaterThanOrEqualTo(800),
            reason: 'rak\'ah $k');
      }
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
