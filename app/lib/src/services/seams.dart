/// Small abstract seams between the UI and the modules other workstreams
/// build in parallel (SessionController #15, audio #16, content #17 and the
/// Android PoseEngine). The UI depends only on these; [AppServices] carries
/// one implementation of each down the widget tree.
///
/// Integration later means writing a thin adapter per seam and passing it to
/// [AppServices] in main.dart instead of the demo fakes.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:salah_core/salah_core.dart';

/// One prayer session. Implemented by an adapter over SessionController.
abstract interface class SessionRunner {
  /// Status updates. A late listener should receive the latest status first.
  /// The UI leaves the prayer screen when a status with `isOver` arrives.
  Stream<SessionStatus> get status;

  /// Starts the session (camera, pose, state machine, audio). Called once,
  /// when the prayer screen opens after the placement countdown.
  Future<void> start();

  /// Ends the session (user long-pressed to end, or pressed Back). Should
  /// emit a final status with `ended: EndReason.cancelled`. Idempotent.
  Future<void> cancel();
}

/// Creates the session for one Start tap: [prayer] is the prayer the user
/// chose on Home (the state machine follows its rak'ah count).
typedef SessionRunnerFactory = SessionRunner Function(
  SessionSettings settings,
  Prayer prayer,
);

/// Result of the live placement check (docs/SPEC.md "Placing the phone").
class PlacementState {
  /// A person is in frame.
  final bool bodyVisible;

  /// Near-side shoulder, hip, knee and ankle average conf >= 0.7 for 3 s.
  final bool confidenceOk;

  /// Camera delivers >= 15 fps for 3 s.
  final bool fpsOk;

  /// Floor space in front of the user for sujood.
  final bool floorSpaceOk;

  /// The one prompt to show and speak ("Move the phone back"). When null the
  /// UI derives one from the first failing check.
  final String? message;

  /// Landmarks of the detected person for the overlay, in pixels of the
  /// upright camera frame of [imageW] x [imageH]. Null when nobody is seen.
  final List<Landmark>? skeleton;
  final int imageW;
  final int imageH;

  /// The camera actually in use (the engine falls back to the other one if
  /// the phone lacks the requested lens). [skeleton] is always unmirrored;
  /// the overlay mirrors it for display only when this is
  /// [CameraLens.front], because the front preview is shown mirrored.
  final CameraLens lens;

  const PlacementState({
    this.bodyVisible = false,
    this.confidenceOk = false,
    this.fpsOk = false,
    this.floorSpaceOk = false,
    this.message,
    this.skeleton,
    this.imageW = 480,
    this.imageH = 640,
    this.lens = CameraLens.rear,
  });

  bool get allPass => bodyVisible && confidenceOk && fpsOk && floorSpaceOk;

  PlacementState copyWith({
    bool? bodyVisible,
    bool? confidenceOk,
    bool? fpsOk,
    bool? floorSpaceOk,
    String? message,
    List<Landmark>? skeleton,
    CameraLens? lens,
  }) => PlacementState(
    bodyVisible: bodyVisible ?? this.bodyVisible,
    confidenceOk: confidenceOk ?? this.confidenceOk,
    fpsOk: fpsOk ?? this.fpsOk,
    floorSpaceOk: floorSpaceOk ?? this.floorSpaceOk,
    message: message ?? this.message,
    skeleton: skeleton ?? this.skeleton,
    imageW: imageW,
    imageH: imageH,
    lens: lens ?? this.lens,
  );
}

/// The live placement check. Implemented by the Android PoseEngine side.
abstract interface class PlacementCheck {
  /// Check results. A late listener should receive the latest state first.
  Stream<PlacementState> get state;

  /// Opens [lens] (the user's camera setting) and starts checking.
  Future<void> start({CameraLens lens = CameraLens.rear});

  /// Switches to [lens] while checking: the camera and its preview restart
  /// and the checks start over. Before [start] it only sets the lens.
  Future<void> switchLens(CameraLens lens);

  /// Releases the camera (before the session takes it over).
  Future<void> stop();

  /// The full-screen camera preview, or null to show a placeholder. The
  /// skeleton overlay is drawn on top, mapped like `BoxFit.contain` (the
  /// whole camera frame, letterboxed and centred).
  Widget? buildPreview(BuildContext context);
}

