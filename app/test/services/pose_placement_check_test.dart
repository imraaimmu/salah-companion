import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/pose/pose_wire.dart';
import 'package:salah_companion/src/services/fakes.dart';
import 'package:salah_companion/src/services/pose_placement_check.dart';
import 'package:salah_companion/src/services/seams.dart';
import 'package:salah_core/salah_core.dart';

/// Says "standing" for every frame with a person.
class StandingClassifier implements PostureClassifier {
  @override
  PostureReading classify(PoseFrame f) => f.hasPerson
      ? PostureReading(tMs: f.tMs, posture: Posture.standing, confidence: 1)
      : PostureReading.unknown(f.tMs);

  @override
  void reset() {}
}

/// The demo skeleton (facing right, toes at x ~ 268), shifted by [dx].
List<Landmark> person({double dx = 0, double dy = 0, double conf = 0.9}) => [
  for (final l in standingSkeleton(conf: conf))
    Landmark(l.x + dx, l.y + dy, l.z, l.conf),
];

/// The demo skeleton scaled by [k] about the floor point under its feet:
/// what a user 2-3 m away fills in a portrait frame (about half its height).
List<Landmark> farPerson({double k = 0.7, double dx = 0}) => [
  for (final l in standingSkeleton())
    Landmark(240 + (l.x - 240) * k + dx, 564 + (l.y - 564) * k, l.z, l.conf),
];

PoseFrame frame(int t, List<Landmark>? p) =>
    PoseFrame(tMs: t, landmarks: p, people: [?p], imageW: 480, imageH: 640);

/// Feeds [ms] of frames at [fps] from [t0]; returns the last state.
PlacementState feed(
  PlacementEvaluator e,
  List<Landmark>? p, {
  int t0 = 0,
  int ms = 3500,
  double fps = 15,
}) {
  var s = const PlacementState();
  for (var i = 0; t0 + i * 1000 / fps <= t0 + ms; i++) {
    s = e.add(frame(t0 + (i * 1000 / fps).round(), p));
  }
  return s;
}

/// Standing, except every 10th frame reads as unknown (a flicker).
class _FlickerClassifier implements PostureClassifier {
  int _n = 0;
  @override
  PostureReading classify(PoseFrame f) => (_n++ % 10 == 9 || !f.hasPerson)
      ? PostureReading.unknown(f.tMs)
      : PostureReading(tMs: f.tMs, posture: Posture.standing, confidence: 1);

  @override
  void reset() => _n = 0;
}

