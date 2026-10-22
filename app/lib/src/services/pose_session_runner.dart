/// The real [SessionRunner]: PoseEngine -> RuleBasedClassifier ->
/// MajoritySmoother -> SalahStateMachine (for the chosen [Prayer]) ->
/// SessionController ->
/// RecitationPlayer (docs/SPEC.md section 5).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:salah_core/salah_core.dart';

import '../pose/pose_wire.dart' show PoseEngineError;
import 'latest_value.dart';
import 'seams.dart';

/// A recitation player plus the system interruptions it reports
/// (headphones unplugged, audio focus lost) and, if it has any, the
/// playback errors it reports outside a call ([problems]; shown as
/// `SessionStatus.audioProblem`).
typedef PlayerHandle = ({
  RecitationPlayer player,
  Stream<Interruption> interruptions,
  Stream<Object>? problems,
});

/// Creates the player for one session (it is disposed when the session
/// ends).
typedef PlayerFactory = Future<PlayerHandle> Function();

/// [Interruption.appBackgrounded] whenever the app is hidden or paused (not
/// for `inactive`, which a notification shade or a system dialog causes).
Stream<Interruption> appLifecycleInterruptions() {
  AppLifecycleListener? listener;
  late final StreamController<Interruption> out;
  out = StreamController<Interruption>.broadcast(
    onListen: () {
      listener = AppLifecycleListener(
        onStateChange: (s) {
          if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) {
            out.add(Interruption.appBackgrounded);
          }
        },
      );
    },
    onCancel: () {
      listener?.dispose();
      listener = null;
    },
  );
  return out.stream;
}

/// Whether the app is visible (resumed or merely inactive) right now, from
/// the widgets binding. True when there is no binding (plain unit tests).
bool appIsVisibleNow() {
  try {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null ||
        s == AppLifecycleState.resumed ||
        s == AppLifecycleState.inactive;
  } catch (_) {
    return true;
  }
}

/// One prayer session on the real pipeline.
///
/// * Every engine output (camera frame or heartbeat) goes, in order, to the
///   controller's [FrameRateMonitor] (`frames:`) and then through the
///   classifier, smoother and state machine; the machine's events are
///   applied to the [SessionController] synchronously, as in the replay
///   harness.
/// * Interruptions: the player's system interruptions, pose engine errors
///   ([PoseEngineError.interruption]: camera unavailable, or app paused),
///   the app lifecycle ([lifecycleInterruptions]) and [cancel]
///   ([Interruption.userCancelled]). The engine stream closing by itself
///   counts as [Interruption.cameraUnavailable], and so does no engine
///   output at all within [firstFrameTimeout] of opening the camera (a
///   camera that never delivers a frame would otherwise leave a black
///   screen and the wakelock on forever).
/// * The lifecycle is watched from the start of [start], before any await,
///   and [isAppVisible] is checked once the camera is about to open, so the
///   app going to the background while the player is being created still
///   ends the session as [Interruption.appBackgrounded].
/// * [status] replays the latest status to late listeners.
/// * The state machine follows [prayer] (its rak'ah count and middle
///   sitting); the machine trusts that choice, so Home and the placement
///   screen make it obvious before the session starts.
/// * When the session ends [EndReason.completed], the controller's
///   `settingsAfterSession(clock())` is saved to [store] before the final
///   status is published: the Auto pair advances on the first completed
///   prayer of a new calendar day and then stays for the rest of that day.
/// * At the end the camera is released and the player is disposed.
/// * Audio errors are never silent: errors thrown by player calls and the
///   player's [PlayerHandle.problems] become `SessionStatus.audioProblem`
///   (and are logged); a player that cannot be created ends the session
///   with that problem.
/// * [diagnostics] is a cheap snapshot of the pipeline (posture, state,
///   takbir, the last recitation event and audio problem) for the optional
///   tracking details on the prayer screen.
class PoseSessionRunner implements SessionRunner, SessionDiagnosticsSource {
  final SessionSettings settings;

  /// The prayer the user chose; the state machine follows it.
  final Prayer prayer;
  final PoseEngine engine;
  final RecitationPlanner planner;
  final SettingsStore store;
  final PlayerFactory createPlayer;
  final Stream<Interruption> Function() lifecycleInterruptions;

  /// The camera to open; by default [SessionSettings.cameraConfig] (the
  /// user's camera setting, rear or front).
  final CameraConfig cameraConfig;

  /// Waited before the camera opens, so a placement preview that is being
  /// removed releases the camera first (one camera owner at a time).
  final Duration cameraHandoverDelay;

  /// How long to wait for the engine's first output after opening the
  /// camera before giving up with [Interruption.cameraUnavailable].
  final Duration firstFrameTimeout;

