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

  test('no floor in front: centred user fails the floor check', () {
    final s = feed(ev(), person());
    expect(s.floorSpaceOk, isFalse);
    expect(s.message, 'Leave space in front of you for sujood');
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

  @override
  Stream<PoseFrame> start(CameraConfig config) =>
      (ctrl = StreamController<PoseFrame>()).stream;

  @override
  Future<void> stop() async {
    stops++;
    await ctrl?.close();
  }
}
