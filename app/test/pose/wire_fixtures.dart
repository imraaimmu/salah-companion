import 'dart:typed_data';

import 'package:salah_companion/src/pose/pose_wire.dart';
import 'package:salah_core/salah_core.dart';

/// Builds a frame buffer the way PoseWire.kt does.
Float32List frameBuffer({
  int kind = 0,
  int token = 1,
  int tMs = 0,
  int w = 480,
  int h = 640,
  double tilt = 0,
  List<List<double>> people = const [],
}) {
  final d = Float32List(
    PoseWire.header + people.length * PoseWire.personFloats,
  );
  d[0] = kind.toDouble();
  d[1] = token.toDouble();
  d[2] = (tMs ~/ 65536).toDouble();
  d[3] = (tMs % 65536).toDouble();
  d[4] = w.toDouble();
  d[5] = h.toDouble();
  d[6] = tilt;
  d[7] = people.length.toDouble();
  for (var p = 0; p < people.length; p++) {
    d.setAll(PoseWire.header + p * PoseWire.personFloats, people[p]);
  }
  return d;
}

/// Landmark i = (i + seed, 2i + seed, -i/100, conf).
List<double> person(double seed, {double conf = 0.9}) => [
  for (var i = 0; i < LandmarkIndex.count; i++) ...[
    i + seed,
    2.0 * i + seed,
    -i / 100,
    conf,
  ],
];
