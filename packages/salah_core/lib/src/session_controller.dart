/// Turns prayer events and outside interruptions into playback (#15). See
/// docs/SPEC.md sections 3 (During the prayer), 4 (Rules), 5 (Modules) and
/// 8 (Edge cases).
library;

import 'dart:async';
import 'dart:collection';

import 'interfaces.dart';
import 'pose.dart';
import 'prayer.dart';
import 'recitation.dart';
import 'session.dart';

/// [problem] in words for [SessionStatus.audioProblem]: its `toString()`,
/// without a leading "Exception: ", shortened to 300 characters.
String describeAudioProblem(Object problem) {
  var text = problem.toString().trim();
  if (text.startsWith('Exception: ')) text = text.substring(11);
  if (text.isEmpty) text = problem.runtimeType.toString();
  return text.length > 300 ? '${text.substring(0, 299)}…' : text;
}

/// A change reported by [FrameRateMonitor].
enum FrameRateChange { low, recovered }

/// The spec's rule "below 10 fps for 5 s counts as lost tracking"
/// (docs/SPEC.md section 8), measured on camera frame timestamps only.
///
/// The frame rate is the number of camera frames in the last [windowMs] of
/// sensor time, `(t - windowMs, t]`. It is *low* once at least [windowMs] of
/// sensor time has passed since the first input and that window holds fewer
/// than `minFps * windowMs / 1000` frames (49 or fewer at the defaults: a
/// steady 10 fps is not low). It *recovers* when the window holds enough
/// frames again. Heartbeats move the clock (so a stalled camera is noticed)
/// but never count as frames.
///
/// [add] tells heartbeats from camera frames by the heartbeat rule
/// (docs/SPEC.md section 5): a frame with no person stamped a positive
/// multiple of [heartbeatMs] after the last camera frame is a heartbeat. A
/// real no-person camera frame landing exactly on such a stamp (possible
/// only after a gap of 100 ms or more) is taken for a heartbeat, which can
/// only lower the measured rate, erring toward silence. Callers that know
/// which is which use [addCameraFrame] and [tick].
class FrameRateMonitor {
  final double minFps;
  final int windowMs;
  final int heartbeatMs;

  final Queue<int> _frames = Queue<int>();
  int? _firstMs;
  int? _lastFrameMs;
  int _nowMs = 0;
  bool _low = false;

  FrameRateMonitor(
      {this.minFps = 10, this.windowMs = 5000, this.heartbeatMs = 100}) {
    if (!(minFps > 0)) {
      throw ArgumentError.value(minFps, 'minFps', 'must be > 0');
    }
    if (windowMs <= 0) {
      throw ArgumentError.value(windowMs, 'windowMs', 'must be positive');
    }
    if (heartbeatMs <= 0) {
      throw ArgumentError.value(heartbeatMs, 'heartbeatMs', 'must be positive');
    }
  }

  /// Camera frames needed in one window.
  int get requiredFrames => (minFps * windowMs / 1000).ceil();

  /// True while the frame rate is low.
  bool get low => _low;

  /// Camera frames in the current window.
  int get framesInWindow => _frames.length;

  void reset() {
    _frames.clear();
    _firstMs = null;
    _lastFrameMs = null;
    _nowMs = 0;
    _low = false;
  }

  /// Adds one engine output (camera frame or heartbeat, see the class docs).
  FrameRateChange? add(PoseFrame f) {
    final last = _lastFrameMs;
    final isHeartbeat = !f.hasPerson &&
        last != null &&
        f.tMs > last &&
        (f.tMs - last) % heartbeatMs == 0;
    return isHeartbeat ? tick(f.tMs) : addCameraFrame(f.tMs);
  }

  /// Adds a camera frame at sensor time [tMs].
  FrameRateChange? addCameraFrame(int tMs) {
    tMs = _advance(tMs);
    _frames.addLast(tMs);
    _lastFrameMs = tMs;
    return _evaluate();
  }

  /// Moves the clock to [tMs] without a frame (a heartbeat).
  FrameRateChange? tick(int tMs) {
    _advance(tMs);
    return _evaluate();
  }