typedef PlacementCheckFactory = PlacementCheck Function();

/// Persists settings on the phone only.
abstract interface class SettingsStore {
  Future<SessionSettings> load();
  Future<void> save(SessionSettings settings);

  /// Whether first-run setup has been completed.
  Future<bool> isSetupDone();
  Future<void> markSetupDone();
}

/// Surah display names. Implemented by the content repository (#17).
abstract interface class SurahNames {
  /// The pilot surahs, in mushaf order.
  List<int> get available;

  /// Transliterated name, e.g. 93 -> "Ad-Duha".
  String nameOf(int surah);
}

/// Which surahs a session with these settings will recite. In production:
/// `RecitationPlanner.surahsFor`.
typedef TodaysSurahs = (int, int) Function(SessionSettings settings);

/// Spoken placement guidance. No TTS dependency yet; a no-op is fine.
abstract interface class Prompter {
  Future<void> speak(String text);
}

/// Media output state, for the audio check (docs/SPEC.md setup step 6).
class AudioStatus {
  final bool volumeAboveZero;
  final bool bluetooth;
  const AudioStatus({this.volumeAboveZero = true, this.bluetooth = false});
}

abstract interface class AudioCheck {
  Future<AudioStatus> check();
}

abstract interface class CameraPermission {
  Future<bool> isGranted();

  /// Shows the system prompt; returns whether it was granted.
  Future<bool> request();
}

/// Keeps the screen awake and dim during the prayer.
abstract interface class ScreenControl {
  Future<void> enterPrayerMode();
  Future<void> exitPrayerMode();
}

/// A snapshot of what the session pipeline sees, for the optional tracking
/// details on the prayer screen (Settings, "Show tracking details during
/// prayer"). Text only; nothing is recorded or stored.
class SessionDiagnostics {
  /// The smoothed posture (what the state machine acts on).
  final Posture posture;

  /// The classifier's raw posture for the latest frame.
  final Posture rawPosture;

  /// Whether a person is in the latest frame.
  final bool personSeen;
  final PrayerState state;
  final int rakah;
  final bool tracking;

  /// Whether a takbir hand raise was detected in this session (rak'ah 1
  /// recites only after one).
  final bool takbirSeen;

  /// The latest recitation event, e.g. "Start (rak'ah 1)", or null.
  final String? lastAudioEvent;

  /// The latest audio problem in words, or null.
  final String? audioProblem;

  /// The latest interruption, or null.
  final Interruption? interruption;

  const SessionDiagnostics({
    this.posture = Posture.unknown,
    this.rawPosture = Posture.unknown,
    this.personSeen = false,
    this.state = PrayerState.waiting,
    this.rakah = 0,
    this.tracking = true,
    this.takbirSeen = false,
    this.lastAudioEvent,
    this.audioProblem,
    this.interruption,
  });

  /// The lines shown on the prayer screen.
  List<String> get lines => [
    'Posture: ${posture.name} (raw ${rawPosture.name})'
        '${personSeen ? '' : ', no person'}',
    'State: ${state.name}, rak\'ah $rakah'
        '${tracking ? '' : ', tracking lost'}',
    'Takbir seen: ${takbirSeen ? 'yes' : 'no'}',
    'Audio: ${lastAudioEvent ?? 'no event yet'}',
    if (interruption != null) 'Interruption: ${interruption!.name}',
    if (audioProblem != null) 'Audio problem: $audioProblem',
  ];
}

/// A session that can report [SessionDiagnostics]. The prayer screen polls
/// [diagnostics] (at most 4 times a second) only when the user turned the
/// tracking details on.
abstract interface class SessionDiagnosticsSource {
  SessionDiagnostics get diagnostics;
}

/// Settings, "Test sound": plays a short sample through the same recitation
/// player, audio backend and audio session configuration as a prayer.
abstract interface class SoundTest {
  /// Whether the bundled audio is placeholder tones (no recitation yet).
  bool get placeholder;

  /// Plays the sample for a few seconds. Completes with null when it played
  /// without any reported error, or with the problem in words.
  Future<String?> run();
}

/// A [SoundTest] for builds without real audio (demo mode).
class UnavailableSoundTest implements SoundTest {
  const UnavailableSoundTest();

  @override
  bool get placeholder => true;

  @override
  Future<String?> run() async => 'Sound test is not available in demo mode.';
}
