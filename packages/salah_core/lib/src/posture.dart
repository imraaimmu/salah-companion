/// Posture types. See docs/SPEC.md, section "Pose detection and classification".
library;

enum Posture { standing, bowing, prostrating, sitting, unknown }

/// The classifier's reading for one frame.
class PostureReading {
  final int tMs;
  final Posture posture;

  /// 0..1.
  final double confidence;

  /// True on the frame where a takbir hand raise completed. Detected before
  /// smoothing and passed through the smoother untouched.
  final bool takbirRaise;

  /// Hip height relative to the calibrated standing value (1.0 = standing),
  /// or null before calibration or when the hips or feet are not visible.
  final double? hipHeightRatio;

  /// Torso angle from vertical in degrees, or null when not visible.
  final double? torsoAngleDeg;

  const PostureReading({
    required this.tMs,
    required this.posture,
    required this.confidence,
    this.takbirRaise = false,
    this.hipHeightRatio,
    this.torsoAngleDeg,
  });

  /// A reading for a frame with no usable person.
  const PostureReading.unknown(this.tMs)
      : posture = Posture.unknown,
        confidence = 0,
        takbirRaise = false,
        hipHeightRatio = null,
        torsoAngleDeg = null;

  PostureReading copyWith({
    int? tMs,
    Posture? posture,
    double? confidence,
    bool? takbirRaise,
  }) =>
      PostureReading(
        tMs: tMs ?? this.tMs,
        posture: posture ?? this.posture,
        confidence: confidence ?? this.confidence,
        takbirRaise: takbirRaise ?? this.takbirRaise,
        hipHeightRatio: hipHeightRatio,
        torsoAngleDeg: torsoAngleDeg,
      );

  @override
  bool operator ==(Object other) =>
      other is PostureReading &&
      other.tMs == tMs &&
      other.posture == posture &&
      other.confidence == confidence &&
      other.takbirRaise == takbirRaise &&
      other.hipHeightRatio == hipHeightRatio &&
      other.torsoAngleDeg == torsoAngleDeg;

  @override
  int get hashCode => Object.hash(
      tMs, posture, confidence, takbirRaise, hipHeightRatio, torsoAngleDeg);

  @override
  String toString() =>
      'PostureReading($tMs ms, $posture, ${confidence.toStringAsFixed(2)}'
      '${takbirRaise ? ', takbir' : ''})';
}
