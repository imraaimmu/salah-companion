import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/screens/home_page.dart';
import 'package:salah_companion/src/screens/setup_flow.dart';
import 'package:salah_companion/src/services/seams.dart';

import 'helpers.dart';

Future<void> next(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('setup-next')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('first run shows setup; finishing persists settings', (
    tester,
  ) async {
    final h = Harness(setupDone: false);
    await h.pumpApp(tester);
    expect(find.byType(SetupFlow), findsOneWidget);
    expect(find.text('Assalamu alaikum'), findsOneWidget);

    await next(tester); // Camera
    expect(find.textContaining('No video is recorded'), findsOneWidget);
    expect(find.textContaining('Do Not Disturb'), findsOneWidget);
    await tester.tap(find.byKey(const Key('allow-camera')));
    await tester.pumpAndSettle();
    expect(h.camera.requests, 1);
    expect(find.text('Camera allowed'), findsOneWidget);

    await next(tester); // Surahs
    await tester.tap(find.byKey(const Key('surah-manual')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surah-rakah1')), findsOneWidget);
    expect(find.byKey(const Key('surah-rakah2')), findsOneWidget);

    await next(tester); // Opening dua
    await tester.tap(find.byKey(const Key('dua-18000')));
    await tester.pumpAndSettle();

    await next(tester); // Pace
    expect(find.text('1.5 s'), findsOneWidget);
    final slider = find.byKey(const Key('gap-slider'));
    // Drag to the far end: 3 s.
    await tester.drag(slider, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gap-value')), findsOneWidget);
    expect(find.text('3 s'), findsWidgets);
    await tester.tap(find.byKey(const Key('soft-glow')));
    await tester.pumpAndSettle();

    await next(tester); // Audio check
    expect(find.text('Media volume is on.'), findsOneWidget);
    await next(tester); // Placement guide
    expect(find.text('Placing the phone'), findsOneWidget);
    expect(h.store.setupDone, isFalse);
    await next(tester); // Done

    expect(h.store.setupDone, isTrue);
    final saved = h.store.saved!;
    expect(saved.autoPairs, isFalse);
    expect(saved.openingDuaMs, 18000);
    expect(saved.ayahGapMs, 3000);
    expect(saved.softGlow, isTrue);
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('settings are saved after each step', (tester) async {
    final h = Harness(setupDone: false);
    await h.pumpApp(tester);
    await next(tester);
    await next(tester);
    await next(tester); // now on Opening dua
    await tester.tap(find.byKey(const Key('dua-0')));
    await tester.pumpAndSettle();
    await next(tester);
    expect(h.store.saved!.openingDuaMs, 0);
    expect(h.store.setupDone, isFalse);
  });

  testWidgets('Back returns to the previous step', (tester) async {
    final h = Harness(setupDone: false);
    await h.pumpApp(tester);
    expect(find.byKey(const Key('setup-back')), findsNothing);
    await next(tester);
    await tester.tap(find.byKey(const Key('setup-back')));
    await tester.pumpAndSettle();
    expect(find.text('Assalamu alaikum'), findsOneWidget);
  });

  testWidgets('audio check blocks Next at zero volume and warns on Bluetooth', (
    tester,
  ) async {
    final h = Harness(
      setupDone: false,
      audio: const AudioStatus(volumeAboveZero: false, bluetooth: true),
    );
    await h.pumpApp(tester);
    for (var i = 0; i < 5; i++) {
      await next(tester);
    }
    expect(find.text('Audio check'), findsOneWidget);
    expect(find.textContaining('Turn it up to continue'), findsOneWidget);
    expect(find.textContaining('Bluetooth audio is connected'), findsOneWidget);
    final btn = tester.widget<FilledButton>(
      find.byKey(const Key('setup-next')),
    );
    expect(btn.onPressed, isNull);

    h.audio.status = const AudioStatus();
    await tester.tap(find.byKey(const Key('audio-recheck')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('setup-next')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('setup is not shown again once done', (tester) async {
    final h = Harness(setupDone: true);
    await h.pumpApp(tester);
    expect(find.byType(SetupFlow), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('setup survives large text', (tester) async {
    final h = Harness(setupDone: false);
    await h.pumpScreen(tester, const SetupFlow(), textScale: 2);
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      expect(tester.takeException(), isNull);
      await next(tester);
    }
    expect(tester.takeException(), isNull);
  });
}
