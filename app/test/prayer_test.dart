import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/screens/prayer_page.dart';
import 'package:salah_companion/src/screens/summary_page.dart';
import 'package:salah_companion/src/services/fakes.dart';
import 'package:salah_core/salah_core.dart';

import 'helpers.dart';

Color dotColor(WidgetTester tester) {
  final box = tester.widget<Container>(find.byKey(const Key('tracking-dot')));
  return (box.decoration! as BoxDecoration).color!;
}

Future<FakeSessionRunner> pumpPrayer(
  WidgetTester tester,
  Harness h, {
  SessionSettings settings = const SessionSettings(),
}) async {
  final runner = FakeSessionRunner(settings);
  await h.pumpScreen(tester, PrayerPage(runner: runner, settings: settings));
  return runner;
}

Future<void> longPress(WidgetTester tester, Duration hold) async {
  final g = await tester.startGesture(
    tester.getCenter(find.byType(PrayerPage)),
  );
  await tester.pump(hold);
  await g.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('pure black, one dim dot, no text; screen kept awake and dim', (
    tester,
  ) async {
    final h = Harness();
    final runner = await pumpPrayer(tester, h);
    expect(runner.startCalls, 1);
    expect(h.screen.inPrayerMode, isTrue);
    expect(
      find.descendant(of: find.byType(PrayerPage), matching: find.byType(Text)),
      findsNothing,
    );
    final bg = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(PrayerPage),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(bg.color, const Color(0xFF000000));
    expect(dotColor(tester), PrayerPage.dotTracking);
    expect(find.byKey(const Key('soft-glow-circle')), findsNothing);
  });

  testWidgets('dot turns amber when tracking is lost, back when restored', (
    tester,
  ) async {
    final h = Harness();
    final runner = await pumpPrayer(tester, h);
    runner.emit(
      const SessionStatus(state: PrayerState.qiyam1, rakah: 1, tracking: false),
    );
    await tester.pump();
    expect(dotColor(tester), PrayerPage.dotLost);
    runner.emit(const SessionStatus(state: PrayerState.qiyam1, rakah: 1));
    await tester.pump();
    expect(dotColor(tester), PrayerPage.dotTracking);
  });

  testWidgets('a short press does nothing', (tester) async {
    final h = Harness();
    final runner = await pumpPrayer(tester, h);
    await longPress(tester, const Duration(milliseconds: 800));
    expect(find.byKey(const Key('end-dialog')), findsNothing);
    await tester.tap(find.byType(PrayerPage));
    await tester.pump();
    expect(find.byKey(const Key('end-dialog')), findsNothing);
    expect(runner.cancelCalls, 0);
  });

  testWidgets('long-press 1.5 s asks, Keep going stays', (tester) async {
    final h = Harness();
    final runner = await pumpPrayer(tester, h);
    await longPress(tester, const Duration(milliseconds: 1600));
    expect(find.byKey(const Key('end-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('end-keep')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('end-dialog')), findsNothing);
    expect(find.byType(PrayerPage), findsOneWidget);
    expect(runner.cancelCalls, 0);
  });

  testWidgets('the end confirmation closes by itself after 10 s', (
    tester,
  ) async {
    final h = Harness();
    await pumpPrayer(tester, h);
    await longPress(tester, const Duration(milliseconds: 1600));
    expect(find.byKey(const Key('end-dialog')), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('end-dialog')), findsNothing);
    expect(find.byType(PrayerPage), findsOneWidget);
  });

  testWidgets('long-press then End cancels the session and shows the summary', (
    tester,
  ) async {
    final h = Harness();
    final runner = await pumpPrayer(tester, h);
    await longPress(tester, const Duration(milliseconds: 1600));
    await tester.tap(find.byKey(const Key('end-confirm')));
    await tester.pumpAndSettle();
    expect(runner.cancelCalls, 1);
    expect(find.byType(SummaryPage), findsOneWidget);
    expect(find.text('Session ended'), findsOneWidget);
    expect(h.screen.inPrayerMode, isFalse);
  });

  testWidgets('goes to the summary when the session is over', (tester) async {
    final h = Harness();
    final runner = await pumpPrayer(tester, h);
    runner.emit(
      const SessionStatus(
        state: PrayerState.done,
        rakah: 2,
        ended: EndReason.completed,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text("Fajr completed · 2 rak'ahs"), findsOneWidget);
    expect(h.screen.inPrayerMode, isFalse);
    expect(runner.cancelCalls, 0);
  });

  testWidgets('session ending while the confirmation is open', (tester) async {
    final h = Harness();
    final runner = await pumpPrayer(tester, h);
    await longPress(tester, const Duration(milliseconds: 1600));
    runner.emit(const SessionStatus(ended: EndReason.cameraLost));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('end-dialog')), findsNothing);
    expect(find.text('Prayer tracking stopped'), findsOneWidget);
  });

  testWidgets('Back ends the session', (tester) async {
    final h = Harness();
    final runner = await pumpPrayer(tester, h);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(runner.cancelCalls, 1);
    expect(find.byType(SummaryPage), findsOneWidget);
  });

  testWidgets('soft glow shows a dim breathing circle', (tester) async {
    final h = Harness();
    await pumpPrayer(
      tester,
      h,
      settings: const SessionSettings(softGlow: true),
    );
    expect(find.byKey(const Key('soft-glow-circle')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.descendant(of: find.byType(PrayerPage), matching: find.byType(Text)),
      findsNothing,
    );
  });

  testWidgets('TalkBack users can end with a long-press action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final h = Harness();
    await pumpPrayer(tester, h);
    final node = find.bySemanticsLabel(RegExp('Prayer in progress'));
    expect(node, findsOneWidget);
    tester.semantics.longPress(
      find.semantics.byLabel(RegExp('Prayer in progress')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('end-dialog')), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    handle.dispose();
  });
}
