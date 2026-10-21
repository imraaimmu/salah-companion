/// Demo mode (`--dart-define=DEMO=true`, and any non-Android platform):
/// scripted fakes stand in for the camera, pose engine and session
/// controller. Surah names and today's pair come from the real content
/// manifest. Settings are kept in memory and the screen
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
    DateTime Function()? clock,
  }) => AppServices(
    settingsStore: settingsStore ?? MemorySettingsStore(),
    surahNames: surahNames ?? const ManifestSurahNames(),
    todaysSurahs: todaysSurahs ?? manifestTodaysSurahs,
    sessionRunnerFactory: sessionRunnerFactory ?? DemoSessionRunner.new,
    placementCheckFactory: placementCheckFactory ?? DemoPlacementCheck.new,
    prompter: prompter ?? SilentPrompter(),
    audioCheck: audioCheck ?? FakeAudioCheck(),
    cameraPermission: cameraPermission ?? FakeCameraPermission(granted: false),
    screenControl: screenControl ?? const DeviceScreenControl(),
    clock: clock ?? DateTime.now,
    child: child,
  );
}

/// Walks through a session of the chosen prayer on a timer (about 20 s per
/// rak'ah), losing tracking briefly in rak'ah 2 so the amber dot can be
/// seen.
class DemoSessionRunner implements SessionRunner {
  final SessionSettings settings;
  final Prayer prayer;
  final _status = LatestValue<SessionStatus>();
  final List<Timer> _timers = [];
  bool _started = false;

  DemoSessionRunner(this.settings, [this.prayer = Prayer.fajr]) {
    _status.add(const SessionStatus());
  }

  /// The scripted statuses for [prayer], as (ms after start, status).
  static List<(int, SessionStatus)> scriptFor(Prayer prayer) {
    final out = <(int, SessionStatus)>[];
    var t = 2000;
    void at(int dt, SessionStatus s) {
      t += dt;
      out.add((t, s));
    }

    out.add((t, const SessionStatus(state: PrayerState.takbir, rakah: 1)));
    for (var r = 1; r <= prayer.rakahCount; r++) {
      at(
        r == 1 ? 1000 : 0,
        SessionStatus(state: PrayerState.qiyam, rakah: r, reciting: true),
      );
      if (r == 2) {
        at(
          3000,
          const SessionStatus(
            state: PrayerState.qiyam,
            rakah: 2,
            tracking: false,
            paused: true,
          ),
        );
        at(
          1000,
          const SessionStatus(
            state: PrayerState.qiyam,
            rakah: 2,
            reciting: true,
          ),
        );
      }
      at(
        prayer.hasSurah(r) ? 8000 : 5000,
        SessionStatus(state: PrayerState.ruku, rakah: r),
      );
      at(3000, SessionStatus(state: PrayerState.itidal, rakah: r));
      at(2000, SessionStatus(state: PrayerState.sujood, rakah: r));
      if (r == 2 && prayer.hasMiddleSitting) {
        at(
          4000,
          const SessionStatus(state: PrayerState.middleSitting, rakah: 2),
        );
      }
      if (r < prayer.rakahCount) t += 5000;
    }
    at(
      4000,
      SessionStatus(state: PrayerState.finalSitting, rakah: prayer.rakahCount),
    );
    at(
      6000,
      SessionStatus(
        state: PrayerState.done,
        rakah: prayer.rakahCount,
        ended: EndReason.completed,
      ),
    );
    return out;
  }

  @override
  Stream<SessionStatus> get status => _status.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final (ms, s) in scriptFor(prayer)) {
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

  CameraLens _lens = CameraLens.rear;

  @override
  Future<void> start({CameraLens lens = CameraLens.rear}) async {
    _lens = lens;
    final skel = standingSkeleton();
    void at(int ms, PlacementState s) => _timers.add(
      Timer(
        Duration(milliseconds: ms),
        () => _state.add(s.copyWith(lens: _lens)),
      ),
    );
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
  Future<void> switchLens(CameraLens lens) async {
    _lens = lens;
    await stop();
    _timers.clear();
    _state.add(PlacementState(fpsOk: true, lens: lens));
    await start(lens: lens);
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
