/// Demo mode (`--dart-define=DEMO=true`, and any non-Android platform):
/// scripted fakes stand in for the camera, pose engine and session
/// controller. Surah names and today's pair come from the real content
/// manifest. Settings persist for real (shared_preferences) and the screen
/// really stays awake and dims.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:salah_core/salah_core.dart';

import 'app_services.dart';
import 'content_services.dart';
import 'fakes.dart';
import 'screen_control.dart';
import 'seams.dart';
import 'settings_stores.dart';

abstract final class DemoServices {
  /// Wraps [child] in [AppServices] backed by demo implementations. Any
  /// seam can be overridden, which is how real modules get swapped in one
  /// at a time during integration.
  static AppServices wrap({
    required Widget child,
    SettingsStore? settingsStore,
    SurahNames? surahNames,
    TodaysSurahs? todaysSurahs,
    SessionRunnerFactory? sessionRunnerFactory,
    PlacementCheckFactory? placementCheckFactory,
    Prompter? prompter,
    AudioCheck? audioCheck,
    CameraPermission? cameraPermission,
    ScreenControl? screenControl,
  }) => AppServices(
    settingsStore: settingsStore ?? SharedPrefsSettingsStore(),
    surahNames: surahNames ?? const ManifestSurahNames(),
    todaysSurahs: todaysSurahs ?? manifestTodaysSurahs,
    sessionRunnerFactory: sessionRunnerFactory ?? DemoSessionRunner.new,
    placementCheckFactory: placementCheckFactory ?? DemoPlacementCheck.new,
    prompter: prompter ?? SilentPrompter(),
    audioCheck: audioCheck ?? FakeAudioCheck(),
    cameraPermission: cameraPermission ?? FakeCameraPermission(granted: false),
    screenControl: screenControl ?? const DeviceScreenControl(),
    child: child,
  );
}

/// Walks through a Fajr session on a timer (about 40 s), losing tracking
/// briefly in rak'ah 2 so the amber dot can be seen.
class DemoSessionRunner implements SessionRunner {
  final SessionSettings settings;
  final _status = LatestValue<SessionStatus>();
  final List<Timer> _timers = [];
  bool _started = false;

  DemoSessionRunner(this.settings) {
    _status.add(const SessionStatus());
  }

  static const _script = <(int, SessionStatus)>[
    (2000, SessionStatus(state: PrayerState.takbir, rakah: 1)),
    (3000, SessionStatus(state: PrayerState.qiyam1, rakah: 1, reciting: true)),
    (12000, SessionStatus(state: PrayerState.ruku1, rakah: 1)),
    (15000, SessionStatus(state: PrayerState.itidal1, rakah: 1)),
    (17000, SessionStatus(state: PrayerState.sujood1, rakah: 1)),
    (22000, SessionStatus(state: PrayerState.qiyam2, rakah: 2, reciting: true)),
    (
      25000,
      SessionStatus(
        state: PrayerState.qiyam2,
        rakah: 2,
        reciting: false,
        tracking: false,
        paused: true,
      ),
    ),
    (26000, SessionStatus(state: PrayerState.qiyam2, rakah: 2, reciting: true)),
    (30000, SessionStatus(state: PrayerState.ruku2, rakah: 2)),
    (32000, SessionStatus(state: PrayerState.itidal2, rakah: 2)),
    (34000, SessionStatus(state: PrayerState.sujood2, rakah: 2)),
    (38000, SessionStatus(state: PrayerState.finalSitting, rakah: 2)),
    (
      44000,
      SessionStatus(
        state: PrayerState.done,
        rakah: 2,
        ended: EndReason.completed,
      ),
    ),
  ];

  @override
  Stream<SessionStatus> get status => _status.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final (ms, s) in _script) {
      _timers.add(
        Timer(Duration(milliseconds: ms), () {
          if (!_status.latest!.isOver) _status.add(s);
        }),
      );
    }
  }

  @override
  Future<void> cancel() async {
    for (final t in _timers) {
      t.cancel();
    }
    final cur = _status.latest!;
    if (!cur.isOver) {
      _status.add(
        cur.copyWith(
          ended: EndReason.cancelled,
          interruption: Interruption.userCancelled,
          reciting: false,
        ),
      );
    }
  }
}

/// Pretends the user adjusts the phone: nobody, then too close, then all
/// checks pass after a few seconds.
class DemoPlacementCheck implements PlacementCheck {
  final _state = LatestValue<PlacementState>();
  final List<Timer> _timers = [];

  DemoPlacementCheck() {
    _state.add(const PlacementState(fpsOk: true));
  }

  @override
  Stream<PlacementState> get state => _state.stream;

  @override
  Future<void> start() async {
    final skel = standingSkeleton();
    void at(int ms, PlacementState s) =>
        _timers.add(Timer(Duration(milliseconds: ms), () => _state.add(s)));
    at(
      1500,
      PlacementState(
        bodyVisible: true,
        fpsOk: true,
        skeleton: standingSkeleton(conf: 0.5),
        message: 'Move the phone back',
      ),
    );
    at(
      4000,
      PlacementState(
        bodyVisible: true,
        fpsOk: true,
        confidenceOk: true,
        skeleton: skel,
      ),
    );
    at(
      5500,
      PlacementState(
        bodyVisible: true,
        fpsOk: true,
        confidenceOk: true,
        floorSpaceOk: true,
        skeleton: skel,
      ),
    );
  }

  @override
  Future<void> stop() async {
    for (final t in _timers) {
      t.cancel();
    }
  }

  @override
  Widget? buildPreview(BuildContext context) => null;
}
