import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/screens/settings_page.dart';
import 'package:salah_core/salah_core.dart';

import 'helpers.dart';

void main() {
  testWidgets('settings shows the privacy line and saves each change', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpScreen(tester, const SettingsPage());
    await tester.pumpAndSettle();
    expect(
      find.text('No video is recorded. Nothing leaves your phone.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('dua-0')));
    await tester.pumpAndSettle();
    expect(h.store.saved!.openingDuaMs, 0);

    await tester.scrollUntilVisible(
      find.byKey(const Key('soft-glow')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const Key('soft-glow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('soft-glow')));
    await tester.pumpAndSettle();
    expect(h.store.saved!.softGlow, isTrue);
    expect(h.store.saved!.openingDuaMs, 0);
  });

  testWidgets('camera choice: back by default, front saved, with a note', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpScreen(tester, const SettingsPage());
    await tester.pumpAndSettle();
    final front = find.byKey(const Key('camera-front'));
    await tester.scrollUntilVisible(
      front,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Back camera (recommended)'), findsOneWidget);
    expect(find.text('Front camera'), findsOneWidget);
    expect(
      find.text(
        'The back camera sees better in dim rooms. The front camera lets '
        'you see yourself while placing the phone.',
      ),
      findsOneWidget,
    );
    final group = tester.widget<RadioGroup<CameraLens>>(
      find.byType(RadioGroup<CameraLens>),
    );
    expect(group.groupValue, CameraLens.rear);
    await tester.tap(front);
    await tester.pumpAndSettle();
    expect(h.store.saved!.camera, CameraLens.front);
    await tester.ensureVisible(find.byKey(const Key('camera-rear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('camera-rear')));
    await tester.pumpAndSettle();
    expect(h.store.saved!.camera, CameraLens.rear);
  });

  testWidgets('choosing surahs shows both rak\'ahs and a gentle order note', (
    tester,
  ) async {
    final h = Harness(
      settings: const SessionSettings(
        autoPairs: false,
        surahRakah1: 114,
        surahRakah2: 112,
      ),
    );
    await h.pumpScreen(tester, const SettingsPage());
    await tester.pumpAndSettle();
    expect(find.text('An-Nas (114)'), findsOneWidget);
    expect(find.text('Al-Ikhlas (112)'), findsOneWidget);
    expect(find.textContaining('comes later in the mushaf'), findsOneWidget);

    await tester.tap(find.byKey(const Key('surah-auto')));
    await tester.pumpAndSettle();
    expect(h.store.saved!.autoPairs, isTrue);
    expect(find.byKey(const Key('surah-rakah1')), findsNothing);
  });

  testWidgets('picking a rak\'ah 1 surah from the list persists it', (
    tester,
  ) async {
    final h = Harness(settings: const SessionSettings(autoPairs: false));
    await h.pumpScreen(tester, const SettingsPage());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('surah-rakah1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Al-Kawthar (108)').last);
    await tester.pumpAndSettle();
    expect(h.store.saved!.surahRakah1, 108);
    expect(h.store.saved!.surahRakah2, 94);
  });

  testWidgets('settings has semantics for controls', (tester) async {
    final handle = tester.ensureSemantics();
    final h = Harness();
    await h.pumpScreen(tester, const SettingsPage());
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('Auto')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Short')), findsOneWidget);
    handle.dispose();
  });
}