  /// Whether the app is in the foreground now (see [appIsVisibleNow]).
  final bool Function() isAppVisible;

  /// The phone's clock, for the daily Auto pair.
  final DateTime Function() clock;

  /// Pipeline modules (fresh per session unless given).
  final RuleBasedClassifier classifier;
  final MajoritySmoother smoother;
  final SalahStateMachine machine;

  final _status = LatestValue<SessionStatus>();
  final _frames = StreamController<PoseFrame>.broadcast(sync: true);
  final _interrupts = StreamController<Interruption>.broadcast(sync: true);
  final _finished = Completer<void>();
  final List<StreamSubscription<Object?>> _subs = [];

  SessionController? _controller;
  RecitationPlayer? _player;
  StreamSubscription<PoseFrame>? _frameSub;
  Timer? _firstFrameWatchdog;
  Interruption? _earlyInterruption;
  bool _started = false;
  bool _cancelRequested = false;
  bool _ending = false;

  // Diagnostics (see [diagnostics]).
  Posture _posture = Posture.unknown;
  Posture _rawPosture = Posture.unknown;
  bool _personSeen = false;
  bool _takbirSeen = false;
  String? _lastAudioEvent;

  PoseSessionRunner({
    required this.settings,
    this.prayer = Prayer.fajr,
    required this.engine,
    required this.planner,
    required this.store,
    required this.createPlayer,
    Stream<Interruption> Function()? lifecycleInterruptions,
    CameraConfig? cameraConfig,
    this.cameraHandoverDelay = const Duration(milliseconds: 300),
    this.firstFrameTimeout = const Duration(seconds: 5),
    this.isAppVisible = appIsVisibleNow,
    this.clock = DateTime.now,
    RuleBasedClassifier? classifier,
    MajoritySmoother? smoother,
    SalahStateMachine? machine,
  }) : lifecycleInterruptions =
           lifecycleInterruptions ?? appLifecycleInterruptions,
       cameraConfig = cameraConfig ?? settings.cameraConfig,
       classifier = classifier ?? RuleBasedClassifier(),
       smoother = smoother ?? MajoritySmoother(),
       machine = machine ?? SalahStateMachine(prayer: prayer) {
    assert(
      this.machine.prayer == prayer,
      'the state machine must follow the chosen prayer',
    );
    _status.add(const SessionStatus());
  }

  @override
  Stream<SessionStatus> get status => _status.stream;

  @override
  SessionDiagnostics get diagnostics {
    final s = _controller?.current ?? _status.latest ?? const SessionStatus();
    return SessionDiagnostics(
      posture: _posture,
      rawPosture: _rawPosture,
      personSeen: _personSeen,
      state: s.state,
      rakah: s.rakah,
      tracking: s.tracking,
      takbirSeen: _takbirSeen,
      lastAudioEvent: _lastAudioEvent,
      audioProblem: s.audioProblem,
      interruption: s.interruption,
    );
  }

  /// The controller, once [start] created it (for tests and diagnostics).
  @visibleForTesting
  SessionController? get controller => _controller;

  /// Completes after the session ended and everything was released.
  Future<void> get finished => _finished.future;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (_cancelRequested) return;

    // Subscribed before the first await, so backgrounding while the player
    // is being created is not missed. Until the controller listens, the
    // first interruption is kept and delivered once it does.
    _subs.add(
      lifecycleInterruptions().listen((i) {
        if (_controller == null) {
          _earlyInterruption ??= i;
        } else {
          _interrupts.add(i);
        }
      }),
    );

    final PlayerHandle handle;
    try {
      handle = await createPlayer();
    } catch (e) {
      debugPrint('PoseSessionRunner: no player: $e');
      await _finishWithout(
        Interruption.audioFocusLost,
        audioProblem:
            'Could not start the audio player: '
            '${describeAudioProblem(e)}',
      );
      return;
    }
    _player = handle.player;
    if (_cancelRequested || _ending) {
      await _finishWithout(Interruption.userCancelled);
      return;
    }

    classifier.reset();
    smoother.reset();
    machine.reset();
    final controller = SessionController(
      handle.player,
      planner,
      settings,
      _interrupts.stream,
      frames: _frames.stream,
    );
    _controller = controller;
    _subs.add(controller.status.listen(_onStatus));
    _subs.add(handle.interruptions.listen(_interrupts.add));
    final problems = handle.problems;
    if (problems != null) {
      _subs.add(
        problems.listen((e) {
          debugPrint('PoseSessionRunner: audio problem: $e');
          controller.reportAudioProblem(e);
        }),
      );
    }
    final early = _earlyInterruption;
    if (early != null) {
      _interrupts.add(early);
      if (controller.isOver) return;
    }

