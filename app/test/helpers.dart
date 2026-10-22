import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/main.dart';
import 'package:salah_companion/src/services/app_services.dart';
import 'package:salah_companion/src/services/fakes.dart';
import 'package:salah_companion/src/services/seams.dart';
import 'package:salah_companion/src/services/settings_stores.dart';
import 'package:salah_core/salah_core.dart';

/// All fakes for one test, plus helpers to pump the app or a single screen.
class Harness {
  final MemorySettingsStore store;
  final FakePlacementCheck placement = FakePlacementCheck();
  final List<FakeSessionRunner> runners = [];
  final SilentPrompter prompter = SilentPrompter();
  final FakeAudioCheck audio;
  final FakeCameraPermission camera = FakeCameraPermission();
  final FakeScreenControl screen = FakeScreenControl();
  final SoundTest soundTest;

  /// The phone's clock; Fajr time by default. Tests may move it.
  DateTime now;

  Harness({
    SessionSettings? settings,
    bool setupDone = true,
    AudioStatus audio = const AudioStatus(),
    DateTime? now,
    SoundTest? soundTest,
  }) : now = now ?? DateTime(2026, 10, 20, 5, 30),
       soundTest = soundTest ?? FakeSoundTest(),
       store = MemorySettingsStore(initial: settings, setupDone: setupDone),
       audio = FakeAudioCheck(audio);

  FakeSessionRunner get runner => runners.single;

  Widget wrap(Widget child) => AppServices(
    settingsStore: store,
    surahNames: const PilotSurahNames(),
    todaysSurahs: draftTodaysSurahs,
    sessionRunnerFactory: (s, p) {
      final r = FakeSessionRunner(s, p);
      runners.add(r);
      return r;
    },
    placementCheckFactory: () => placement,
    prompter: prompter,
    audioCheck: audio,
    cameraPermission: camera,
    screenControl: screen,
    soundTest: soundTest,
    clock: () => now,
    child: child,
  );

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(wrap(const SalahCompanionApp()));
    await tester.pumpAndSettle();
  }

  /// Pumps [screen] as the second route above a stub home, so pops and
  /// `popUntil(isFirst)` can be observed.
  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen, {
    TextDirection textDirection = TextDirection.ltr,
    double textScale = 1,
  }) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      wrap(
        MaterialApp(
          navigatorKey: navKey,
          builder: (context, child) => Directionality(
            textDirection: textDirection,
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
          home: const Scaffold(body: Center(child: Text('stub-home'))),
        ),
      ),
    );
    navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => screen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

const allPass = PlacementState(
  bodyVisible: true,
  confidenceOk: true,
  fpsOk: true,
  floorSpaceOk: true,
);