  int _advance(int tMs) {
    _firstMs ??= tMs;
    if (tMs < _nowMs) tMs = _nowMs; // out of order: clamp
    _nowMs = tMs;
    while (_frames.isNotEmpty && _frames.first <= tMs - windowMs) {
      _frames.removeFirst();
    }
    return tMs;
  }

  FrameRateChange? _evaluate() {
    if (_nowMs - _firstMs! < windowMs) return null;
    final enough = _frames.length >= requiredFrames;
    if (!_low && !enough) {
      _low = true;
      return FrameRateChange.low;
    }
    if (_low && enough) {
      _low = false;
      return FrameRateChange.recovered;
    }
    return null;
  }

  /// Emits [Interruption.lowFrameRate] each time the rate becomes low.
  Stream<Interruption> watch(Stream<PoseFrame> frames) async* {
    reset();
    await for (final f in frames) {
      if (add(f) == FrameRateChange.low) yield Interruption.lowFrameRate;
    }
  }
}

/// Runs one session: applies [PrayerEvent]s and [Interruption]s to a
/// [RecitationPlayer] and reports a [SessionStatus] for the UI.
///
/// ## Events (strictly in order, [handle] is synchronous)
///
/// * [StartRecitation] `r`: `player.play(planner.planFor(r, settings))`,
///   without waiting for it to finish. At most once per rak'ah per session,
///   however often the event repeats; never while tracking is lost (the
///   machine's [TrackingLost] or a low frame rate), after the headphones
///   were unplugged, or after the session ended. A start ignored this way
///   still uses up that rak'ah (missing a recitation is acceptable, playing
///   one late is not).
/// * [PauseRecitation] `r`: `pause()`, only while rak'ah `r`'s recitation
///   plays.
/// * [ResumeRecitation] `r`: `resume()`, only while rak'ah `r`'s recitation
///   is paused and tracking is good. Never after a stop.
/// * [StopRecitation]: `fadeOut()` (always, so a pending pre-roll is
///   cancelled too); the open recitation, playing or paused, is over.
/// * [TrackingLost] / [TrackingRestored]: `status.tracking`. A recitation
///   still open at [TrackingLost] (the machine stops it first) is faded out.
/// * [StateChanged]: `status.state` and `status.rakah`.
/// * [SessionEnded]: `fadeOut()` and `status.ended`.
///
/// ## Interruptions
///
/// Each calls `stopNow()` at once, without waiting behind a player call
/// that is still running (a resume ramp or a fade would otherwise keep the
/// audio going for another 0.3-0.5 s after a cancel, backgrounding or low
/// frame rate). Player calls queued but not yet started are dropped, later
/// calls wait for the stop, and the open recitation ends for good (no
/// resume):
///
/// * [Interruption.phoneCall], [Interruption.appBackgrounded],
///   [Interruption.audioFocusLost], [Interruption.userCancelled]: the
///   session ends with [EndReason.cancelled].
/// * [Interruption.cameraUnavailable]: ends with [EndReason.cameraLost].
/// * [Interruption.headphonesUnplugged]: the session continues, but no audio
///   plays again in it: the output would now be the speaker, and the app
///   never switches to the speaker (the controller cannot see the route).
/// * [Interruption.lowFrameRate]: lost tracking (`status.tracking` false)
///   until the rate recovers ([frameRateRecovered], or the built-in
///   [FrameRateMonitor] when constructed with `frames`).
///
/// ## Player calls
///
/// Calls are serialized: each starts only after the previous one completed,
/// so a `fadeOut` after a `resume` can never be overtaken by it. `play` is
/// the exception: it counts as done once called (its future completes only
/// when the recitation ends). The interruption `stopNow` is the other: it
/// runs immediately, overlapping a running call (the player's contract lets
/// `stopNow` win over any call in progress). [idle] completes when the
/// queue is empty and that stop has completed.
///
/// The controller never disposes the player; the owner does.
class SessionController {
  final RecitationPlayer player;
  final RecitationPlanner planner;
  final SessionSettings settings;

  /// Built-in frame-rate monitor, when constructed with `frames`.
  final FrameRateMonitor? frameRate;

  /// Errors thrown by the planner or the player, and problems reported with
  /// [reportAudioProblem]. The session goes on, but each one also sets
  /// [SessionStatus.audioProblem], so a failure is never silent.
  final List<Object> errors = [];

