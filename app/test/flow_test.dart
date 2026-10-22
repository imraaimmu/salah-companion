import 'dart:async';

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

import 'dart:io';

import 'helpers.dart';

void main() {
  testWidgets('home -> placement -> prayer -> summary -> home', (tester) async {
    final h = Harness(settings: const SessionSettings(softGlow: true));
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('start-prayer')));
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

  testWidgets('a picked Maghrib flows from Home to its summary', (
    tester,
  ) async {
    final h = Harness(now: DateTime(2026, 10, 20, 13, 0));
    await h.pumpApp(tester);
    expect(find.text('Start Dhuhr'), findsOneWidget);
    await tester.tap(find.byKey(const Key('prayer-maghrib')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-prayer')));
    await tester.pumpAndSettle();
    expect(find.text("Maghrib · 3 rak'ahs"), findsOneWidget);

    h.placement.emit(allPass);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.runner.prayer, Prayer.maghrib);
    // The prayer screen shows no text at all.
    expect(
      find.descendant(of: find.byType(PrayerPage), matching: find.byType(Text)),
      findsNothing,
    );

    h.runner.emit(
      const SessionStatus(
        state: PrayerState.done,
        rakah: 3,
        ended: EndReason.completed,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text("Maghrib completed · 3 rak'ahs"), findsOneWidget);
    await tester.tap(find.byKey(const Key('summary-done')));
    await tester.pumpAndSettle();
    // Still the Dhuhr window: Home keeps the pick.
    expect(find.text('Start Maghrib'), findsOneWidget);
  });

  testWidgets('demo mode runs a 4-rak\'ah session too', (tester) async {
    await tester.pumpWidget(
      DemoServices.wrap(
        settingsStore: MemorySettingsStore(setupDone: true),
        screenControl: FakeScreenControl(),
        child: const SalahCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('prayer-isha')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-prayer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PrayerPage), findsOneWidget);
    for (
      var i = 0;
      i < 200 && find.byType(PrayerPage).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text("Isha completed · 4 rak'ahs"), findsOneWidget);
  });

  testWidgets('demo mode runs a whole session on its own', (tester) async {
    final screen = FakeScreenControl();
    await tester.pumpWidget(
      DemoServices.wrap(
        settingsStore: MemorySettingsStore(setupDone: true),
        screenControl: screen,
        clock: () => DateTime(2026, 10, 20, 5, 30), // Fajr time
        child: const SalahCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-prayer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Demo placement passes after 5.5 s, then the 5 s countdown.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PrayerPage), findsOneWidget);
    for (
      var i = 0;
      i < 60 && find.byType(PrayerPage).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text("Fajr completed · 2 rak'ahs"), findsOneWidget);
    await tester.tap(find.byKey(const Key('summary-done')));
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
  });

  group('FileSettingsStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('settings'));
    tearDown(() => dir.deleteSync(recursive: true));
    FileSettingsStore store() => FileSettingsStore(() async => dir);

    test('defaults, round trip and setup flag', () async {
      final s = store();
      expect((await s.load()).openingDuaMs, 6000);
      expect(await s.isSetupDone(), isFalse);
      await s.save(
        const SessionSettings(
          autoPairs: false,
          surahRakah1: 109,
          ayahGapMs: 2500,
          softGlow: true,
          showTrackingDetails: true,
        ),
      );
      await s.markSetupDone();
      final again = await store().load();
      expect(again.autoPairs, isFalse);
      expect(again.surahRakah1, 109);
      expect(again.ayahGapMs, 2500);
      expect(again.softGlow, isTrue);
      expect(again.showTrackingDetails, isTrue);
      expect(await store().isSetupDone(), isTrue);
    });

    test('corrupt file falls back to defaults', () async {
      File('${dir.path}/${FileSettingsStore.fileName}')
          .writeAsStringSync('{not json');
      expect((await store().load()).ayahGapMs, 1500);
    });
  });

  group('ResilientSettingsStore', () {
    test('a broken store never blocks: setup still completes', () async {
      final s = ResilientSettingsStore(
        FileSettingsStore(() async => throw StateError('no folder')),
      );
      expect(await s.isSetupDone(), isFalse);
      await s.save(const SessionSettings(ayahGapMs: 2000));
      await s.markSetupDone();
      expect((await s.load()).ayahGapMs, 2000);
      expect(await s.isSetupDone(), isTrue);
      expect(s.problem, contains('no folder'));
    });

    test('a hanging store times out', () async {
      final s = ResilientSettingsStore(
        FileSettingsStore(() => Completer<Directory>().future),
        timeout: const Duration(milliseconds: 50),
      );
      await s.save(const SessionSettings(ayahGapMs: 500));
      expect((await s.load()).ayahGapMs, 500);
    });
  });
}
