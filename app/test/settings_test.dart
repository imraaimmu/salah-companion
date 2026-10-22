import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/screens/settings_page.dart';
import 'package:salah_companion/src/services/fakes.dart';
import 'package:salah_companion/src/services/seams.dart';
import 'package:salah_companion/src/services/sound_test.dart';
import 'package:salah_companion/src/widgets/settings_controls.dart';
import 'package:salah_core/salah_core.dart';
import 'package:salah_core/testing.dart';

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

  group('test sound', () {
    const clip = AyahClip(
      assetPath: 'assets/audio/placeholder/001001.wav',
      surah: 1,
      ayah: 1,
      duration: Duration(seconds: 3),
    );

    RecitationSoundTest soundTestWith(
      RecitationPlayer player, {
      Stream<Object>? problems,
    }) => RecitationSoundTest(
      createPlayer: () async => (
        player: player,
        interruptions: const Stream<Interruption>.empty(),
        problems: problems,
      ),
      clip: clip,
      placeholder: true,
    );

    Future<void> tapTestSound(WidgetTester tester, Harness h) async {
      await h.pumpScreen(tester, const SettingsPage());
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('test-sound'));
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();
      await tester.pump();
    }

    String statusText(WidgetTester tester) => tester
        .widget<QuietNote>(find.byKey(const Key('test-sound-status')))
        .text;

    testWidgets('plays Al-Fatiha 1:1 through the player, then says a tone', (
      tester,
    ) async {
      final player = FakeRecitationPlayer();
      final h = Harness(soundTest: soundTestWith(player));
      await tapTestSound(tester, h);
      expect(statusText(tester), 'Playing…');
      expect(player.plays.single.clips.single.assetPath, clip.assetPath);
      expect(player.plays.single.preRoll, Duration.zero);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(statusText(tester), 'You should hear a tone (placeholder audio).');
      expect(player.kinds, [
        PlayerCallKind.play,
        PlayerCallKind.fadeOut,
        PlayerCallKind.dispose,
      ]);
      expect(player.disposed, isTrue);
      expect(find.byKey(const Key('test-sound-volume')), findsNothing);
    });

    testWidgets('a failing player shows the error text', (tester) async {
      final h = Harness(soundTest: soundTestWith(_FailingPlayer()));
      await tapTestSound(tester, h);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        statusText(tester),
        'No sound: Unable to open asset flutter_assets/x.wav',
      );
    });

    testWidgets('a problem the player reports later is shown too', (
      tester,
    ) async {
      final problems = StreamController<Object>.broadcast();
      final h = Harness(
        soundTest: soundTestWith(
          FakeRecitationPlayer(),
          problems: problems.stream,
        ),
      );
      await tapTestSound(tester, h);
      problems.add(Exception('Source error (0)'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(statusText(tester), 'No sound: Source error (0)');
    });

    testWidgets('a player that cannot be created is reported', (tester) async {
      final h = Harness(
        soundTest: RecitationSoundTest(
          createPlayer: () async => throw StateError('no audio session'),
          clip: clip,
          placeholder: true,
        ),
      );
      await tapTestSound(tester, h);
      await tester.pumpAndSettle();
      expect(
        statusText(tester),
        'No sound: Could not start the audio player: '
        'Bad state: no audio session',
      );
    });

    testWidgets('says when the media volume is at zero', (tester) async {
      final fake = FakeSoundTest()..gate = Completer<void>();
      final h = Harness(
        soundTest: fake,
        audio: const AudioStatus(volumeAboveZero: false),
      );
      await tapTestSound(tester, h);
      expect(statusText(tester), 'Playing…');
      expect(
        find.text(
          'Media volume is at zero, so nothing can be heard. Turn it up.',
        ),
        findsOneWidget,
      );
      // The button is disabled while playing.
      await tester.tap(find.byKey(const Key('test-sound')));
      fake.gate!.complete();
      await tester.pumpAndSettle();
      expect(fake.runs, 1);
      expect(statusText(tester), 'You should hear a tone (placeholder audio).');
    });
  });

  testWidgets('tracking details switch: off by default, saved when on', (
    tester,
  ) async {
    final h = Harness();
    await h.pumpScreen(tester, const SettingsPage());
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('tracking-details'));
    await tester.scrollUntilVisible(
      toggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Show tracking details during prayer (for testing)'),
      findsOneWidget,
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(h.store.saved!.showTrackingDetails, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });
}

class _FailingPlayer extends FakeRecitationPlayer {
  @override
  Future<void> play(RecitationPlan plan) async {
    throw Exception('Unable to open asset flutter_assets/x.wav');
  }
}
