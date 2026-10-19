import 'package:salah_core/salah_core.dart';
import 'package:salah_core/testing.dart';
import 'package:test/test.dart';

void main() {
  var now = Duration.zero;
  late FakeRecitationPlayer p;
  final planner =
      FakeRecitationPlanner(clipDuration: const Duration(seconds: 2));
  // rak'ah 1: pre-roll 6000, clips of 2000 with 1500 gaps (+1500 after 1:7).
  final plan = planner.planFor(1, const SessionSettings());

  setUp(() {
    now = Duration.zero;
    p = FakeRecitationPlayer(clock: () => now);
  });

  test('records calls with timestamps and follows the contract', () async {
    final done = p.play(plan);
    var finished = false;
    done.then((_) => finished = true);
    now = const Duration(milliseconds: 7000); // inside 1:1 [6000, 8000)
    await p.pause();
    expect(p.isPaused, isTrue);
    expect(p.position, const Duration(milliseconds: 6000));
    await p.pause(); // already paused: no-op
    now = const Duration(milliseconds: 20000);
    await p.resume();
    expect(p.isPlaying, isTrue);
    now = const Duration(milliseconds: 20500);
    expect(p.position, const Duration(milliseconds: 6500));
    await p.fadeOut();
    await Future<void>.delayed(Duration.zero);
    expect(finished, isTrue);
    await p.resume(); // not paused after fadeOut: no-op
    expect(p.kinds, [
      PlayerCallKind.play,
      PlayerCallKind.pause,
      PlayerCallKind.pause,
      PlayerCallKind.resume,
      PlayerCallKind.fadeOut,
      PlayerCallKind.resume,
    ]);
    expect(p.calls.map((c) => c.effective),
        [true, true, false, true, true, false]);
    expect(p.calls.map((c) => c.at.inMilliseconds),
        [0, 7000, 7000, 20000, 20500, 20500]);
    expect(p.plays.single, same(plan));
    expect(p.state, FakePlayerState.idle);
  });

  test('pause in a gap keeps the paused point', () async {
    p.play(plan);
    now = const Duration(milliseconds: 8700); // gap after 1:1
    await p.pause();
    expect(p.position, const Duration(milliseconds: 8700));
  });

  test('stopNow, finish and a new play end the recitation', () async {
    final a = p.play(plan);
    final b = p.play(plan);
    await a; // ended by the second play
    p.finish();
    await b;
    final c = p.play(plan);
    await p.stopNow();
    await c;
    expect(p.currentPlan, isNull);
  });

  test('counts overlapping calls', () async {
    p.opDelay = const Duration(milliseconds: 20);
    p.play(plan);
    final f1 = p.pause();
    final f2 = p.resume(); // while pause is still fading
    await Future.wait([f1, f2]);
    expect(p.overlaps, 1);
    await p.fadeOut();
    expect(p.overlaps, 1);
  });

  test('dispose ends playback; later calls throw', () async {
    final f = p.play(plan);
    p.dispose();
    await f;
    expect(p.disposed, isTrue);
    expect(() => p.play(plan), throwsStateError);
    p.dispose(); // idempotent
    expect(p.callsOf(PlayerCallKind.dispose), hasLength(1));
  });

  test('the fake planner follows the settings', () {
    const s = SessionSettings(
        autoPairs: false,
        surahRakah1: 112,
        surahRakah2: 113,
        openingDuaMs: 18000,
        rakah2PreRollMs: 1500,
        ayahGapMs: 0,
        ameenGapMs: 1500);
    final p1 = planner.planFor(1, s), p2 = planner.planFor(2, s);
    expect(p1.clips.first.surah, 1);
    expect(p1.clips.last.surah, 112);
    expect(p2.clips.last.surah, 113);
    expect(p1.preRoll, const Duration(seconds: 18));
    expect(p2.preRoll, const Duration(milliseconds: 1500));
    expect(p1.gapAfterAyah, Duration.zero);
    expect(planner.surahsFor(const SessionSettings(autoIndex: 4)), (102, 103));
    expect(planner.planFor(1, s), same(p1));
    expect(() => planner.planFor(3, s), throwsArgumentError);
  });
}
