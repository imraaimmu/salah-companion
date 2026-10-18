/// Posture smoothing. See docs/SPEC.md, section "Pose detection and
/// classification" -> "Smoothing and confirmation".
///
/// Majority vote over a sliding time window plus hysteresis. No hold times:
/// those live only in the state machine.
library;

import 'dart:collection';

import 'interfaces.dart';
import 'posture.dart';

/// Majority-vote smoother with hysteresis.
///
/// ## Voting
///
/// The window is the last [windowMs] milliseconds of sensor time, ending at
/// the current reading's `tMs` (never earlier than the first reading after a
/// [reset]). Votes are weighted by **time** and by **confidence**:
///
/// * Each reading covers the time since the previous reading, capped at
///   [maxSpanMs] (the nominal heartbeat period). So a burst of frames counts
///   for no more than the milliseconds it actually spans, and irregular frame
///   rates do not change the outcome.
/// * A real posture votes with weight `max(confidence, minKnownWeight)` per
///   millisecond, so low-confidence frames count less but never vanish.
/// * [Posture.unknown] (including heartbeats, which have confidence 0) votes
///   with the fixed weight [unknownWeight] per millisecond. At the default 0.5
///   a typical real posture (confidence about 0.9) outweighs the same span of
///   unknown nearly two to one, so dropouts and interleaved heartbeats do not
///   easily out-vote a real posture, yet a sustained run of unknown (tracking
///   lost) fills the window and wins.
/// * Window time not covered by any reading (a gap in the stream longer than
///   [maxSpanMs]) counts as unknown: nothing was observed there.
///
/// ## Hysteresis
///
/// The output posture `P` changes to the strongest challenger `C` (by
/// weighted share) only when **both** hold:
///
/// 1. `C` wins the weighted vote: it holds at least [switchShare] of the
///    window weight (default 0.6), or `P` has decayed below [releaseShare]
///    (default 0.25) and `C` outweighs it. The release rule stops the output
///    sticking to a posture with no support left when the window is split
///    between a new posture and unknown.
/// 2. `C` covers at least [switchShare] of the window's **unweighted time**
///    (its readings' spans; for [Posture.unknown] also any uncovered time).
///
/// Rule 2 applies to every posture. Without it, confidence weighting would let
/// a high-confidence posture take over while covering only a minority of the
/// window: for example a few `standing` misreads at confidence 0.95 mixed with
/// unknown frames during jalsa could out-weigh a `sitting` output at
/// confidence 0.6. Misreading standing there is the most dangerous error (it
/// starts the second rak'ah's recitation), so no posture may take over unless
/// it was actually observed for most of the window. When nothing qualifies,
/// the output keeps its previous value.
///
/// Near 50/50 noise therefore never thrashes, and a single-frame flicker
/// (at most [maxSpanMs] of a [windowMs] window) can never reach either
/// threshold. The initial output after a reset is [Posture.unknown], and the
/// same rules apply, so a steady first posture is adopted on the first frame.
///
/// ## Latency
///
/// The smoothed posture lags real transitions by roughly half the window: in
/// clean 15 fps data it leaves `standing` about 270 ms after the person starts
/// bowing, and up to about 400 ms when unknown frames fall mid-movement (about
/// 470 ms if a free-running 100 ms heartbeat interleaves with camera frames,
/// since each heartbeat takes a slice of time as unknown). That is too slow
/// for stopping recitation. The state machine must therefore
/// trigger StopRecitation from the raw `torsoAngleDeg` and `hipHeightRatio`
/// passed through on every output (spec: torso above 35 degrees or hip below
/// 0.8 of standing, for 0.2 s), not from [PostureReading.posture].
///
/// ## Output
///
/// Each output keeps the raw frame's `tMs`, `takbirRaise`, `hipHeightRatio`
/// and `torsoAngleDeg` (unsmoothed, for the state machine's fast checks).
/// `takbirRaise` passes through untouched. `confidence`
/// is the output posture's share of the window weight (0..1).
class MajoritySmoother implements PostureSmoother {
  /// Length of the sliding vote window in milliseconds.
  final int windowMs;

  /// Window share a challenger needs to take over the output. In (0.5, 1].
  final double switchShare;

  /// Below this share the current output gives way to any posture that
  /// outweighs it. In [0, 0.5].
  final double releaseShare;

  /// Vote weight per millisecond of [Posture.unknown]. In (0, 1].
  final double unknownWeight;

  /// Minimum vote weight per millisecond of a real posture. In (0, 1].
  final double minKnownWeight;

  /// Longest span a single reading may cover (the heartbeat period).
  final int maxSpanMs;

  final Queue<_Vote> _votes = Queue<_Vote>();
  int? _lastT;
  int? _sessionStart;
  Posture _current = Posture.unknown;