void main() {
  PlacementEvaluator ev() =>
      PlacementEvaluator(classifier: StandingClassifier());

  test('all four checks pass for a well-placed user', () {
    // Shifted to the left edge, facing right: lots of floor in front.
    final s = feed(ev(), person(dx: -215));
    expect(s.bodyVisible, isTrue);
    expect(s.confidenceOk, isTrue);
    expect(s.fpsOk, isTrue);
    expect(s.floorSpaceOk, isTrue);
    expect(s.allPass, isTrue);
    expect(s.message, isNull);
    expect(s.skeleton, hasLength(LandmarkIndex.count));
  });

  test('confidence and fps need 3 s', () {
    final s = feed(ev(), person(dx: -215), ms: 2500);
    expect(s.bodyVisible, isTrue);
    expect(s.confidenceOk, isFalse);
    expect(s.fpsOk, isFalse);
    expect(s.floorSpaceOk, isTrue);
  });

  test('low landmark confidence fails and says move back', () {
    final s = feed(ev(), person(dx: -215, conf: 0.6));
    expect(s.bodyVisible, isTrue);
    expect(s.confidenceOk, isFalse);
    expect(s.message, 'Move the phone back');
  });

  test('feet below the frame: not visible, move back', () {
    final s = feed(ev(), person(dx: -215, dy: 120));
    expect(s.bodyVisible, isFalse);
    expect(s.message, 'Move the phone back');
  });

  test('a user standing in the middle of the frame has room for sujood', () {
    // Before the fix this failed: it demanded 0.88 x height of floor, which a
    // portrait frame only shows when the user stands at the very edge.
    final s = feed(ev(), farPerson());
    expect(s.floorSpaceOk, isTrue);
    expect(s.allPass, isTrue);
  });

  test('even a user close to the phone passes with 0.2 x height in front', () {
    expect(feed(ev(), person()).floorSpaceOk, isTrue);
  });

  test('no floor in front: user near the front edge fails', () {
    final s = feed(ev(), person(dx: 150));
    expect(s.floorSpaceOk, isFalse);
    expect(s.message, 'Step back a little so sujood fits in view');
  });

  test('facing the other way needs the space on the other side', () {
    // Mirror the skeleton: facing left, standing at the right edge.
    final mirrored = [
      for (final l in person(dx: -215)) Landmark(480 - l.x, l.y, l.z, l.conf),
    ];
    expect(feed(ev(), mirrored).floorSpaceOk, isTrue);
    final wrongEdge = [
      for (final l in person(dx: 150)) Landmark(480 - l.x, l.y, l.z, l.conf),
    ];
    expect(feed(ev(), wrongEdge).floorSpaceOk, isFalse);
  });

  test('facing the camera says to turn sideways', () {
    // Shoulders and hips spread wide, as seen from the front.
    final p = [...farPerson()];
    final sh = p[LandmarkIndex.leftShoulder];
    final hip = p[LandmarkIndex.leftHip];
    p[LandmarkIndex.leftShoulder] = Landmark(sh.x - 60, sh.y, 0, sh.conf);
    p[LandmarkIndex.rightShoulder] = Landmark(sh.x + 60, sh.y, 0, sh.conf);
    p[LandmarkIndex.leftHip] = Landmark(hip.x - 40, hip.y, 0, hip.conf);
    p[LandmarkIndex.rightHip] = Landmark(hip.x + 40, hip.y, 0, hip.conf);
    final s = feed(ev(), p);
    expect(s.allPass, isFalse);
    expect(
      s.message,
      'Turn sideways: the phone should be at your left or right',
    );
  });

  test('noisy foot points cannot flip the facing direction', () {
    // Heel and toe swapped (a common MediaPipe glitch) on every frame: the
    // nose and ear still say "facing right", so the space is measured in
    // front, not behind.
    final p = farPerson();
    final glitched = [...p];
    glitched[LandmarkIndex.leftHeel] = p[LandmarkIndex.leftFootIndex];
    glitched[LandmarkIndex.leftFootIndex] = p[LandmarkIndex.leftHeel];
    glitched[LandmarkIndex.rightHeel] = p[LandmarkIndex.rightFootIndex];
    glitched[LandmarkIndex.rightFootIndex] = p[LandmarkIndex.rightHeel];
    expect(feed(ev(), glitched).floorSpaceOk, isTrue);
  });

  test('one non-standing frame does not drop the space check', () {
    final e = PlacementEvaluator(classifier: _FlickerClassifier());
    final s = feed(e, farPerson());
    expect(s.floorSpaceOk, isTrue);
  });

  test('12 fps fails the frame-rate check, 15 fps with one drop passes', () {
    final slow = feed(ev(), person(dx: -215), fps: 12);
    expect(slow.fpsOk, isFalse);
    expect(slow.message, 'Turn on a light');

    final e = ev();
    var s = const PlacementState();
    var n = 0;
    for (var t = 0.0; t <= 4000; t += 1000 / 15) {
      if (n++ == 50) continue; // one dropped frame in the last 3 s
      s = e.add(frame(t.round(), person(dx: -215)));
    }
    expect(s.fpsOk, isTrue);
    expect(e.requiredFrames, 44);
  });

  test('heartbeats keep the person checks but lower the frame rate', () {
    final e = ev();
    var s = feed(e, person(dx: -215));
    expect(s.allPass, isTrue);
    final last = (52 * 1000 / 15).round();
    for (var k = 1; k <= 20; k++) {
      s = e.add(PoseFrame.heartbeat(last + 100 * k, imageW: 480, imageH: 640));
    }
    expect(s.bodyVisible, isTrue);
    expect(s.fpsOk, isFalse);
  });

  test('nobody in frame', () {
    final s = feed(ev(), null);
    expect(s.bodyVisible, isFalse);
    expect(s.skeleton, isNull);
    expect(s.fpsOk, isTrue);
  });

  test('the real classifier sees a synthetic standing user', () {
    final prayer = generateSyntheticPrayer(SyntheticCase.normal, seed: 3);
    final e = PlacementEvaluator();
    PlacementState? s;
    for (final f in prayer.recording.frames) {
      if (f.tMs > 3500) break;
      s = e.add(f);
    }
    expect(s!.bodyVisible, isTrue);
    expect(s.confidenceOk, isTrue);
    expect(s.fpsOk, isTrue);
  });

  group('PosePlacementCheck', () {
    test('stop releases the camera; errors become a message', () async {
      final engine = _Engine();
      final check = PosePlacementCheck(engine: engine, watchLifecycle: false);
      final states = <PlacementState>[];
      check.state.listen(states.add);
      await check.start();
      engine.ctrl!.add(frame(0, person(dx: -215)));
      await pumpEventQueue();
      expect(states.last.bodyVisible, isTrue);
      engine.ctrl!.addError(const PoseEngineError('cameraInUse', 'busy'));
      await pumpEventQueue();
      expect(states.last.message, 'The camera is not available');
      await check.stop();
      expect(engine.stops, 1);
    });

    test('opens the requested lens and switches it live', () async {
      final engine = _Engine();
      final check = PosePlacementCheck(
        engine: engine,
        cameraConfig: const CameraConfig(fps: 15, width: 480, height: 640),
        watchLifecycle: false,
      );
      final states = <PlacementState>[];
      check.state.listen(states.add);
      await check.start(lens: CameraLens.front);
      expect(engine.configs.single.lens, CameraLens.front);
      expect(engine.configs.single.fps, 15);
      engine.ctrl!.add(frame(0, person(dx: -215)));
      await pumpEventQueue();
      expect(states.last.bodyVisible, isTrue);
      expect(states.last.lens, CameraLens.front);

      final first = engine.ctrl!;
      await check.switchLens(CameraLens.rear);
      await pumpEventQueue();
      expect(engine.stops, 1);
      expect(first.isClosed, isTrue);
      expect(engine.configs.map((c) => c.lens), [
        CameraLens.front,
        CameraLens.rear,
      ]);
      // The checks start over with the new camera.
      expect(states.last.bodyVisible, isFalse);
      expect(states.last.lens, CameraLens.rear);
      expect(check.requestedLens, CameraLens.rear);
      await check.stop();
    });

    test('states carry the lens the engine actually opened', () async {
      final engine = _Engine();
      final active = ValueNotifier<CameraLens?>(null);
      final check = PosePlacementCheck(
        engine: engine,
        activeLens: active,
        watchLifecycle: false,
      );
      final states = <PlacementState>[];
      check.state.listen(states.add);
      await check.start(lens: CameraLens.front);
      engine.ctrl!.add(frame(0, person(dx: -215)));
      await pumpEventQueue();
      expect(states.last.lens, CameraLens.front); // Not reported yet.
      // No front camera on this phone: the engine fell back to the rear.
      active.value = CameraLens.rear;
      await pumpEventQueue();
      expect(states.last.lens, CameraLens.rear);
      expect(states.last.bodyVisible, isTrue);
      engine.ctrl!.add(frame(67, person(dx: -215)));
      await pumpEventQueue();
      expect(states.last.lens, CameraLens.rear);
      await check.stop();
    });

    test('landmarks reach the state unmirrored for the front lens', () async {
      final engine = _Engine();
      final check = PosePlacementCheck(
        engine: engine,
        activeLens: ValueNotifier(CameraLens.front),
        watchLifecycle: false,
      );
      final states = <PlacementState>[];
      check.state.listen(states.add);
      await check.start(lens: CameraLens.front);
      final p = person(dx: -215);
      engine.ctrl!.add(frame(0, p));
      await pumpEventQueue();
      expect(states.last.lens, CameraLens.front);
      expect(states.last.skeleton, same(p));
      await check.stop();
    });

    test('switchLens before start only sets the lens', () async {
      final engine = _Engine();
      final check = PosePlacementCheck(engine: engine, watchLifecycle: false);
      await check.switchLens(CameraLens.front);
      expect(engine.configs, isEmpty);
      expect(check.requestedLens, CameraLens.front);
    });

    testWidgets('preview is shown only while checking', (tester) async {
      final engine = _Engine();
      final check = PosePlacementCheck(
        engine: engine,
        watchLifecycle: false,
        previewBuilder: (_) => const Text('preview', key: Key('p')),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(builder: (c) => check.buildPreview(c)!),
        ),
      );
      expect(find.byKey(const Key('p')), findsNothing);
      unawaited(check.start());
      await tester.pump();
      expect(find.byKey(const Key('p')), findsOneWidget);
      unawaited(check.stop());
      await tester.pump();
      expect(find.byKey(const Key('p')), findsNothing);
    });
  });
}

class _Engine implements PoseEngine {
  StreamController<PoseFrame>? ctrl;
  int stops = 0;
  final configs = <CameraConfig>[];

  @override
  Stream<PoseFrame> start(CameraConfig config) {
    configs.add(config);
    return (ctrl = StreamController<PoseFrame>()).stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    await ctrl?.close();
  }
}
