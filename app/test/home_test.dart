import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/screens/home_page.dart';
import 'package:salah_companion/src/screens/placement_page.dart';
import 'package:salah_companion/src/screens/settings_page.dart';
import 'package:salah_companion/src/services/seams.dart';
import 'package:salah_core/salah_core.dart';

import 'helpers.dart';

void main() {
  testWidgets('home shows one Start Fajr button, two small icons and today', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpApp(tester);

    expect(find.byKey(const Key('start-fajr')), findsOneWidget);
    expect(find.text('Start Fajr'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Practice'), findsOneWidget);
    expect(find.text('Ad-Duha · Ash-Sharh'), findsOneWidget);
  });

  testWidgets("today's line follows a manual surah choice", (tester) async {
    final h = Harness(
      settings: const SessionSettings(
        autoPairs: false,
        surahRakah1: 112,
        surahRakah2: 114,
      ),
    );
    await h.pumpApp(tester);
    expect(find.text('Al-Ikhlas · An-Nas'), findsOneWidget);
  });

  testWidgets('Start opens the placement screen', (tester) async {
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('start-fajr')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlacementPage), findsOneWidget);
    expect(h.placement.startCalls, 1);
  });

  testWidgets('Start is blocked while media volume is zero', (tester) async {
    final h = Harness(audio: const AudioStatus(volumeAboveZero: false));
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('start-fajr')));
    await tester.pump();
    expect(find.text('Turn the media volume up to start.'), findsOneWidget);
    expect(find.byType(PlacementPage), findsNothing);
  });

  testWidgets('settings icon opens settings; practice is not built yet', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.byTooltip('Practice'));
    await tester.pump();
    expect(find.text('Practice mode is coming soon.'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
  });

  testWidgets('home has TalkBack labels', (tester) async {
    final handle = tester.ensureSemantics();
    final h = Harness();
    await h.pumpApp(tester);
    expect(find.bySemanticsLabel('Start Fajr prayer'), findsOneWidget);
    expect(
      find.bySemanticsLabel("Today's surahs: Ad-Duha · Ash-Sharh"),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('home survives large text and right-to-left', (tester) async {
    final h = Harness();
    await h.pumpScreen(
      tester,
      const HomePage(),
      textDirection: TextDirection.rtl,
      textScale: 2,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Start Fajr'), findsOneWidget);
    // Icons sit at the start-of-reading-order corner's opposite: top left in RTL.
    final settings = tester.getCenter(find.byTooltip('Settings'));
    expect(settings.dx, lessThan(400));
  });
}