  MajoritySmoother({
    this.windowMs = 500,
    this.switchShare = 0.6,
    this.releaseShare = 0.25,
    this.unknownWeight = 0.5,
    this.minKnownWeight = 0.1,
    this.maxSpanMs = 100,
  }) {
    if (windowMs <= 0) {
      throw ArgumentError.value(windowMs, 'windowMs', 'must be positive');
    }
    if (maxSpanMs <= 0 || maxSpanMs > windowMs) {
      throw ArgumentError.value(
          maxSpanMs, 'maxSpanMs', 'must be in (0, windowMs]');
    }
    if (!(switchShare > 0.5 && switchShare <= 1)) {
      throw ArgumentError.value(
          switchShare, 'switchShare', 'must be in (0.5, 1]');
    }
    if (!(releaseShare >= 0 && releaseShare <= 0.5)) {
      throw ArgumentError.value(
          releaseShare, 'releaseShare', 'must be in [0, 0.5]');
    }
    if (!(unknownWeight > 0 && unknownWeight <= 1)) {
      throw ArgumentError.value(
          unknownWeight, 'unknownWeight', 'must be in (0, 1]');
    }
    if (!(minKnownWeight > 0 && minKnownWeight <= 1)) {
      throw ArgumentError.value(
          minKnownWeight, 'minKnownWeight', 'must be in (0, 1]');
    }
  }

  /// The current smoothed posture ([Posture.unknown] after a reset).
  Posture get current => _current;

  /// Clears all state, as at the start of a session.
  void reset() {
    _votes.clear();
    _lastT = null;
    _sessionStart = null;
    _current = Posture.unknown;
  }

  /// Adds one raw reading and returns the smoothed reading for that frame.
  ///
  /// Readings must arrive in non-decreasing `tMs`; otherwise an
  /// [ArgumentError] is thrown and the state is unchanged. (The [smooth]
  /// stream never throws for this: it clamps late readings instead.)
  PostureReading add(PostureReading raw) {
    final t = raw.tMs;
    final last = _lastT;
    if (last != null && t < last) {
      throw ArgumentError.value(
          raw, 'raw', 'tMs $t is before the previous reading at $last ms');
    }

    final spanStart = last == null
        ? t - maxSpanMs
        : (t - last > maxSpanMs ? t - maxSpanMs : last);
    _sessionStart ??= spanStart;
    _lastT = t;
    _votes.addLast(_Vote(spanStart, t, raw.posture, _weightOf(raw)));

    final lo = t - windowMs > _sessionStart! ? t - windowMs : _sessionStart!;
    while (_votes.isNotEmpty && _votes.first.end <= lo) {
      _votes.removeFirst();
    }

    final weights = List<double>.filled(Posture.values.length, 0);
    final times = List<int>.filled(Posture.values.length, 0);
    var covered = 0;
    for (final v in _votes) {
      final start = v.start > lo ? v.start : lo;
      final span = v.end - start;
      if (span <= 0) continue;
      covered += span;
      times[v.posture.index] += span;
      weights[v.posture.index] += span * v.weight;
    }
    final windowLen = t - lo;
    final uncovered = windowLen - covered;
    if (uncovered > 0) {
      times[Posture.unknown.index] += uncovered;
      weights[Posture.unknown.index] += uncovered * unknownWeight;
    }

    var total = 0.0;
    for (final w in weights) {
      total += w;
    }
    // total > 0 always: the window spans at least maxSpanMs and all weights
    // are positive. Guard anyway.
    final shares = total > 0
        ? [for (final w in weights) w / total]
        : List<double>.filled(Posture.values.length, 0);

    final currentShare = shares[_current.index];
    Posture? challenger;
    for (final p in Posture.values) {
      if (p == _current) continue;
      if (challenger == null || shares[p.index] > shares[challenger.index]) {
        challenger = p;
      }
    }
    final challengerShare = shares[challenger!.index];
    final winsVote = challengerShare >= switchShare ||
        (currentShare < releaseShare && challengerShare > currentShare);
    // windowLen >= maxSpanMs > 0 always (see spanStart).
    final coversTime = windowLen > 0 &&
        times[challenger.index] >= switchShare * windowLen - 1e-9;
    if (winsVote && coversTime) {
      _current = challenger;
    }

    return PostureReading(
      tMs: t,
      posture: _current,
      confidence: shares[_current.index].clamp(0.0, 1.0),
      takbirRaise: raw.takbirRaise,
      hipHeightRatio: raw.hipHeightRatio,
      torsoAngleDeg: raw.torsoAngleDeg,
    );
  }

  /// Smooths a whole stream. State is reset when the stream is listened to.
  ///
  /// Unlike [add], this never throws for out-of-order input, so one late
  /// reading cannot kill the pipeline: a reading whose `tMs` is before the
  /// previous one is clamped to the previous `tMs`. It then spans no time and
  /// carries no vote, but its `takbirRaise`, `hipHeightRatio` and
  /// `torsoAngleDeg` still pass through, and the output's `tMs` stays
  /// non-decreasing.
  @override
  Stream<PostureReading> smooth(Stream<PostureReading> raw) async* {
    reset();
    await for (final r in raw) {
      final last = _lastT;
      yield add(last != null && r.tMs < last ? r.copyWith(tMs: last) : r);
    }
  }

  double _weightOf(PostureReading r) {
    if (r.posture == Posture.unknown) return unknownWeight;
    final c = r.confidence;
    return c > minKnownWeight ? (c > 1 ? 1.0 : c) : minKnownWeight;
  }
}

class _Vote {
  final int start;
  final int end;
  final Posture posture;
  final double weight;
  const _Vote(this.start, this.end, this.posture, this.weight);
}
