/// Decoder for the native pose engine's EventChannel events.
///
/// The encoder is `android/app/src/main/kotlin/in/kukoo/salah_companion/pose/PoseWire.kt`;
/// both sides are tested against the same golden vectors.
///
/// Frames and heartbeats arrive as one Float32List:
///
/// | index | meaning                                                       |
/// | ----- | ------------------------------------------------------------- |
/// | 0     | kind: 0 = camera frame, 1 = heartbeat                         |
/// | 1     | session token (chosen by Dart in `start`, echoed back)        |
/// | 2, 3  | tMs = [2] * 65536 + [3] (each part exact in float32)          |
/// | 4, 5  | imageW, imageH of the upright frame                           |
/// | 6     | tiltDeg (phone roll relative to session start)                |
/// | 7     | N = number of people (0..3)                                   |
/// | 8..   | N x 33 landmarks x (x, y, z, conf)                            |
///
/// x, y are pixels of the upright, unmirrored frame; z is MediaPipe's z scaled by imageW;
/// conf is MediaPipe's per-landmark `visibility` (how likely the landmark is visible, not
/// hidden), which is what the classifier's 0.5 / 0.7 thresholds are meant for.
///
/// Errors and info arrive as maps: `{event: 'error' | 'started' | 'engine', token, ...}`.
library;

import 'dart:typed_data';

import 'package:salah_core/salah_core.dart';

abstract final class PoseWire {
  static const int kindFrame = 0;
  static const int kindHeartbeat = 1;
  static const int header = 8;
  static const int fields = 4;
  static const int personFloats = LandmarkIndex.count * fields;
  static const int maxPeople = 3;
}

/// One decoded event from the native engine.
sealed class PoseWireEvent {
  /// The session token the native side echoed.
  final int token;
  const PoseWireEvent(this.token);
}

/// A camera frame or a heartbeat.
final class PoseWireFrame extends PoseWireEvent {
  final PoseFrame frame;
  final bool isHeartbeat;
  const PoseWireFrame(super.token, this.frame, {required this.isHeartbeat});
}

/// The engine stopped because of [error].
final class PoseWireError extends PoseWireEvent {
  final PoseEngineError error;
  const PoseWireError(super.token, this.error);
}

/// Diagnostics (`started`: lens, fps range, analysis size; `engine`: delegate).
final class PoseWireInfo extends PoseWireEvent {
  final String event;
  final Map<String, Object?> data;
  const PoseWireInfo(super.token, this.event, this.data);
}

/// A native engine failure. Every code ends the session.
///
/// Codes: `permissionDenied`, `cameraInUse`, `cameraDisabled`, `cameraFatal`,
/// `cameraDoNotDisturb`, `cameraConfig`, `cameraUnavailable`, `noCamera`, `engineInit`,
/// `engineError` (all [Interruption.cameraUnavailable]) and `paused` (the activity was stopped,
/// i.e. no longer visible: [Interruption.appBackgrounded]).
class PoseEngineError implements Exception {
  final String code;
  final String message;

  const PoseEngineError(this.code, this.message);

  Interruption get interruption => code == 'paused'
      ? Interruption.appBackgrounded
      : Interruption.cameraUnavailable;

  @override
  String toString() => 'PoseEngineError($code: $message)';

  @override
  bool operator ==(Object other) =>
      other is PoseEngineError &&
      other.code == code &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, message);
}

abstract final class PoseWireDecoder {
  /// Decodes one EventChannel event. Throws [FormatException] if it is malformed.
  static PoseWireEvent decode(Object? event) {
    if (event is Float32List) return decodeFloats(event);
    if (event is Map) return _decodeMap(event);
    throw FormatException('Unexpected pose event type: ${event.runtimeType}');
  }

  static PoseWireFrame decodeFloats(Float32List d) {
    if (d.length < PoseWire.header) {
      throw FormatException('Pose event too short: ${d.length} floats');
    }
    final kind = _int(d[0], 'kind');
    final token = _int(d[1], 'token');
    final tMs = _int(d[2], 'tMs high') * 65536 + _int(d[3], 'tMs low');
    final w = _int(d[4], 'imageW');
    final h = _int(d[5], 'imageH');
    final tilt = d[6].toDouble();
    final n = _int(d[7], 'people');
    if (n < 0 || n > PoseWire.maxPeople) {
      throw FormatException('Bad person count $n');
    }
    if (d.length != PoseWire.header + n * PoseWire.personFloats) {
      throw FormatException(
        'Pose event has ${d.length} floats, expected ${PoseWire.header + n * PoseWire.personFloats}',
      );
    }
    switch (kind) {
      case PoseWire.kindHeartbeat:
        if (n != 0) throw const FormatException('Heartbeat with people');
        return PoseWireFrame(
          token,
          PoseFrame.heartbeat(tMs, imageW: w, imageH: h),
          isHeartbeat: true,
        );
      case PoseWire.kindFrame:
        final people = List<List<Landmark>>.generate(n, (p) {
          final base = PoseWire.header + p * PoseWire.personFloats;
          return List<Landmark>.generate(LandmarkIndex.count, (i) {
            final o = base + i * PoseWire.fields;
            return Landmark(d[o], d[o + 1], d[o + 2], d[o + 3]);
          }, growable: false);
        }, growable: false);
        return PoseWireFrame(
          token,
          PoseFrame(
            tMs: tMs,
            landmarks: people.length == 1 ? people.first : null,
            people: people,
            imageW: w,
            imageH: h,
            tiltDeg: tilt,
          ),
          isHeartbeat: false,
        );
      default:
        throw FormatException('Unknown pose event kind $kind');
    }
  }

  static PoseWireEvent _decodeMap(Map<Object?, Object?> m) {
    final event = m['event'];
    final token = m['token'];
    if (event is! String || token is! int) {
      throw FormatException('Bad pose map event: $m');
    }
    if (event == 'error') {
      return PoseWireError(
        token,
        PoseEngineError(
          (m['code'] as String?) ?? 'cameraUnavailable',
          (m['message'] as String?) ?? '',
        ),
      );
    }
    return PoseWireInfo(token, event, {
      for (final e in m.entries) '${e.key}': e.value,
    });
  }

  static int _int(double v, String what) {
    if (!v.isFinite || v != v.truncateToDouble()) {
      throw FormatException('$what is not an integer: $v');
    }
    return v.toInt();
  }
}
