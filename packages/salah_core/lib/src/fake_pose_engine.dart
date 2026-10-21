/// A [PoseEngine] that replays a [Recording] (#6): for tests (immediate) and
/// the app's demo mode ([FakePoseEngine.realTime]).
library;

import 'dart:async';

import 'interfaces.dart';
import 'pose.dart';
import 'recording.dart';
import 'replay.dart';

/// Replays a [Recording] with its original sensor timestamps, inserting
/// heartbeats by the engine's rule (docs/SPEC.md section 5) via
/// [withHeartbeats], exactly as the replay harness does.
///
/// * Immediate (default): every frame is emitted as fast as the listener
///   takes them (one per event-loop turn), for tests.
/// * [realTime]: frame (or heartbeat) `i` is emitted [Duration] `(tMs_i -
///   tMs_0) / speed` after [start] is listened to, measured with a
///   [Stopwatch] so timer lateness never accumulates. For the demo mode.
///
/// [CameraConfig] is ignored (the recording fixes size and rate). The stream
/// is single-subscription and closes after the last frame. Calling [start]
/// again stops the previous replay first. Pausing the subscription pauses
/// an immediate replay; a real-time replay keeps its clock and catches up.
class FakePoseEngine implements PoseEngine {
  final Recording recording;
  final bool realTime;

  /// Real-time playback rate (2.0 = twice as fast). Ignored when immediate.
  final double speed;

  /// Gap after which heartbeats are inserted, and their period.
  final int heartbeatMs;

  /// Insert heartbeats (the real engine always does).
  final bool heartbeats;

  StreamController<PoseFrame>? _ctrl;
  Timer? _timer;
  bool _running = false;

  FakePoseEngine(
    this.recording, {
    this.realTime = false,
    this.speed = 1.0,
    this.heartbeatMs = defaultHeartbeatMs,
    this.heartbeats = true,
  }) {
    if (!(speed > 0)) throw ArgumentError.value(speed, 'speed', 'must be > 0');
    if (heartbeatMs <= 0) {
      throw ArgumentError.value(heartbeatMs, 'heartbeatMs', 'must be positive');
    }
  }

  /// True between [start] and the end of the replay or [stop].
  bool get running => _running;

  /// The frames [start] emits, in order (heartbeats included).
  Iterable<PoseFrame> get frames => heartbeats
      ? withHeartbeats(recording, heartbeatMs: heartbeatMs).map((e) => e.frame)
      : recording.frames;

  @override
  Stream<PoseFrame> start([CameraConfig config = const CameraConfig()]) {
    _close();
    late final StreamController<PoseFrame> ctrl;
    final it = frames.iterator;
    ctrl = StreamController<PoseFrame>(
      onListen: () =>
          realTime ? _runRealTime(ctrl, it) : _runImmediate(ctrl, it),
      onResume: () {
        if (!realTime) _runImmediate(ctrl, it);
      },
      onCancel: () {
        if (identical(_ctrl, ctrl)) _close();
      },
    );
    _ctrl = ctrl;
    _running = true;
    return ctrl.stream;
  }

  void _runImmediate(StreamController<PoseFrame> ctrl, Iterator<PoseFrame> it) {
    _timer?.cancel();
    void step() {
      if (!identical(_ctrl, ctrl) || ctrl.isPaused) return;
      if (!it.moveNext()) {
        _close();
        return;
      }
      ctrl.add(it.current);
      _timer = Timer(Duration.zero, step);
    }

    _timer = Timer(Duration.zero, step);
  }

  void _runRealTime(StreamController<PoseFrame> ctrl, Iterator<PoseFrame> it) {
    final clock = Stopwatch()..start();
    int? t0;
    PoseFrame? pending;
    void step() {
      if (!identical(_ctrl, ctrl)) return;
      while (true) {
        if (pending == null) {
          if (!it.moveNext()) {
            _close();
            return;
          }
          pending = it.current;
          t0 ??= pending!.tMs;
        }
        final dueUs = ((pending!.tMs - t0!) * 1000 / speed).round();
        final waitUs = dueUs - clock.elapsedMicroseconds;
        if (waitUs > 0) {
          _timer = Timer(Duration(microseconds: waitUs), step);
          return;
        }
        ctrl.add(pending!);
        pending = null;
      }
    }

    step();
  }

  void _close() {
    _timer?.cancel();
    _timer = null;
    final c = _ctrl;
    _ctrl = null;
    _running = false;
    if (c != null && !c.isClosed) c.close();
  }

  @override
  Future<void> stop() async => _close();
}
