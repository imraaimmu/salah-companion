import 'dart:async';

import 'package:salah_core/salah_core.dart';
import 'package:salah_core/testing.dart';
import 'package:test/test.dart';

const settings = SessionSettings();

class Rig {
  final FakeRecitationPlayer player;
  final FakeRecitationPlanner planner = FakeRecitationPlanner();
  final StreamController<Interruption> interruptions =
      StreamController<Interruption>();
  late final SessionController c;
  final List<SessionStatus> statuses = [];

  Rig({
    Duration opDelay = Duration.zero,
    Stream<PoseFrame>? frames,
    SessionSettings s = settings,
  }) : player = FakeRecitationPlayer(opDelay: opDelay) {
    c = SessionController(player, planner, s, interruptions.stream,
        frames: frames);
    c.status.listen(statuses.add);
  }

  List<PlayerCallKind> get kinds => player.kinds;
}

const play = PlayerCallKind.play;
const pause = PlayerCallKind.pause;
const resume = PlayerCallKind.resume;
const fadeOut = PlayerCallKind.fadeOut;
const stopNow = PlayerCallKind.stopNow;

/// Lets the interruption stream deliver.
Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('events', () {
    test('StartRecitation plays the planner\'s plan for that rak\'ah',
        () async {
      final r = Rig();
      r.c.handle(const StartRecitation(100, rakah: 1));
      expect(r.c.current.reciting, isTrue);
      await r.c.idle;
      expect(r.kinds, [play]);
      expect(r.player.plays.single, same(r.planner.planFor(1, settings)));
      expect(r.planner.requests.first.$1, 1);
      expect(r.player.plays.single.preRoll, const Duration(seconds: 6));
    });

    test('play is not awaited: later events still reach the player', () async {
      final r = Rig();
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const PauseRecitation(10, rakah: 1));
      r.c.handle(const ResumeRecitation(20, rakah: 1));
      r.c.handle(const StopRecitation(30));
      await r.c.idle;
      expect(r.kinds, [play, pause, resume, fadeOut]);
      expect(r.player.calls.every((c) => c.effective), isTrue);
    });

    test('never plays twice per rak\'ah, even if events repeat', () async {
      final r = Rig();
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const StartRecitation(1, rakah: 1));
      r.c.handle(const StopRecitation(2));
      r.c.handle(const StartRecitation(3, rakah: 1));
      r.c.handle(const StartRecitation(4, rakah: 2));
      r.c.handle(const StartRecitation(5, rakah: 2));
      await r.c.idle;
      expect(r.kinds, [play, fadeOut, play]);
      expect(r.player.plays.map((p) => p.clips.last.surah), [93, 94]);
    });

    test('pause and resume only for the open recitation', () async {
      final r = Rig();
      r.c.handle(const PauseRecitation(0, rakah: 1)); // nothing playing
      r.c.handle(const ResumeRecitation(1, rakah: 1)); // not paused
      r.c.handle(const StartRecitation(2, rakah: 1));
      r.c.handle(const ResumeRecitation(3, rakah: 1)); // not paused
      r.c.handle(const PauseRecitation(4, rakah: 2)); // other rak'ah
      r.c.handle(const PauseRecitation(5, rakah: 1));
      expect(r.c.current.paused, isTrue);
      r.c.handle(const PauseRecitation(6, rakah: 1)); // already paused
      r.c.handle(const ResumeRecitation(7, rakah: 2)); // other rak'ah
      r.c.handle(const ResumeRecitation(8, rakah: 1));
      expect(r.c.current.paused, isFalse);
      await r.c.idle;
      expect(r.kinds, [play, pause, resume]);
    });

    test('a stop is final: no resume after it', () async {
      final r = Rig();
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const PauseRecitation(1, rakah: 1));
      r.c.handle(const StopRecitation(2));
      r.c.handle(const ResumeRecitation(3, rakah: 1));
      await r.c.idle;
      expect(r.kinds, [play, pause, fadeOut]);
      expect(r.c.current.reciting, isFalse);
      expect(r.c.current.paused, isFalse);
    });

    test('StopRecitation always fades (cancels a pending pre-roll)', () async {
      final r = Rig();
      r.c.handle(const StopRecitation(0));
      await r.c.idle;
      expect(r.kinds, [fadeOut]);
      expect(r.player.calls.single.fade, const Duration(milliseconds: 300));
    });

    test('player calls are serialized: a fade after a resume waits for it',
        () async {
      final r = Rig(opDelay: const Duration(milliseconds: 30));
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const PauseRecitation(1, rakah: 1));
      r.c.handle(const ResumeRecitation(2, rakah: 1));
      r.c.handle(const StopRecitation(3));
      // Nothing beyond the first call has happened synchronously.
      expect(r.kinds, isEmpty);
      await r.c.idle;
      expect(r.kinds, [play, pause, resume, fadeOut]);
      expect(r.player.overlaps, 0);
      expect(r.player.state, FakePlayerState.idle);
    });

    test('tracking, state and rak\'ah reach the status', () async {
      final r = Rig();
      r.c.handle(const StateChanged(0,
          from: PrayerState.waiting, to: PrayerState.takbir, rakah: 0));
      r.c.handle(const StateChanged(800,
          from: PrayerState.takbir, to: PrayerState.qiyam, rakah: 1));
      expect(r.c.current.state, PrayerState.qiyam);
      expect(r.c.current.rakah, 1);
      r.c.handle(const TrackingLost(900));
      expect(r.c.current.tracking, isFalse);
      r.c.handle(const TrackingRestored(1000));
      expect(r.c.current.tracking, isTrue);
      await pump();
      expect(r.statuses.map((s) => s.state), [
        PrayerState.takbir,
        PrayerState.qiyam,
        PrayerState.qiyam,
        PrayerState.qiyam
      ]);
      expect(r.statuses.map((s) => s.tracking), [true, true, false, true]);
    });

    test('no start while tracking is lost; that rak\'ah stays silent',
        () async {
      final r = Rig();
      r.c.handle(const TrackingLost(0));
      r.c.handle(const StartRecitation(1, rakah: 1));
      r.c.handle(const TrackingRestored(2));
      r.c.handle(const StartRecitation(3, rakah: 1));
      r.c.handle(const StartRecitation(4, rakah: 2));
      await r.c.idle;
      expect(r.kinds, [play]);
      expect(r.player.plays.single, same(r.planner.planFor(2, settings)));
    });

    test('four rak\'ahs: each plays once, rak\'ahs 3 and 4 Al-Fatiha only',
        () async {
      final r = Rig();
      for (var k = 1; k <= 4; k++) {
        r.c.handle(StartRecitation(k * 1000, rakah: k));
        r.c.handle(StartRecitation(k * 1000 + 10, rakah: k)); // repeat: ignored
        r.c.handle(StopRecitation(k * 1000 + 500));
      }
      await r.c.idle;
      expect(r.player.plays, hasLength(4));
      for (var k = 1; k <= 4; k++) {
        expect(r.player.plays[k - 1], same(r.planner.planFor(k, settings)));
      }
      expect(r.player.plays[2].clips.map((c) => c.surah).toSet(), {1});
      expect(r.player.plays[3].clips.map((c) => c.surah).toSet(), {1});
      expect(r.player.plays[1].clips.map((c) => c.surah).toSet(), hasLength(2));
    });

    test('TrackingLost fades an open recitation (defensive)', () async {
      final r = Rig();
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const TrackingLost(1));
      r.c.handle(const TrackingRestored(2));
      r.c.handle(const ResumeRecitation(3, rakah: 1));
      await r.c.idle;
      expect(r.kinds, [play, fadeOut]);
    });

    test('SessionEnded fades out, ends, and ignores later events', () async {
      final r = Rig();
      final done = r.c.status.toList();
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const SessionEnded(1, reason: EndReason.timeout));
      r.c.handle(const StartRecitation(2, rakah: 2));
      r.interruptions.add(Interruption.phoneCall);
      await pump();
      await r.c.idle;
      expect(r.kinds, [play, fadeOut]);
      expect(r.c.current.ended, EndReason.timeout);
      expect(r.c.current.reciting, isFalse);
      expect((await done).last.ended, EndReason.timeout);
    });

    test('a recitation that finishes on its own clears reciting', () async {
      final r = Rig();
      r.c.handle(const StartRecitation(0, rakah: 1));
      await r.c.idle;
      r.player.finish();
      await pump();
      expect(r.c.current.reciting, isFalse);
      r.c.handle(const PauseRecitation(1, rakah: 1));
      await r.c.idle;
      expect(r.kinds, [play]);
    });

    test('a planner error leaves the rak\'ah silent', () async {
      final player = FakeRecitationPlayer();
      final c = SessionController(
          player, _ThrowingPlanner(), settings, const Stream.empty());
      c.handle(const StartRecitation(0, rakah: 1));
      await c.idle;
      expect(player.calls, isEmpty);
      expect(c.errors.single, isA<StateError>());
      expect(c.current.reciting, isFalse);
    });

    test('run applies a stream in order and returns at the end', () async {
      final r = Rig();
      await r.c.run(Stream.fromIterable(const [
        StartRecitation(0, rakah: 1),
        StopRecitation(1),
        StartRecitation(2, rakah: 2),
        SessionEnded(3, reason: EndReason.completed),
        StartRecitation(4, rakah: 2),
      ]));
      expect(r.kinds, [play, fadeOut, play, fadeOut]);
      expect(r.c.isOver, isTrue);
    });
  });

  group('interruptions', () {
    for (final (i, reason) in [
      (Interruption.phoneCall, EndReason.cancelled),
      (Interruption.appBackgrounded, EndReason.cancelled),
      (Interruption.audioFocusLost, EndReason.cancelled),
      (Interruption.userCancelled, EndReason.cancelled),
      (Interruption.cameraUnavailable, EndReason.cameraLost),
    ]) {
      test('${i.name} stops now and ends the session (${reason.name})',
          () async {
        final r = Rig();
        r.c.handle(const StartRecitation(0, rakah: 1));
        r.interruptions.add(i);
        await pump();
        r.c.handle(const StartRecitation(5, rakah: 2));
        await r.c.idle;
        expect(r.kinds, [play, stopNow]);
        expect(r.c.current.ended, reason);
        expect(r.c.current.interruption, i);
        expect(r.c.current.reciting, isFalse);
        expect(r.c.settingsAfterSession().autoIndex, 0);
      });
    }

    test('headphones unplugged: stop now, keep the session, no more audio',
        () async {
      final r = Rig();
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const PauseRecitation(1, rakah: 1));
      await r.c.idle;
      r.c.interrupt(Interruption.headphonesUnplugged);
      r.c.handle(const ResumeRecitation(2, rakah: 1));
      r.c.handle(const StartRecitation(3, rakah: 2));
      r.c.handle(const StateChanged(4,
          from: PrayerState.sujood, to: PrayerState.qiyam, rakah: 2));
      await r.c.idle;
      expect(r.kinds, [play, pause, stopNow]);
      expect(r.c.isOver, isFalse);
      expect(r.c.current.state, PrayerState.qiyam);
      expect(r.c.current.interruption, Interruption.headphonesUnplugged);
      r.c.handle(const SessionEnded(5, reason: EndReason.completed));
      expect(r.c.current.ended, EndReason.completed);
    });

    test('an interruption drops queued calls that have not started', () async {
      final r = Rig(opDelay: const Duration(milliseconds: 30));
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const PauseRecitation(1, rakah: 1));
      r.c.handle(const ResumeRecitation(2, rakah: 1));
      await pump(); // play and pause have started, resume is queued
      r.c.interrupt(Interruption.phoneCall);
      await r.c.idle;
      expect(r.kinds, [play, pause, stopNow]);
      // The stop deliberately overlaps the running pause.
      expect(r.player.overlaps, 1);
    });

    test('an interruption stops at once, not behind a running call', () async {
      final r = Rig(opDelay: const Duration(milliseconds: 400));
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const PauseRecitation(1, rakah: 1));
      await pump();
      await pump();
      r.c.handle(const ResumeRecitation(2, rakah: 1));
      await Future<void>.delayed(const Duration(milliseconds: 450));
      // The resume (a 400 ms ramp) is running now.
      expect(r.kinds, [play, pause, resume]);
      expect(r.player.isPlaying, isTrue);
      final sw = Stopwatch()..start();
      r.c.interrupt(Interruption.userCancelled);
      // stopNow was called synchronously: the audio is already stopped.
      expect(r.kinds, [play, pause, resume, stopNow]);
      expect(r.player.state, FakePlayerState.idle);
      expect(r.c.isOver, isTrue);
      // A later call still waits for the running resume and the stop.
      var idleDone = false;
      final idle = r.c.idle.then((_) => idleDone = true);
      await pump();
      expect(idleDone, isFalse);
      await idle;
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(300));
      expect(r.c.errors, isEmpty);
    });

    test('a throwing stopNow is recorded, the session still ends', () async {
      final r = Rig();
      r.player.dispose(); // every call now throws StateError
      r.c.interrupt(Interruption.appBackgrounded);
      await r.c.idle;
      expect(r.c.isOver, isTrue);
      expect(r.c.errors.single, isA<StateError>());
    });

    test('an interruption before the queued play runs drops the play',
        () async {
      final r = Rig();
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.interrupt(Interruption.appBackgrounded);
      await r.c.idle;
      expect(r.kinds, [stopNow]);
    });

    test('low frame rate: stop now, tracking lost, no start or resume',
        () async {
      final r = Rig();
      r.c.handle(const StartRecitation(0, rakah: 1));
      r.c.handle(const PauseRecitation(1, rakah: 1));
      await r.c.idle;
      r.c.interrupt(Interruption.lowFrameRate);
      expect(r.c.current.tracking, isFalse);
      r.c.handle(const ResumeRecitation(2, rakah: 1));
      r.c.handle(const StartRecitation(3, rakah: 2));
      r.c.handle(const TrackingRestored(4)); // the machine never lost it
      expect(r.c.current.tracking, isFalse);
      r.c.frameRateRecovered();
      expect(r.c.current.tracking, isTrue);
      r.c.handle(const ResumeRecitation(5, rakah: 1));
      await r.c.idle;
      expect(r.kinds, [play, pause, stopNow]);
      expect(r.c.isOver, isFalse);
    });

    test('the built-in frame-rate monitor reports low fps from frames',
        () async {
      final frames = StreamController<PoseFrame>();
      final r = Rig(frames: frames.stream);
      r.c.handle(const StartRecitation(0, rakah: 1));
      // 15 fps for 3 s, then 5 fps.
      for (var t = 0; t < 3000; t += 66) {
        frames.add(_frame(t));
      }
      for (var t = 3000; t < 12000; t += 200) {
        frames.add(_frame(t));
      }
      await pump();
      await r.c.idle;
      expect(r.kinds, [play, stopNow]);
      expect(r.c.current.tracking, isFalse);
      expect(r.c.current.interruption, Interruption.lowFrameRate);
      // Back to 15 fps for 6 s: recovered.
      for (var t = 12000; t < 18000; t += 66) {
        frames.add(_frame(t));
      }
      await pump();
      expect(r.c.current.tracking, isTrue);
      await frames.close();
    });
  });

  group('settingsAfterSession', () {
    final day = DateTime(2026, 10, 20, 13, 5);
    test('changes nothing unless the session completed', () {
      for (final reason in [
        EndReason.timeout,
        EndReason.cancelled,
        EndReason.cameraLost,
      ]) {
        const s = SessionSettings(
            autoIndex: 3, autoPairDate: '2026-10-19', ayahGapMs: 900);
        final r = Rig(s: s);
        r.c.handle(SessionEnded(0, reason: reason));
        final after = r.c.settingsAfterSession(day);
        expect(after.autoIndex, 3, reason: reason.name);
        expect(after.autoPairDate, '2026-10-19', reason: reason.name);
      }
    });

    test('a completed prayer on a new day advances the Auto pair once', () {
      final r = Rig(
          s: const SessionSettings(
              autoIndex: 3, autoPairDate: '2026-10-19', ayahGapMs: 900));
      expect(r.c.settingsAfterSession(day).autoIndex, 3);
      r.c.handle(const SessionEnded(0, reason: EndReason.completed));
      final after = r.c.settingsAfterSession(day);
      expect(after.autoIndex, 4);
      expect(after.autoPairDate, '2026-10-20');
      expect(after.ayahGapMs, 900);
    });

    test('later prayers of the same day keep the pair', () {
      final r = Rig(
          s: const SessionSettings(autoIndex: 4, autoPairDate: '2026-10-20'));
      r.c.handle(const SessionEnded(0, reason: EndReason.completed));
      final after = r.c.settingsAfterSession(day);
      expect(after.autoIndex, 4);
      expect(after.autoPairDate, '2026-10-20');
    });

    test('the first completed prayer ever keeps the pair and dates it', () {
      final r = Rig(s: const SessionSettings(autoIndex: 3));
      r.c.handle(const SessionEnded(0, reason: EndReason.completed));
      final after = r.c.settingsAfterSession(day);
      expect(after.autoIndex, 3);
      expect(after.autoPairDate, '2026-10-20');
    });
  });

  group('FrameRateMonitor', () {
    List<FrameRateChange?> feed(FrameRateMonitor m, Iterable<int> times) =>
        [for (final t in times) m.addCameraFrame(t)];

    test('15 fps and a steady 10 fps are fine', () {
      final m = FrameRateMonitor();
      expect(
          feed(m, [for (var t = 0; t < 60000; t += 66) t]).nonNulls, isEmpty);
      final m10 = FrameRateMonitor();
      expect(feed(m10, [for (var t = 0; t < 60000; t += 100) t]).nonNulls,
          isEmpty);
      expect(m10.framesInWindow, 50);
    });

    test('9 fps is low once 5 s have passed', () {
      final m = FrameRateMonitor();
      final times = [for (var t = 0; t < 20000; t += 111) t];
      final changes = feed(m, times);
      final i = changes.indexOf(FrameRateChange.low);
      expect(times[i], greaterThanOrEqualTo(5000));
      expect(times[i], lessThan(5200));
      expect(changes.where((c) => c != null), [FrameRateChange.low]);
      expect(m.low, isTrue);
    });

    test('a drop from 15 to 5 fps is low within 5 s, then recovers', () {
      final m = FrameRateMonitor();
      feed(m, [for (var t = 0; t < 10000; t += 66) t]);
      final slow = [for (var t = 10000; t < 20000; t += 200) t];
      final c = feed(m, slow);
      final lowAt = slow[c.indexOf(FrameRateChange.low)];
      expect(lowAt, greaterThan(10000));
      expect(lowAt, lessThanOrEqualTo(15000));
      final fast = [for (var t = 20000; t < 30000; t += 66) t];
      final c2 = feed(m, fast);
      final backAt = fast[c2.indexOf(FrameRateChange.recovered)];
      expect(backAt, lessThanOrEqualTo(25000));
      expect(m.low, isFalse);
    });

    test('heartbeats move the clock but are not frames', () {
      final m = FrameRateMonitor();
      feed(m, [for (var t = 0; t <= 3000; t += 66) t]);
      // Camera stalls: only heartbeats from the last frame (2970).
      FrameRateChange? change;
      var t = 2970 + 100;
      for (; t < 20000 && change == null; t += 100) {
        change = m.add(PoseFrame.heartbeat(t, imageW: 480, imageH: 640));
      }
      expect(change, FrameRateChange.low);
      expect(m.framesInWindow, lessThan(50));
    });

    test('add tells camera frames from heartbeats by the heartbeat rule', () {
      final m = FrameRateMonitor();
      m.add(_frame(0));
      m.add(const PoseFrame.heartbeat(100));
      expect(m.framesInWindow, 1);
      m.add(_frame(150)); // a person: a frame
      m.add(const PoseFrame(tMs: 216, landmarks: null, imageW: 1, imageH: 1));
      expect(m.framesInWindow, 3); // no person, off the heartbeat grid
      m.add(const PoseFrame(tMs: 316, landmarks: null, imageW: 1, imageH: 1));
      expect(m.framesInWindow, 3); // on the grid: taken for a heartbeat
    });

    test('watch emits lowFrameRate per episode', () async {
      final frames = [
        for (var t = 0; t < 8000; t += 200) _frame(t),
        for (var t = 8000; t < 16000; t += 66) _frame(t),
        for (var t = 16000; t < 24000; t += 250) _frame(t),
      ];
      final out =
          await FrameRateMonitor().watch(Stream.fromIterable(frames)).toList();
      expect(out, [Interruption.lowFrameRate, Interruption.lowFrameRate]);
    });

    test('rejects bad settings', () {
      expect(() => FrameRateMonitor(minFps: 0), throwsArgumentError);
      expect(() => FrameRateMonitor(windowMs: 0), throwsArgumentError);
      expect(() => FrameRateMonitor(heartbeatMs: 0), throwsArgumentError);
    });
  });
}

PoseFrame _frame(int t) => PoseFrame(
    tMs: t, landmarks: const [], people: const [[]], imageW: 480, imageH: 640);

class _ThrowingPlanner implements RecitationPlanner {
  @override
  RecitationPlan planFor(int rakah, SessionSettings settings) =>
      throw StateError('no content');

  @override
  (int, int) surahsFor(SessionSettings settings) => (93, 94);
}