  final StreamController<SessionStatus> _statusCtrl =
      StreamController<SessionStatus>.broadcast();
  SessionStatus _status = const SessionStatus();

  StreamSubscription<Interruption>? _interruptSub;
  StreamSubscription<PoseFrame>? _framesSub;

  final Set<int> _used = {};
  int? _openRakah;
  bool _paused = false;
  int _playToken = 0;
  bool _machineTracking = true;
  bool _lowFps = false;
  bool _audioBlocked = false;

  Future<void> _tail = Future<void>.value();
  int _gen = 0;

  SessionController(
    this.player,
    this.planner,
    this.settings,
    Stream<Interruption> interruptions, {
    Stream<PoseFrame>? frames,
    FrameRateMonitor? frameRateMonitor,
  }) : frameRate =
            frames == null ? null : (frameRateMonitor ?? FrameRateMonitor()) {
    _interruptSub = interruptions.listen(interrupt);
    final m = frameRate;
    if (frames != null && m != null) {
      m.reset();
      _framesSub = frames.listen((f) {
        switch (m.add(f)) {
          case FrameRateChange.low:
            interrupt(Interruption.lowFrameRate);
          case FrameRateChange.recovered:
            frameRateRecovered();
          case null:
            break;
        }
      });
    }
  }

  /// Status changes (only real changes are emitted). Closes after the
  /// status that ends the session, or on [dispose].
  Stream<SessionStatus> get status => _statusCtrl.stream;

  /// The latest status.
  SessionStatus get current => _status;

  bool get isOver => _status.isOver;

  /// Completes when every player call queued so far has completed.
  Future<void> get idle => _tail;

  /// The settings to save after this session: only if the session ended
  /// [EndReason.completed], `settings.forDay(day)` ([day] defaults to now),
  /// so the Auto pair advances at most once per calendar day (on the first
  /// completed prayer of a new day) and stays the same for the rest of it.
  /// Otherwise [settings] unchanged.
  SessionSettings settingsAfterSession([DateTime? day]) =>
      _status.ended == EndReason.completed
          ? settings.forDay(day ?? DateTime.now())
          : settings;

  /// Applies [events] in order until the session ends (then stops
  /// listening), and waits for the player calls.
  Future<void> run(Stream<PrayerEvent> events) async {
    await for (final e in events) {
      handle(e);
      if (isOver) break;
    }
    await idle;
  }

  /// Applies one event. Ignored after the session ended.
  void handle(PrayerEvent e) {
    if (isOver) return;
    switch (e) {
      case StartRecitation(:final rakah):
        _start(rakah);
      case PauseRecitation(:final rakah):
        if (_openRakah == rakah && !_paused) {
          _paused = true;
          _enqueue(player.pause);
          _emit(_status.copyWith(paused: true));
        }
      case ResumeRecitation(:final rakah):
        if (_openRakah == rakah && _paused && _trackingOk && !_audioBlocked) {
          _paused = false;
          _enqueue(player.resume);
          _emit(_status.copyWith(paused: false));
        }
      case StopRecitation():
        _closeRecitation();
        _enqueue(player.fadeOut);
        _emit(_status.copyWith(reciting: false, paused: false));
      case TrackingLost():
        _machineTracking = false;
        if (_openRakah != null) {
          _closeRecitation();
          _enqueue(player.fadeOut);
        }
        _emit(
            _status.copyWith(tracking: false, reciting: false, paused: false));
      case TrackingRestored():
        _machineTracking = true;
        _emit(_status.copyWith(tracking: _trackingOk));
      case StateChanged(:final to, :final rakah):
        _emit(_status.copyWith(state: to, rakah: rakah));
      case SessionEnded(:final reason):
        _closeRecitation();
        _enqueue(player.fadeOut);
        _end(reason);
    }
  }

