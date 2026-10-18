/// Pose input types. See docs/SPEC.md, section "Technical architecture".
library;

/// One body landmark.
///
/// [x] and [y] are pixels in the upright (rotated, unmirrored) camera frame.
/// [z] is depth relative to the hips (engine units, rarely used).
/// [conf] is the engine's confidence for this landmark, mapped to 0..1.
class Landmark {
  final double x;
  final double y;
  final double z;
  final double conf;

  const Landmark(this.x, this.y, this.z, this.conf);

  @override
  String toString() => 'Landmark($x, $y, $z, conf: $conf)';
}

/// Indices of the 33 MediaPipe / BlazePose landmarks.
abstract final class LandmarkIndex {
  static const int count = 33;

  static const int nose = 0;
  static const int leftEye = 2;
  static const int rightEye = 5;
  static const int leftEar = 7;
  static const int rightEar = 8;
  static const int leftShoulder = 11;
  static const int rightShoulder = 12;
  static const int leftElbow = 13;
  static const int rightElbow = 14;
  static const int leftWrist = 15;
  static const int rightWrist = 16;
  static const int leftHip = 23;
  static const int rightHip = 24;
  static const int leftKnee = 25;
  static const int rightKnee = 26;
  static const int leftAnkle = 27;
  static const int rightAnkle = 28;
  static const int leftHeel = 29;
  static const int rightHeel = 30;
  static const int leftFootIndex = 31;
  static const int rightFootIndex = 32;
}

/// One camera frame's worth of pose data, or a heartbeat.
class PoseFrame {
  /// Camera sensor timestamp minus session start, in milliseconds.
  /// The prayer logic never reads wall-clock time.
  final int tMs;

  /// The selected person's 33 landmarks, or null for a heartbeat or when no
  /// person is detected.
  final List<Landmark>? landmarks;

  /// Landmarks of every detected person (up to 3), for person selection.
  /// Empty when the engine reports a single person in [landmarks].
  final List<List<Landmark>> people;

  final int imageW;
  final int imageH;

  /// Phone roll relative to the tilt recorded at session start, in degrees.
  final double tiltDeg;

  const PoseFrame({
    required this.tMs,
    required this.landmarks,
    this.people = const [],
    required this.imageW,
    required this.imageH,
    this.tiltDeg = 0,
  });

  /// A frame with no person, used as a 100 ms heartbeat so timeouts still fire.
  const PoseFrame.heartbeat(this.tMs, {this.imageW = 0, this.imageH = 0})
      : landmarks = null,
        people = const [],
        tiltDeg = 0;

  bool get hasPerson => landmarks != null;
}

enum CameraLens { rear, rearUltraWide, front }

class CameraConfig {
  final int width;
  final int height;
  final int fps;
  final CameraLens lens;

  const CameraConfig({
    this.width = 480,
    this.height = 640,
    this.fps = 15,
    this.lens = CameraLens.rear,
  });
}
