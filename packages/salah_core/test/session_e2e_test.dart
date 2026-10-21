/// End to end: synthetic prayer -> FakePoseEngine -> classifier -> smoother
/// -> state machine -> SessionController -> FakeRecitationPlayer, checked
/// against the ground-truth labels, for every prayer.
library;

import 'dart:math' as math;

import 'package:salah_core/salah_core.dart';
import 'package:salah_core/testing.dart';
import 'package:test/test.dart';

const settings = SessionSettings(autoIndex: 1); // pair (102, 103)

class Run {
  final SyntheticPrayer prayer;
  final List<PrayerEvent> events;
  final FakeRecitationPlayer player;
  final FakeRecitationPlanner planner;
  final SessionController controller;
  Run(this.prayer, this.events, this.player, this.planner, this.controller);
}

Future<Run> runSession(SyntheticPrayer p) async {
  var now = 0;
  final player = FakeRecitationPlayer(clock: () => Duration(milliseconds: now));
  final planner = FakeRecitationPlanner();
  final controller =
      SessionController(player, planner, settings, const Stream.empty());
  final classifier = RuleBasedClassifier();
  final smoother = MajoritySmoother();
  final machine = SalahStateMachine(prayer: p.prayer);
  final events = <PrayerEvent>[];
  final engine = FakePoseEngine(p.recording);
  await for (final f in engine.start(const CameraConfig())) {
    now = f.tMs;
    final out = machine.add(smoother.add(classifier.classify(f)));
    for (final e in out) {
      controller.handle(e);
    }
    events.addAll(out);
    // Let the player calls for this frame run at this frame's time.
    if (out.isNotEmpty) await controller.idle;
    if (machine.ended) break;
  }
  await engine.stop();
  await controller.idle;
  return Run(p, events, player, planner, controller);
}

/// True when [t] is inside a `qiyam{rakah}` label run, or (rak'ah 1) in the
/// labelled takbir standing directly before one: the replay harness's
/// "early start" (see replay.dart).
bool inQiyam(LabelSet labels, int rakah, int t) {
  final runs = qiyamRuns(labels);
  if (runs.any((q) => q.rakah == rakah && q.contains(t))) return true;
  if (rakah != 1) return false;
  final iv = labels.intervalAt(t);
  final next = runs.where((q) => q.startMs > t).firstOrNull;
  return iv != null &&
      iv.state == PrayerState.takbir &&
      next != null &&
      next.rakah == 1 &&
      next.startMs == iv.endMs;
}

void check(Run r) {
  final name = r.prayer.name;
  final calls = r.player.calls;
  final labels = r.prayer.labels;

  // The events are exactly what the replay harness produces: the fake
  // engine feeds the same frames and heartbeats.
  expect(r.events, replay(r.prayer.recording, labels).events, reason: name);

  // play exactly once per StartRecitation, at most once per rak'ah, with
  // the planner's plan for that rak'ah.
  final starts = r.events.whereType<StartRecitation>().toList();
  expect(starts.map((s) => s.rakah).toSet().length, starts.length,
      reason: name);
  final plays = r.player.callsOf(PlayerCallKind.play).toList();
  expect(plays.length, starts.length, reason: '$name plays');
  for (var i = 0; i < plays.length; i++) {
    final rakah = starts[i].rakah;
    expect(plays[i].at.inMilliseconds, starts[i].tMs, reason: name);
    expect(plays[i].plan, same(r.planner.planFor(rakah, settings)),
        reason: name);
    // Rak'ahs 1 and 2: Al-Fatiha + the pair's surah; 3 and 4 Al-Fatiha
    // only.
    expect(plays[i].plan!.clips.last.surah, [102, 103, 1, 1][rakah - 1]);
    // Never outside qiyam.
    expect(inQiyam(labels, rakah, plays[i].at.inMilliseconds), isTrue,
        reason: '$name: play rak\'ah $rakah at ${plays[i].at}');
  }

  // Resumes only in the same rak'ah's qiyam.
  for (final e in r.events.whereType<ResumeRecitation>()) {
    expect(inQiyam(labels, e.rakah, e.tMs), isTrue, reason: '$name $e');
  }
  final resumes = calls.where((c) => c.kind == PlayerCallKind.resume);
  expect(resumes.length, r.events.whereType<ResumeRecitation>().length,
      reason: name);

  // A fade at every StopRecitation and SessionEnded, at that moment.
  for (final e in r.events) {
    if (e is StopRecitation || e is SessionEnded) {
      expect(
          calls.any((c) =>
              c.kind == PlayerCallKind.fadeOut && c.at.inMilliseconds == e.tMs),
          isTrue,
          reason: '$name: fade at $e');
    }
  }

  // Every recitation that played was ended by a fade (or is still open
  // only if the recording ran out first).
  for (final p in plays) {
    final ended = calls
        .any((c) => c.kind == PlayerCallKind.fadeOut && c.at >= p.at && c != p);
    expect(ended || r.player.isPlaying || r.player.isPaused, isTrue,
        reason: name);
  }

  // Audible time is inside qiyam: replay the call log and check each
  // stretch from play/resume to pause/fade with the harness's grace.
  final graceMs = defaultGraceMs;
  int? from;
  int? rakah;
  var startIdx = 0;
  for (final c in calls) {
    switch (c.kind) {
      case PlayerCallKind.play:
        from = c.at.inMilliseconds;
        rakah = starts[startIdx++].rakah;
      case PlayerCallKind.resume when c.effective:
        from = c.at.inMilliseconds;
      case PlayerCallKind.pause ||
              PlayerCallKind.fadeOut ||
              PlayerCallKind.stopNow
          when from != null:
        final until = c.at.inMilliseconds;
        final run = qiyamRuns(labels).where((q) =>
            q.rakah == rakah && q.endMs > from! && q.startMs <= until + 1000);
        // Some qiyam{rakah} run covers [from, until - grace].
        expect(
            run.any((q) =>
                (q.startMs <= from! || inQiyam(labels, rakah!, from)) &&
                until - graceMs <= q.endMs),
            isTrue,
            reason: '$name: audible $from-$until ms, rak\'ah $rakah');
        from = null;
      default:
        break;
    }
  }

  // Calls are serialized.
  expect(r.player.overlaps, 0, reason: name);
}

