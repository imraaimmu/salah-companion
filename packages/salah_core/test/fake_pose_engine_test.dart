import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

const header = RecordingHeader(
    engine: 'test',
    model: 'test',
    fps: 15,
    orientation: 'portrait',
    side: 'left',
    device: 'test',
    imageW: 480,
    imageH: 640);

PoseFrame frame(int t, {bool person = true}) => PoseFrame(
    tMs: t,
    landmarks: null,
    people: person ? const [[]] : const [],
    imageW: 480,
    imageH: 640);

/// Frames at 0, 66, 132, then a 350 ms gap (heartbeats at 232, 332, 432),
/// a no-person frame at 482 (a frame, not a gap), and 582 (100 ms: none).
final rec = Recording(header: header, frames: [
  frame(0),
  frame(66),
  frame(132),
  frame(482, person: false),
  frame(582),
]);

void main() {
  test('immediate replay: original timestamps plus heartbeats', () async {
    final e = FakePoseEngine(rec);
    final out = await e.start(const CameraConfig()).toList();
    expect(out.map((f) => f.tMs), [0, 66, 132, 232, 332, 432, 482, 582]);
    expect(out.map((f) => f.hasPerson),
        [true, true, true, false, false, false, false, true]);
    expect(out[3].imageW, 480);
    expect(identical(out[6], rec.frames[3]), isTrue);
    expect(e.running, isFalse);
  });

  test('heartbeats can be turned off', () async {
    final out = await FakePoseEngine(rec, heartbeats: false).start().toList();
    expect(out.map((f) => f.tMs), [0, 66, 132, 482, 582]);
  });

  test('the same frames as the replay harness', () async {
    final p = generateSyntheticPrayer(SyntheticCase.missedRuku,
        seed: 3, options: const SyntheticOptions.clean(timeScale: 0.05));
    final out = await FakePoseEngine(p.recording).start().toList();
    final expected = withHeartbeats(p.recording).map((e) => e.frame).toList();
    expect(out.length, expected.length);
    expect(out.map((f) => f.tMs), expected.map((f) => f.tMs));
    // The harness stops at SessionEnded; up to there it fed the same.
    final r = replay(p.recording, p.labels);
    expect(r.frames + r.heartbeats, lessThanOrEqualTo(out.length));
    expect(r.frames + r.heartbeats, greaterThan(out.length * 0.9));
  });

  test('stop ends the stream early', () async {
    final e = FakePoseEngine(rec);
    final got = <int>[];
    final done = e.start().forEach((f) {
      got.add(f.tMs);
      if (got.length == 2) e.stop();
    });
    await done;
    expect(got, [0, 66]);
    expect(e.running, isFalse);
  });

  test('start again restarts from the first frame', () async {
    final e = FakePoseEngine(rec);
    final first = e.start();
    final second = await e.start().toList();
    expect(second.first.tMs, 0);
    expect(await first.toList(), isEmpty);
  });

  test('real time keeps the original spacing (scaled by speed)', () async {
    final e = FakePoseEngine(rec, realTime: true, speed: 2);
    final sw = Stopwatch()..start();
    final arrivals = <int, int>{};
    await e.start().forEach((f) => arrivals[f.tMs] = sw.elapsedMilliseconds);
    expect(arrivals.keys, [0, 66, 132, 232, 332, 432, 482, 582]);
    // 582 ms of sensor time at 2x: about 291 ms, never early.
    for (final MapEntry(key: t, value: at) in arrivals.entries) {
      expect(at, greaterThanOrEqualTo(t ~/ 2 - 1), reason: 'frame $t');
      expect(at, lessThan(t ~/ 2 + 150), reason: 'frame $t');
    }
  });

  test('rejects bad options', () {
    expect(() => FakePoseEngine(rec, speed: 0), throwsArgumentError);
    expect(() => FakePoseEngine(rec, heartbeatMs: 0), throwsArgumentError);
  });
}
