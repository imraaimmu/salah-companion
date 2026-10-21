/// A [RecitationPlayer] that plays nothing and records every call.
library;

import 'dart:async';

import '../interfaces.dart';
import '../recitation.dart';
import '../scheduler.dart';

enum PlayerCallKind { play, pause, resume, fadeOut, stopNow, dispose }

/// One call to a [FakeRecitationPlayer].
class PlayerCall {
  final PlayerCallKind kind;

  /// [FakeRecitationPlayer.clock] when the call was made.
  final Duration at;

  /// The plan, for [PlayerCallKind.play].
  final RecitationPlan? plan;

  /// The fade length, for [PlayerCallKind.fadeOut].
  final Duration? fade;

  /// Whether the call changed anything (e.g. false for [pause] when nothing
  /// was playing, or [resume] when not paused), per the interface docs.
  final bool effective;

  const PlayerCall(this.kind, this.at,
      {this.plan, this.fade, this.effective = true});

  @override
  String toString() => '${kind.name}@${at.inMilliseconds}ms'
      '${effective ? '' : ' (no-op)'}';
}

/// The fake's playback state.
enum FakePlayerState { idle, playing, paused }

/// Records calls with timestamps and follows the [RecitationPlayer]
/// contract's state rules (pause only while playing, resume only while
/// paused, fadeOut and stopNow end the recitation), without audio.
///
/// * [play] returns a future that completes when the recitation is ended by
///   [fadeOut], [stopNow], a new [play], [dispose], or [finish] (playback
///   ending naturally). A new [play] while one is open ends the old one.
/// * [pause], [resume], [fadeOut] and [stopNow] complete after [opDelay]
///   (zero by default: on the next event-loop turn), which simulates the
///   300 ms fades, so tests can check that the caller serializes its calls:
///   [overlaps] counts calls made while an earlier one was still running.
/// * [clock] stamps each call; by default the time since construction.
///   Tests can stamp prayer time instead, e.g. `clock: () => now`.
///
/// [position] tracks where in the plan the recitation is, using
/// [RecitationScheduler.resumePointFor] on pause, when [clock] moves.
class FakeRecitationPlayer implements RecitationPlayer {
  final Duration Function() clock;

  /// How long [pause], [resume], [fadeOut] and [stopNow] take.
  Duration opDelay;

  final List<PlayerCall> calls = [];

  /// Calls made while a previous [pause], [resume], [fadeOut] or [stopNow]
  /// had not completed.
  int overlaps = 0;

  FakePlayerState _state = FakePlayerState.idle;
  RecitationPlan? _plan;
  RecitationScheduler? _sched;
  Completer<void>? _done;
  int _busy = 0;
  bool _disposed = false;

  // Position bookkeeping: plan offset at [_anchorClock] while playing.
  Duration _anchorPos = Duration.zero;
  Duration _anchorClock = Duration.zero;

  FakeRecitationPlayer(
      {Duration Function()? clock, this.opDelay = Duration.zero})
      : clock = clock ?? _stopwatchClock();

  static Duration Function() _stopwatchClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  FakePlayerState get state => _state;
  bool get isPlaying => _state == FakePlayerState.playing;
  bool get isPaused => _state == FakePlayerState.paused;
  bool get disposed => _disposed;

  /// The plan of the open recitation (playing or paused), or null.
  RecitationPlan? get currentPlan => _plan;

  /// Every plan passed to [play], in order.
  List<RecitationPlan> get plays => [
        for (final c in calls)
          if (c.kind == PlayerCallKind.play) c.plan!,
      ];

  /// The kinds of the calls, in order.
  List<PlayerCallKind> get kinds => [for (final c in calls) c.kind];

  /// Calls of [kind].
  Iterable<PlayerCall> callsOf(PlayerCallKind kind) =>
      calls.where((c) => c.kind == kind);

  /// Offset into the open plan: where the audio is (playing) or where it
  /// will resume from (paused); null when idle.
  Duration? get position => switch (_state) {
        FakePlayerState.idle => null,
        FakePlayerState.paused => _anchorPos,
        FakePlayerState.playing => _anchorPos + (clock() - _anchorClock),
      };

  void _record(PlayerCallKind kind,
      {RecitationPlan? plan, Duration? fade, bool effective = true}) {
    if (_busy > 0) overlaps++;
    calls.add(PlayerCall(kind, clock(),
        plan: plan, fade: fade, effective: effective));
  }

  void _end() {
    _state = FakePlayerState.idle;
    _plan = null;
    _sched = null;
    final d = _done;
    _done = null;
    if (d != null && !d.isCompleted) d.complete();
  }

  Future<void> _op() async {
    _busy++;
    try {
      await Future<void>.delayed(opDelay);
    } finally {
      _busy--;
    }
  }

  @override
  Future<void> play(RecitationPlan plan) {
    _checkNotDisposed();
    _record(PlayerCallKind.play, plan: plan);
    _end();
    _state = FakePlayerState.playing;
    _plan = plan;
    _sched = RecitationScheduler(plan);
    _anchorPos = Duration.zero;
    _anchorClock = clock();
    final d = _done = Completer<void>();
    return d.future;
  }

  /// Ends the open recitation as if its last ayah finished.
  void finish() => _end();

  @override
  Future<void> pause() {
    _checkNotDisposed();
    final effective = _state == FakePlayerState.playing;
    _record(PlayerCallKind.pause, effective: effective);
    if (effective) {
      final now = clock();
      final at = _anchorPos + (now - _anchorClock);
      _anchorPos = _sched!.resumePointFor(at);
      _state = FakePlayerState.paused;
    }
    return _op();
  }

  @override
  Future<void> resume() {
    _checkNotDisposed();
    final effective = _state == FakePlayerState.paused;
    _record(PlayerCallKind.resume, effective: effective);
    if (effective) {
      _anchorClock = clock();
      _state = FakePlayerState.playing;
    }
    return _op();
  }

  @override
  Future<void> fadeOut(
      {Duration duration = const Duration(milliseconds: 300)}) {
    _checkNotDisposed();
    _record(PlayerCallKind.fadeOut,
        fade: duration, effective: _state != FakePlayerState.idle);
    _end();
    return _op();
  }

  @override
  Future<void> stopNow() {
    _checkNotDisposed();
    _record(PlayerCallKind.stopNow, effective: _state != FakePlayerState.idle);
    _end();
    return _op();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _record(PlayerCallKind.dispose);
    _end();
    _disposed = true;
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('FakeRecitationPlayer used after dispose');
  }
}
