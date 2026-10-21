// The engine delivers landmarks in the upright, UNMIRRORED camera frame for
// both the rear and the front camera (docs/SPEC.md section 5). These tests
// pin down why that is enough for the prayer logic to be lens-independent,
// and what a wrongly mirrored input would look like.
import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

/// MediaPipe left/right landmark pairs (eyes, ears, mouth, then 11..32).
const _pairs = <(int, int)>[
  (1, 4), (2, 5), (3, 6), (7, 8), (9, 10), //
  (11, 12), (13, 14), (15, 16), (17, 18), (19, 20), (21, 22),
  (23, 24), (25, 26), (27, 28), (29, 30), (31, 32),
];

final List<int> _swap = () {
  final m = List<int>.generate(LandmarkIndex.count, (i) => i);
  for (final (l, r) in _pairs) {
    m[l] = r;
    m[r] = l;
  }
  return m;
}();

/// What an engine would deliver if it ran the pose model on a MIRRORED
/// image (as a front-camera preview is shown): x mirrored, and the model,
/// seeing a mirror-image person, labels the real left side "right".
List<Landmark> mirroredEngine(List<Landmark> p, int imageW) => [
      for (var i = 0; i < p.length; i++)
        Landmark(imageW - p[_swap[i]].x, p[_swap[i]].y, p[_swap[i]].z,
            p[_swap[i]].conf),
    ];

/// Mirroring x for display only, without relabelling sides (what a skeleton
/// overlay does): never valid input for the prayer logic.
List<Landmark> displayMirrored(List<Landmark> p, int imageW) => [
      for (final l in p) Landmark(imageW - l.x, l.y, l.z, l.conf),
    ];

Recording mapRecording(
    Recording r, List<Landmark> Function(List<Landmark>, int) f) {
  final frames = [
    for (final fr in r.frames)
      PoseFrame(
        tMs: fr.tMs,
        landmarks: fr.landmarks == null ? null : f(fr.landmarks!, fr.imageW),
        people: [for (final p in fr.people) f(p, fr.imageW)],
        imageW: fr.imageW,
        imageH: fr.imageH,
        tiltDeg: fr.tiltDeg,
      ),
  ];
  return Recording(header: r.header, frames: frames);
}

/// In a real (unmirrored) camera frame of a person standing side-on, the
/// side nearer the camera is the side they face towards: facing right in the
/// image (towards larger x) shows the right side. Returns +1 / -1 for the
/// facing direction (nose vs near ear) and whether the more visible side
/// agrees with it.
(int facing, bool consistent) geometry(List<Landmark> p) {
  double mean(List<int> ix) =>
      ix.map((i) => p[i].conf).reduce((a, b) => a + b) / ix.length;
  final left = mean(const [11, 23, 25, 27]);
  final right = mean(const [12, 24, 26, 28]);
  final rightNear = right > left;
  final ear = rightNear ? p[LandmarkIndex.rightEar] : p[LandmarkIndex.leftEar];
  final facing = p[LandmarkIndex.nose].x > ear.x ? 1 : -1;
  return (facing, (facing > 0) == rightNear);
}

List<Landmark> firstStanding(Recording r) =>
    r.frames.firstWhere((f) => f.landmarks != null).landmarks!;

void main() {
  for (final facing in [1, -1]) {
    final dir = facing > 0 ? 'right' : 'left';
    group('synthetic prayer facing $dir', () {
      final p = generateSyntheticPrayer(SyntheticCase.normal,
          seed: 3,
          prayer: Prayer.dhuhr,
          options: SyntheticOptions.clean(facing: facing));

      test('unmirrored input has real-world geometry', () {
        final (f, consistent) = geometry(firstStanding(p.recording));
        expect(f, facing);
        expect(consistent, isTrue);
      });

      test('display-only mirroring breaks that geometry (never fed in)', () {
        final m = mapRecording(p.recording, displayMirrored);
        final (f, consistent) = geometry(firstStanding(m));
        expect(f, -facing);
        expect(consistent, isFalse,
            reason: 'x mirrored without relabelling sides is a person who '
                'cannot exist in an unmirrored frame');
      });

      test(
          'a mirrored engine would just be a person facing the other way, '
          'so the logic gives the same events either way', () {
        final m = mapRecording(p.recording, mirroredEngine);
        final (f, consistent) = geometry(firstStanding(m));
        expect(f, -facing);
        expect(consistent, isTrue);

        final c1 = RuleBasedClassifier();
        final c2 = RuleBasedClassifier();
        final a = replay(p.recording, p.labels, classifier: c1);
        final b = replay(m, p.labels, classifier: c2);
        expect(c1.nearSide, facing > 0 ? BodySide.right : BodySide.left);
        expect(c2.nearSide, facing > 0 ? BodySide.left : BodySide.right);
        expect(a.reachedFinal, isTrue);
        expect(a.wrongStarts, isEmpty);
        expect(a.missed, isEmpty);
        expect(b.events, a.events);
        expect(b.finalState, a.finalState);
      });
    });
  }

  test('the same prayer facing either way reaches the same states', () {
    final r = generateSyntheticPrayer(SyntheticCase.normal,
        seed: 5, options: const SyntheticOptions.clean(facing: 1));
    final l = generateSyntheticPrayer(SyntheticCase.normal,
        seed: 5, options: const SyntheticOptions.clean(facing: -1));
    final a = replay(r.recording, r.labels);
    final b = replay(l.recording, l.labels);
    for (final res in [a, b]) {
      expect(res.reachedFinal, isTrue);
      expect(res.wrongStarts, isEmpty);
      expect(res.missed, isEmpty);
    }
    expect(b.events.map((e) => e.runtimeType).toList(),
        a.events.map((e) => e.runtimeType).toList());
  });
}
