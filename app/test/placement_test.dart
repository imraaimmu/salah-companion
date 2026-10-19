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
      'Leave space in front of you for sujood',
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
    expect(find.text('Leave space in front of you for sujood'), findsOneWidget);
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
    expect(find.bySemanticsLabel('Body in view: passed'), findsOneWidget);
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
}
