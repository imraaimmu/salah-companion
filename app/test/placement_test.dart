import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/screens/placement_page.dart';
import 'package:salah_companion/src/screens/prayer_page.dart';
import 'package:salah_companion/src/services/fakes.dart';
import 'package:salah_companion/src/services/seams.dart';
import 'package:salah_companion/src/widgets/skeleton_painter.dart';
import 'package:salah_core/salah_core.dart';

import 'helpers.dart';

Future<void> emit(WidgetTester tester, Harness h, PlacementState s) async {
  h.placement.emit(s);
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('shows a placeholder preview, status line and four checks', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    expect(h.placement.startCalls, 1);
    expect(find.byKey(const Key('preview-placeholder')), findsOneWidget);
    expect(
      find.text('Stand side-on where the phone can see you'),
      findsOneWidget,
    );
    for (final k in ['body', 'confidence', 'fps', 'floor']) {
      expect(find.byKey(Key('check-$k')), findsOneWidget);
    }
    expect(h.prompter.spoken, ['Stand side-on where the phone can see you']);
  });

  testWidgets('status line uses the check message and speaks it once', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    const s = PlacementState(
      bodyVisible: true,
      fpsOk: true,
      message: 'Move the phone back',
    );
    await emit(tester, h, s);
    await emit(tester, h, s);
    expect(find.text('Move the phone back'), findsOneWidget);
    expect(
      h.prompter.spoken.where((t) => t == 'Move the phone back'),
      hasLength(1),
    );
  });

  testWidgets('derives prompts from the first failing check', (tester) async {
    expect(
      PlacementPage.messageFor(
        const PlacementState(bodyVisible: true, confidenceOk: true),
      ),
      'Turn on a light',
    );
    expect(
      PlacementPage.messageFor(
        const PlacementState(
          bodyVisible: true,
          confidenceOk: true,
          fpsOk: true,
        ),
      ),
      'Step back a little so sujood fits in view',
    );
  });

  testWidgets('countdown does not start until all four checks pass', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    await emit(
      tester,
      h,
      const PlacementState(bodyVisible: true, confidenceOk: true, fpsOk: true),
    );
    expect(find.byKey(const Key('countdown')), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(PrayerPage), findsNothing);
    expect(h.runners, isEmpty);
  });

  testWidgets('all checks pass: 5-second countdown, then the prayer screen', (
    tester,
  ) async {
    final h = Harness(settings: const SessionSettings(softGlow: true));
    await h.pumpScreen(
      tester,
      const PlacementPage(settings: SessionSettings(ayahGapMs: 500)),
    );
    await emit(tester, h, allPass);
    expect(find.byKey(const Key('countdown')), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(h.prompter.spoken.last, contains('Step onto your mat'));

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('4'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('1'), findsOneWidget);
    expect(find.byType(PrayerPage), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PrayerPage), findsOneWidget);
    expect(h.placement.stopCalls, 1);
    expect(h.runner.settings.ayahGapMs, 500);
    expect(h.runner.startCalls, 1);
  });

  testWidgets('the chosen prayer is the title, spoken in the countdown and '
      'handed to the session', (tester) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage(prayer: Prayer.dhuhr));
    expect(find.byKey(const Key('placement-title')), findsOneWidget);
    expect(find.text("Dhuhr · 4 rak'ahs"), findsOneWidget);
    await emit(tester, h, allPass);
    expect(
      h.prompter.spoken.last,
      "Good. Step onto your mat for Dhuhr, 4 rak'ahs. Starting in 5 seconds.",
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PrayerPage), findsOneWidget);
    expect(h.runner.prayer, Prayer.dhuhr);
    expect(
      tester.widget<PrayerPage>(find.byType(PrayerPage)).prayer,
      Prayer.dhuhr,
    );
  });

  test('titles for every prayer', () {
    expect(
      [for (final p in Prayer.values) PlacementPage.titleFor(p)],
      [
        "Fajr · 2 rak'ahs",
        "Dhuhr · 4 rak'ahs",
        "Asr · 4 rak'ahs",
        "Maghrib · 3 rak'ahs",
        "Isha · 4 rak'ahs",
      ],
    );
  });

  testWidgets('countdown cancels if a check fails, and restarts from 5', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    await emit(tester, h, allPass);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('2'), findsOneWidget);

    await emit(tester, h, allPass.copyWith(floorSpaceOk: false));
    expect(find.byKey(const Key('countdown')), findsNothing);
    expect(
      find.text('Step back a little so sujood fits in view'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(PrayerPage), findsNothing);

    await emit(tester, h, allPass);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('skeleton points reach the overlay painter', (tester) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    final skel = standingSkeleton();
    await emit(tester, h, PlacementState(bodyVisible: true, skeleton: skel));
    final paint = tester.widget<CustomPaint>(
      find.byKey(const Key('skeleton-overlay')),
    );
    expect((paint.painter! as SkeletonPainter).points, same(skel));
  });

  test('skeleton mapping is contain-fit and centred (like FIT_CENTER)', () {
    const p = Landmark(240, 320, 0, 1);
    final o = SkeletonPainter.map(p, const Size(400, 400), 480, 640);
    expect(o.dx, closeTo(200, 0.01));
    expect(o.dy, closeTo(200, 0.01));
    // The frame's corner lands on the letterboxed image's corner.
    const corner = Landmark(0, 0, 0, 1);
    final c = SkeletonPainter.map(corner, const Size(400, 400), 480, 640);
    expect(c.dx, closeTo(50, 0.01));
    expect(c.dy, closeTo(0, 0.01));
  });

  test('mirror flips x for display only, around the frame centre', () {
    const p = Landmark(100, 320, 0, 1);
    const size = Size(400, 400);
    final plain = SkeletonPainter.map(p, size, 480, 640);
    final mirrored = SkeletonPainter.map(p, size, 480, 640, mirror: true);
    // Letterbox: 300 x 400 image centred, x offset 50, scale 0.625.
    expect(plain.dx, closeTo(50 + 100 * 0.625, 0.01));
    expect(mirrored.dx, closeTo(50 + 380 * 0.625, 0.01));
    expect(mirrored.dy, plain.dy);
    // Symmetric about the centre of the displayed image.
    expect(plain.dx + mirrored.dx, closeTo(400, 0.01));
    // The points themselves are never changed.
    expect(p.x, 100);
  });

  test('a mirrored painter draws the mirror image', () {
    final pts = standingSkeleton();
    List<Offset> drawn(bool mirror) {
      final rec = _RecordingCanvas();
      SkeletonPainter(
        points: pts,
        imageW: 480,
        imageH: 640,
        mirror: mirror,
      ).paint(rec, const Size(480, 640));
      return rec.circles;
    }

    final a = drawn(false);
    final b = drawn(true);
    expect(a, isNotEmpty);
    expect(b, hasLength(a.length));
    for (var i = 0; i < a.length; i++) {
      expect(b[i].dx, closeTo(480 - a[i].dx, 0.001));
      expect(b[i].dy, closeTo(a[i].dy, 0.001));
    }
    expect(
      SkeletonPainter(points: pts, imageW: 480, imageH: 640).shouldRepaint(
        SkeletonPainter(points: pts, imageW: 480, imageH: 640, mirror: true),
      ),
      isTrue,
    );
  });

  testWidgets('the overlay is mirrored only while the front camera is active', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    SkeletonPainter painter() =>
        tester
                .widget<CustomPaint>(find.byKey(const Key('skeleton-overlay')))
                .painter!
            as SkeletonPainter;
    final skel = standingSkeleton();
    await emit(tester, h, PlacementState(bodyVisible: true, skeleton: skel));
    expect(painter().mirror, isFalse);
    await emit(
      tester,
      h,
      PlacementState(bodyVisible: true, skeleton: skel, lens: CameraLens.front),
    );
    expect(painter().mirror, isTrue);
    expect(painter().points, same(skel));
  });

  testWidgets('placement opens the camera from the settings', (tester) async {
    final h = Harness();
    await h.pumpScreen(
      tester,
      const PlacementPage(settings: SessionSettings(camera: CameraLens.front)),
    );
    expect(h.placement.lenses, [CameraLens.front]);
  });

  testWidgets('switch camera flips the lens live, saves it and the session '
      'uses it', (tester) async {
    final h = Harness(
      settings: const SessionSettings(autoIndex: 3, ayahGapMs: 2000),
    );
    await h.pumpScreen(
      tester,
      const PlacementPage(settings: SessionSettings(autoIndex: 3)),
    );
    expect(find.byTooltip('Switch camera'), findsOneWidget);
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pump();
    expect(h.placement.lenses, [CameraLens.rear, CameraLens.front]);
    expect(h.store.saved!.camera, CameraLens.front);
    // Only the camera changed in the stored settings.
    expect(h.store.saved!.ayahGapMs, 2000);
    expect(h.store.saved!.autoPairDate, isNull);

    // The check now reports the front lens; flipping again goes back.
    await emit(tester, h, const PlacementState(lens: CameraLens.front));
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pump();
    expect(h.placement.lenses.last, CameraLens.rear);
    expect(h.store.saved!.camera, CameraLens.rear);

    // Flip to front once more and let the countdown run: the session opens
    // the same camera.
    await emit(tester, h, const PlacementState());
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pump();
    await emit(tester, h, allPass.copyWith(lens: CameraLens.front));
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(h.runner.settings.camera, CameraLens.front);
    expect(h.runner.settings.autoIndex, 3);
  });

  testWidgets('switching camera cancels a running countdown', (tester) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    await emit(tester, h, allPass);
    expect(find.byKey(const Key('countdown')), findsOneWidget);
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pump();
    expect(find.byKey(const Key('countdown')), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(PrayerPage), findsNothing);
  });

  testWidgets('cancel button leaves and releases the camera', (tester) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('stub-home'), findsOneWidget);
    expect(h.placement.stopCalls, 1);
  });

  testWidgets('checks are announced to TalkBack', (tester) async {
    final handle = tester.ensureSemantics();
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    await emit(tester, h, const PlacementState(bodyVisible: true));
    expect(find.bySemanticsLabel('Whole body in view: passed'), findsOneWidget);
    expect(find.bySemanticsLabel('Enough light: not yet'), findsOneWidget);
    expect(
      tester.getSemantics(find.byTooltip('Cancel')),
      isSemantics(tooltip: 'Cancel', isButton: true),
    );
    handle.dispose();
  });

  testWidgets('placement survives large text and RTL', (tester) async {
    final h = Harness();
    await h.pumpScreen(
      tester,
      const PlacementPage(),
      textDirection: TextDirection.rtl,
      textScale: 2,
    );
    await emit(tester, h, allPass.copyWith(fpsOk: false));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a quiet takbir hint appears once all checks pass', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpScreen(tester, const PlacementPage());
    const hint =
        'Raise your hands clearly for the takbir so the recitation can start';
    await emit(tester, h, allPass.copyWith(floorSpaceOk: false));
    expect(find.text(hint), findsNothing);
    await emit(tester, h, allPass);
    expect(find.text(hint), findsOneWidget);
    expect(find.byKey(const Key('countdown')), findsOneWidget);
    await emit(tester, h, allPass.copyWith(fpsOk: false));
    expect(find.text(hint), findsNothing);
  });
}

/// Records circle centres drawn by the painter.
class _RecordingCanvas implements Canvas {
  final circles = <Offset>[];

  @override
  void drawCircle(Offset c, double radius, Paint paint) => circles.add(c);

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
