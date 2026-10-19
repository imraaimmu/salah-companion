import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/main.dart';
import 'package:salah_companion/src/screens/home_page.dart';
import 'package:salah_companion/src/screens/prayer_page.dart';
import 'package:salah_companion/src/screens/summary_page.dart';
import 'package:salah_companion/src/services/demo.dart';
import 'package:salah_companion/src/services/fakes.dart';
import 'package:salah_companion/src/services/settings_stores.dart';
import 'package:salah_core/salah_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers.dart';

void main() {
  testWidgets('home -> placement -> prayer -> summary -> home', (tester) async {
    final h = Harness(settings: const SessionSettings(softGlow: true));
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('start-fajr')));
    await tester.pumpAndSettle();

    h.placement.emit(allPass);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PrayerPage), findsOneWidget);
    expect(h.runner.settings.softGlow, isTrue);
    expect(h.screen.inPrayerMode, isTrue);

    h.runner.emit(
      const SessionStatus(
        state: PrayerState.done,
        rakah: 2,
        ended: EndReason.completed,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SummaryPage), findsOneWidget);

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(SummaryPage), findsNothing);
  });

  testWidgets('demo mode runs a whole session on its own', (tester) async {
    final screen = FakeScreenControl();
    await tester.pumpWidget(
      DemoServices.wrap(
        settingsStore: MemorySettingsStore(setupDone: true),
        screenControl: screen,
        child: const SalahCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-fajr')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Demo placement passes after 5.5 s, then the 5 s countdown.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PrayerPage), findsOneWidget);
    for (var i = 0; i < 46; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text("Fajr completed · 2 rak'ahs"), findsOneWidget);
    await tester.tap(find.byKey(const Key('summary-done')));
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
  });

  group('SharedPrefsSettingsStore', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('defaults, round trip and setup flag', () async {
      final store = SharedPrefsSettingsStore();
      expect((await store.load()).openingDuaMs, 6000);
      expect(await store.isSetupDone(), isFalse);
      await store.save(
        const SessionSettings(
          autoPairs: false,
          surahRakah1: 109,
          ayahGapMs: 2500,
          softGlow: true,
        ),
      );
      await store.markSetupDone();
      final again = await SharedPrefsSettingsStore().load();
      expect(again.autoPairs, isFalse);
      expect(again.surahRakah1, 109);
      expect(again.ayahGapMs, 2500);
      expect(again.softGlow, isTrue);
      expect(await SharedPrefsSettingsStore().isSetupDone(), isTrue);
    });

    test('corrupt value falls back to defaults', () async {
      await SharedPreferencesAsync().setString(
        SharedPrefsSettingsStore.settingsKey,
        '{not json',
      );
      expect((await SharedPrefsSettingsStore().load()).ayahGapMs, 1500);
    });
  });
}