void main() {
  group('clean synthetic prayers', () {
    for (final prayer in Prayer.values) {
      // Dhuhr and Asr script like Isha: the normal prayer is enough.
      final cases = prayer == Prayer.dhuhr || prayer == Prayer.asr
          ? [SyntheticCase.normal]
          : SyntheticCase.forPrayer(prayer);
      for (final c in cases) {
        test('${prayer.name} ${c.name}', () async {
          final p = generateSyntheticPrayer(c,
              seed: 1,
              prayer: prayer,
              options: const SyntheticOptions.clean(timeScale: 0.05));
          final r = await runSession(p);
          check(r);
          final hasTakbir = p.labels.takbirTimesMs.isNotEmpty;
          final rakahs = [
            for (final s in r.events.whereType<StartRecitation>()) s.rakah
          ];
          // Clean prayers: rak'ah 1 recited when the takbir was made, every
          // later rak'ah always, except rak'ah 3 after a middle sitting the
          // camera mostly missed (silent by design).
          final n = prayer.rakahCount;
          expect(
              rakahs,
              [
                for (var k = hasTakbir ? 1 : 2; k <= n; k++)
                  if (!(k == 3 && c == SyntheticCase.missedMiddleSitting)) k
              ],
              reason: p.name);
          expect(r.controller.current.ended, EndReason.completed,
              reason: p.name);
          // First completed prayer ever: today's pair is kept and dated.
          final after =
              r.controller.settingsAfterSession(DateTime(2026, 10, 20, 5));
          expect(after.autoIndex, 1);
          expect(after.autoPairDate, '2026-10-20');
        });
      }
    }
  });

  test('perturbed synthetic prayers', () async {
    for (final prayer in [Prayer.fajr, Prayer.maghrib, Prayer.isha]) {
      for (final c in SyntheticCase.forPrayer(prayer)) {
        final seeds = prayer == Prayer.fajr ? 2 : 1;
        for (var s = 1; s <= seeds; s++) {
          final p = generateSyntheticPrayer(c,
              seed: s,
              prayer: prayer,
              options: SyntheticOptions.random(math.Random(s * 1009 + c.index),
                  timeScale: 0.05),
              name: 'synthetic-${prayer.name}-${c.name}-s$s-perturbed');
          check(await runSession(p));
        }
      }
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a phone call mid-recitation stops at once and ends the session',
      () async {
    final p = generateSyntheticPrayer(SyntheticCase.normal,
        seed: 2, options: const SyntheticOptions.clean(timeScale: 0.05));
    var now = 0;
    final player =
        FakeRecitationPlayer(clock: () => Duration(milliseconds: now));
    final c = SessionController(
        player, FakeRecitationPlanner(), settings, const Stream.empty());
    final classifier = RuleBasedClassifier();
    final smoother = MajoritySmoother();
    final machine = SalahStateMachine();
    int? callAt;
    for (final (frame: f, heartbeat: _) in withHeartbeats(p.recording)) {
      now = f.tMs;
      for (final e in machine.add(smoother.add(classifier.classify(f)))) {
        c.handle(e);
        if (e is StartRecitation) callAt = f.tMs + 1000;
      }
      await c.idle;
      if (callAt != null && f.tMs >= callAt) {
        c.interrupt(Interruption.phoneCall);
        await c.idle;
        callAt = null;
      }
      if (c.isOver) break;
    }
    expect(player.kinds, [PlayerCallKind.play, PlayerCallKind.stopNow]);
    expect(c.current.ended, EndReason.cancelled);
    expect(c.settingsAfterSession().autoIndex, settings.autoIndex);
  });
}
