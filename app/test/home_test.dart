import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/screens/home_page.dart';
import 'package:salah_companion/src/screens/placement_page.dart';
import 'package:salah_companion/src/screens/settings_page.dart';
import 'package:salah_companion/src/services/seams.dart';
import 'package:salah_companion/src/theme.dart';
import 'package:salah_core/salah_core.dart';

import 'helpers.dart';

void main() {
  testWidgets('home shows one Start button, five prayers, icons and today', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpApp(tester);

    expect(find.byKey(const Key('start-prayer')), findsOneWidget);
    expect(find.text('Start Fajr'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Practice'), findsOneWidget);
    expect(find.text('Ad-Duha · Ash-Sharh'), findsOneWidget);
    for (final p in Prayer.values) {
      expect(find.byKey(Key('prayer-${p.name}')), findsOneWidget);
      expect(find.text(p.displayName), findsOneWidget);
    }
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
    await tester.tap(find.byKey(const Key('start-prayer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlacementPage), findsOneWidget);
    expect(h.placement.startCalls, 1);
  });

  testWidgets('Start is blocked while media volume is zero', (tester) async {
    final h = Harness(audio: const AudioStatus(volumeAboveZero: false));
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('start-prayer')));
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
    expect(
      find.bySemanticsLabel("Start Fajr prayer, 2 rak'ahs"),
      findsOneWidget,
    );
    for (final p in Prayer.values) {
      expect(
        tester.getSemantics(find.byKey(Key('prayer-${p.name}'))),
        matchesSemantics(
          label: p.displayName,
          isButton: true,
          hasTapAction: true,
          hasSelectedState: true,
          isSelected: p == Prayer.fajr,
        ),
      );
    }
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

  group('prayer row', () {
    Color colorOf(WidgetTester tester, Prayer p) => tester
        .widget<TextButton>(find.byKey(Key('prayer-${p.name}')))
        .style!
        .foregroundColor!
        .resolve({})!;

    for (final (time, prayer) in [
      (DateTime(2026, 10, 20, 5, 30), Prayer.fajr),
      (DateTime(2026, 10, 20, 11, 0), Prayer.dhuhr),
      (DateTime(2026, 10, 20, 16, 0), Prayer.asr),
      (DateTime(2026, 10, 20, 18, 45), Prayer.maghrib),
      (DateTime(2026, 10, 20, 22, 0), Prayer.isha),
    ]) {
      testWidgets('defaults to ${prayer.displayName} at '
          '${time.hour}:${time.minute}', (tester) async {
        final h = Harness(now: time);
        await h.pumpApp(tester);
        expect(find.text('Start ${prayer.displayName}'), findsOneWidget);
        for (final p in Prayer.values) {
          expect(
            colorOf(tester, p),
            p == prayer ? AppColors.accent : AppColors.textQuiet,
            reason: p.name,
          );
        }
      });
    }

    testWidgets('one tap switches the prayer and the button label', (
      tester,
    ) async {
      final h = Harness(now: DateTime(2026, 10, 20, 13, 0));
      await h.pumpApp(tester);
      expect(find.text('Start Dhuhr'), findsOneWidget);
      await tester.tap(find.byKey(const Key('prayer-maghrib')));
      await tester.pump();
      expect(find.text('Start Maghrib'), findsOneWidget);
      expect(find.text('Start Dhuhr'), findsNothing);
      expect(colorOf(tester, Prayer.maghrib), AppColors.accent);
      expect(colorOf(tester, Prayer.dhuhr), AppColors.textQuiet);
    });

    testWidgets('the picked prayer is the one that starts', (tester) async {
      final h = Harness(now: DateTime(2026, 10, 20, 13, 0));
      await h.pumpApp(tester);
      await tester.tap(find.byKey(const Key('prayer-asr')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-prayer')));
      await tester.pumpAndSettle();
      expect(find.text("Asr · 4 rak'ahs"), findsOneWidget);
      final page = tester.widget<PlacementPage>(find.byType(PlacementPage));
      expect(page.prayer, Prayer.asr);
    });

    testWidgets('a manual pick lasts until the clock enters another window', (
      tester,
    ) async {
      final h = Harness(now: DateTime(2026, 10, 20, 13, 0));
      await h.pumpApp(tester);
      await tester.tap(find.byKey(const Key('prayer-fajr')));
      await tester.pump();
      expect(find.text('Start Fajr'), findsOneWidget);
      // Still the Dhuhr window: the pick stays.
      h.now = DateTime(2026, 10, 20, 15, 29);
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('Start Fajr'), findsOneWidget);
      // The Asr window begins: back to the clock's guess.
      h.now = DateTime(2026, 10, 20, 15, 30);
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('Start Asr'), findsOneWidget);
    });

    testWidgets("today's surah line moves on at midnight while Home is open", (
      tester,
    ) async {
      final h = Harness(
        settings: const SessionSettings(
          autoIndex: 0,
          autoPairDate: '2026-10-20',
        ),
        now: DateTime(2026, 10, 20, 23, 58),
      );
      await h.pumpApp(tester);
      expect(find.text('Ad-Duha · Ash-Sharh'), findsOneWidget);
      // Still the Isha window after midnight: only the day changes.
      h.now = DateTime(2026, 10, 21, 0, 1);
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('Start Isha'), findsOneWidget);
      expect(find.text('At-Takathur · Al-\'Asr'), findsOneWidget);
      expect(find.text('Ad-Duha · Ash-Sharh'), findsNothing);
    });

    testWidgets("today's Auto pair moves on with a new day", (tester) async {
      final h = Harness(
        settings: const SessionSettings(
          autoIndex: 0,
          autoPairDate: '2026-10-19',
        ),
      );
      await h.pumpApp(tester);
      // Index 0 was yesterday's pair; today shows the next one.
      expect(find.text('At-Takathur · Al-\'Asr'), findsOneWidget);
    });
  });
}