    if (cameraHandoverDelay > Duration.zero) {
      await Future<void>.delayed(cameraHandoverDelay);
    }
    if (controller.isOver) return;
    if (!isAppVisible()) {
      _interrupts.add(Interruption.appBackgrounded);
      return;
    }

    _frameSub = engine
        .start(cameraConfig)
        .listen(
          _onFrame,
          onError: (Object e) {
            final i = e is PoseEngineError
                ? e.interruption
                : Interruption.cameraUnavailable;
            debugPrint('PoseSessionRunner: engine error $e');
            _interrupts.add(i);
          },
          onDone: () {
            if (!controller.isOver) {
              _interrupts.add(Interruption.cameraUnavailable);
            }
          },
        );
    _firstFrameWatchdog = Timer(firstFrameTimeout, () {
      if (!controller.isOver) {
        debugPrint('PoseSessionRunner: no camera frame in $firstFrameTimeout');
        _interrupts.add(Interruption.cameraUnavailable);
      }
    });
  }

  void _onFrame(PoseFrame f) {
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    final c = _controller;
    if (c == null || c.isOver) return;
    _frames.add(f); // FrameRateMonitor first (synchronous).
    if (c.isOver) return;
    final raw = classifier.classify(f);
    final smoothed = smoother.add(raw);
    _personSeen = f.hasPerson;
    _rawPosture = raw.posture;
    _posture = smoothed.posture;
    if (raw.takbirRaise || smoothed.takbirRaise) _takbirSeen = true;
    final events = machine.add(smoothed);
    for (final e in events) {
      if (e is StateChanged && e.to == PrayerState.takbir) _takbirSeen = true;
      c.handle(e);
      _noteAudioEvent(e, c);
      if (c.isOver) break;
    }
  }

  void _noteAudioEvent(PrayerEvent e, SessionController c) {
    final rakah = c.current.rakah;
    final ignored = c.current.reciting ? '' : ', not played';
    _lastAudioEvent = switch (e) {
      StartRecitation(:final rakah) => "Start (rak'ah $rakah$ignored)",
      PauseRecitation(:final rakah) => "Pause (rak'ah $rakah)",
      ResumeRecitation(:final rakah) => "Resume (rak'ah $rakah)",
      StopRecitation() => "Stop (rak'ah $rakah)",
      _ => _lastAudioEvent,
    };
  }

  void _onStatus(SessionStatus s) {
    if (s.audioProblem != null &&
        s.audioProblem != _status.latest?.audioProblem) {
      debugPrint('PoseSessionRunner: audio problem: ${s.audioProblem}');
    }
    if (s.isOver) {
      unawaited(_finish(s));
    } else if (!_ending) {
      _status.add(s);
    }
  }

  Future<void> _finish(SessionStatus last) async {
    if (_ending) return;
    _ending = true;
    final c = _controller;
    if (c != null && last.ended == EndReason.completed) {
      try {
        await store.save(c.settingsAfterSession(clock()));
      } catch (e) {
        debugPrint('PoseSessionRunner: could not save settings: $e');
      }
    }
    _status.add(last);
    await _release();
  }

  /// Ends a session that never reached the controller.
  Future<void> _finishWithout(Interruption i, {String? audioProblem}) async {
    if (_ending) return;
    _ending = true;
    _status.add(
      _status.latest!.copyWith(
        ended: i == Interruption.cameraUnavailable
            ? EndReason.cameraLost
            : EndReason.cancelled,
        interruption: i,
        reciting: false,
        paused: false,
        audioProblem: audioProblem,
      ),
    );
    await _release();
  }

  Future<void> _release() async {
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    final frameSub = _frameSub;
    _frameSub = null;
    try {
      await frameSub?.cancel();
      await engine.stop();
    } catch (e) {
      debugPrint('PoseSessionRunner: stopping the camera: $e');
    }
    final c = _controller;
    if (c != null) {
      // Let the final fade-out run, but never hang on a stuck player.
      await c.idle.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await c?.dispose();
    try {
      _player?.dispose();
    } catch (e) {
      debugPrint('PoseSessionRunner: disposing the player: $e');
    }
    _player = null;
    await _frames.close();
    await _interrupts.close();
    if (!_finished.isCompleted) _finished.complete();
  }

  @override
  Future<void> cancel() async {
    if (_ending) return _finished.future;
    _cancelRequested = true;
    final c = _controller;
    if (c == null) {
      // Not started yet, or still creating the player: start() notices.
      if (!_started) await _finishWithout(Interruption.userCancelled);
      return;
    }
    c.interrupt(Interruption.userCancelled);
    await _finished.future;
  }
}