  /// Applies an interruption (also fed from the constructor's stream).
  /// Ignored after the session ended.
  void interrupt(Interruption i) {
    if (isOver) return;
    _closeRecitation();
    _gen++; // drop queued calls that have not started
    _stopNowImmediately();
    var s = _status.copyWith(reciting: false, paused: false, interruption: i);
    switch (i) {
      case Interruption.headphonesUnplugged:
        _audioBlocked = true;
      case Interruption.lowFrameRate:
        _lowFps = true;
        s = s.copyWith(tracking: false);
      case Interruption.phoneCall:
      case Interruption.appBackgrounded:
      case Interruption.audioFocusLost:
      case Interruption.userCancelled:
        _emit(s);
        _end(EndReason.cancelled);
        return;
      case Interruption.cameraUnavailable:
        _emit(s);
        _end(EndReason.cameraLost);
        return;
    }
    _emit(s);
  }

  /// The frame rate is good again after [Interruption.lowFrameRate]:
  /// tracking is back unless the state machine reports it lost. A recitation
  /// stopped by the low frame rate stays stopped.
  void frameRateRecovered() {
    if (isOver || !_lowFps) return;
    _lowFps = false;
    _emit(_status.copyWith(tracking: _trackingOk));
  }

  /// Stops listening to the interruptions and frames and closes [status].
  /// Does not touch the player.
  Future<void> dispose() async {
    await _interruptSub?.cancel();
    await _framesSub?.cancel();
    _interruptSub = null;
    _framesSub = null;
    if (!_statusCtrl.isClosed) await _statusCtrl.close();
  }

  /// Reports an audio problem that did not come from a player call (for
  /// example an asynchronous playback error from the platform player): it
  /// is added to [errors] and shown as [SessionStatus.audioProblem]. The
  /// session goes on. Ignored after the session ended.
  void reportAudioProblem(Object problem) => _recordError(problem);

  void _recordError(Object e) {
    errors.add(e);
    if (isOver) return;
    _emit(_status.copyWith(audioProblem: describeAudioProblem(e)));
  }

  bool get _trackingOk => _machineTracking && !_lowFps;

  void _start(int rakah) {
    if (!_used.add(rakah)) return; // never play twice per rak'ah
    if (!_trackingOk || _audioBlocked) return;
    final RecitationPlan plan;
    try {
      plan = planner.planFor(rakah, settings);
    } catch (e) {
      _recordError(e);
      return;
    }
    if (_openRakah != null) _enqueue(player.fadeOut); // defensive
    _openRakah = rakah;
    _paused = false;
    final token = ++_playToken;
    _enqueue(() {
      player.play(plan).then((_) => _playEnded(token), onError: (Object e) {
        _recordError(e);
        _playEnded(token);
      });
      return Future<void>.value();
    });
    _emit(_status.copyWith(reciting: true, paused: false));
  }

  void _playEnded(int token) {
    if (token != _playToken || _openRakah == null) return;
    _closeRecitation();
    if (!isOver) _emit(_status.copyWith(reciting: false, paused: false));
  }

  void _closeRecitation() {
    _openRakah = null;
    _paused = false;
    _playToken++;
  }

  void _end(EndReason reason) {
    _emit(_status.copyWith(ended: reason, reciting: false, paused: false));
    _interruptSub?.cancel();
    _framesSub?.cancel();
    _interruptSub = null;
    _framesSub = null;
    _statusCtrl.close();
  }

  /// Calls `player.stopNow()` now, not behind the queue; errors go to
  /// [errors]. Calls queued after this wait for it (and for the call that
  /// was running).
  void _stopNowImmediately() {
    Future<void> stop;
    try {
      stop = player.stopNow().then((_) {}, onError: (Object e) {
        _recordError(e);
      });
    } catch (e) {
      _recordError(e);
      stop = Future<void>.value();
    }
    _tail = Future.wait([_tail, stop]).then((_) {});
  }

  void _enqueue(Future<void> Function() call) {
    final gen = _gen;
    _tail = _tail.then((_) async {
      if (gen != _gen) return;
      try {
        await call();
      } catch (e) {
        _recordError(e);
      }
    });
  }

  void _emit(SessionStatus s) {
    final o = _status;
    if (s.state == o.state &&
        s.rakah == o.rakah &&
        s.tracking == o.tracking &&
        s.reciting == o.reciting &&
        s.paused == o.paused &&
        s.ended == o.ended &&
        s.interruption == o.interruption &&
        s.audioProblem == o.audioProblem) {
      return;
    }
    _status = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }
}
