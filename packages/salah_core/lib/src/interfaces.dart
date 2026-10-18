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
abstract interface class PrayerStateMachine {
  Stream<PrayerEvent> run(Stream<PostureReading> smoothed);
}

abstract interface class RecitationPlayer {
  /// Completes when playback ends or is cancelled.
  Future<void> play(RecitationPlan plan);

  /// Fades to silence over [duration]; also cancels a pending pre-roll.
  Future<void> fadeOut({Duration duration = const Duration(milliseconds: 300)});

  Future<void> stopNow();

  void dispose();
}
