/// Module interfaces. See docs/SPEC.md, section "Technical architecture".
///
/// Data flows one way: PoseEngine -> PostureClassifier -> PostureSmoother ->
/// PrayerStateMachine -> SessionController -> RecitationPlayer.
library;

import 'dart:async';

import 'pose.dart';
import 'posture.dart';
import 'prayer.dart';
import 'recitation.dart';

abstract interface class PoseEngine {
  Stream<PoseFrame> start(CameraConfig config);
  Future<void> stop();
}

/// Classifies one frame. Stateful implementations (side lock, calibration,
/// takbir detection) must be reset per session.
abstract interface class PostureClassifier {
  PostureReading classify(PoseFrame frame);
  void reset();
}

/// Majority vote and hysteresis only. No hold times: those live only in the
/// state machine.
abstract interface class PostureSmoother {
  Stream<PostureReading> smooth(Stream<PostureReading> raw);
}

/// Owns every hold time and timeout. Never reads wall-clock time.
///
/// The events it emits must be applied to the player strictly in order (a
/// [StopRecitation] after a [ResumeRecitation] must win). An implementation
/// never emits a [ResumeRecitation] together with a later [StopRecitation]
/// for the same reading: it emits only the stop.
abstract interface class PrayerStateMachine {
  Stream<PrayerEvent> run(Stream<PostureReading> smoothed);
}

abstract interface class RecitationPlayer {
  /// Completes when playback ends or is cancelled.
  Future<void> play(RecitationPlan plan);

  /// Fades to silence over [duration]; also cancels a pending pre-roll.
  Future<void> fadeOut({Duration duration = const Duration(milliseconds: 300)});

  /// Pauses the current recitation (a blind spot): fades out over 300 ms and
  /// remembers the position at the start of the ayah that was playing (or
  /// the remaining pre-roll or gap, if paused there). Does nothing when
  /// nothing is playing or it is already paused.
  Future<void> pause();

  /// Resumes a paused recitation: fades back in from the start of the ayah
  /// remembered by [pause], so no words are skipped. Continues the same
  /// recitation; it never restarts it from the first ayah. Does nothing when
  /// not paused (e.g. after [fadeOut] or [stopNow]).
  Future<void> resume();

  Future<void> stopNow();

  void dispose();
}
