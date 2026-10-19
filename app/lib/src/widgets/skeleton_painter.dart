import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

/// Draws the detected skeleton over the camera preview. Points are in pixels
/// of the upright camera frame and are mapped like `BoxFit.contain`, matching
/// the Android preview (CameraX `PreviewView` in `FIT_CENTER`), which shows
/// the whole camera frame so the user can judge the space around them.
class SkeletonPainter extends CustomPainter {
  final List<Landmark>? points;
  final int imageW;
  final int imageH;
  final Color color;
  final double minConf;

  SkeletonPainter({
    required this.points,
    required this.imageW,
    required this.imageH,
    this.color = const Color(0xFFE8D9A8),
    this.minConf = 0.5,
  });

  static const bones = <(int, int)>[
    (LandmarkIndex.leftShoulder, LandmarkIndex.rightShoulder),
    (LandmarkIndex.leftHip, LandmarkIndex.rightHip),
    (LandmarkIndex.leftShoulder, LandmarkIndex.leftHip),
    (LandmarkIndex.rightShoulder, LandmarkIndex.rightHip),
    (LandmarkIndex.leftShoulder, LandmarkIndex.leftElbow),
    (LandmarkIndex.leftElbow, LandmarkIndex.leftWrist),
    (LandmarkIndex.rightShoulder, LandmarkIndex.rightElbow),
    (LandmarkIndex.rightElbow, LandmarkIndex.rightWrist),
    (LandmarkIndex.leftHip, LandmarkIndex.leftKnee),
    (LandmarkIndex.leftKnee, LandmarkIndex.leftAnkle),
    (LandmarkIndex.rightHip, LandmarkIndex.rightKnee),
    (LandmarkIndex.rightKnee, LandmarkIndex.rightAnkle),
    (LandmarkIndex.leftAnkle, LandmarkIndex.leftHeel),
    (LandmarkIndex.leftHeel, LandmarkIndex.leftFootIndex),
    (LandmarkIndex.rightAnkle, LandmarkIndex.rightHeel),
    (LandmarkIndex.rightHeel, LandmarkIndex.rightFootIndex),
    (LandmarkIndex.leftEar, LandmarkIndex.leftShoulder),
    (LandmarkIndex.rightEar, LandmarkIndex.rightShoulder),
  ];

  /// Maps a frame pixel to canvas coordinates (contain fit, centred).
  static Offset map(Landmark p, Size size, int imageW, int imageH) {
    final scale = math.min(size.width / imageW, size.height / imageH);
    final dx = (size.width - imageW * scale) / 2;
    final dy = (size.height - imageH * scale) / 2;
    return Offset(p.x * scale + dx, p.y * scale + dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pts = points;
    if (pts == null || imageW <= 0 || imageH <= 0) return;
    final line = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..color = color;
    bool ok(int i) => i < pts.length && pts[i].conf >= minConf;
    for (final (a, b) in bones) {
      if (ok(a) && ok(b)) {
        canvas.drawLine(
          map(pts[a], size, imageW, imageH),
          map(pts[b], size, imageW, imageH),
          line,
        );
      }
    }
    for (var i = 0; i < pts.length; i++) {
      if (ok(i)) canvas.drawCircle(map(pts[i], size, imageW, imageH), 4, dot);
    }
  }

  @override
  bool shouldRepaint(SkeletonPainter old) =>
      !identical(old.points, points) ||
      old.imageW != imageW ||
      old.imageH != imageH ||
      old.color != color;
}
