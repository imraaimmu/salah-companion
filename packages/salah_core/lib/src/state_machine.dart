/// The anchor-based Fajr prayer state machine. See docs/SPEC.md, section
/// "Prayer logic" (states, rules, replay cases) and the edge-case table.
library;

import 'dart:async';

import 'interfaces.dart';
import 'posture.dart';
import 'prayer.dart';

/// Smoothed postures -> prayer states and events, for a two-rak'ah Fajr.
///
/// Owns every hold time and timeout. Time comes only from
/// [PostureReading.tMs] (camera frames plus the ~100 ms heartbeat), never the
/// wall clock, so replays are deterministic. [add] is the synchronous core
/// used by replays and tests; [run] maps a stream through it.
///
/// ## Input
///
/// Readings from the smoother: `posture` is smoothed, while `takbirRaise`,
/// `hipHeightRatio` and `torsoAngleDeg` are the raw per-frame values passed
/// through. Heartbeats are [PostureReading.unknown] readings.
///
/// A reading **sees a person** when its posture is not [Posture.unknown] or
/// it carries a raw `hipHeightRatio` or `torsoAngleDeg`. An unknown reading
/// with no raw values (and every heartbeat) does not.
///
/// ## States and anchors
///
/// States only move forward. A *hold*
/// of posture P for d ms means: the smoothed posture has been P on every
/// reading for at least d ms, counted only from when the current state was
/// entered (so a hold never starts before its anchor) and only from the last
/// [TrackingRestored].
///
/// | From | Condition | To |
/// | --- | --- | --- |
/// | waiting | `takbirRaise` | takbir |
/// | waiting | bowing 0.5 s (missed takbir) | ruku1 |
/// | waiting | prostrating 0.5 s (missed takbir and ruku) | sujood1 (filled in) |
/// | takbir | standing 0.8 s | qiyam1 + `StartRecitation(1)` |
/// | takbir, qiyam1 | bowing 0.5 s | ruku1 |
/// | takbir, qiyam1 | prostrating 0.5 s (missed ruku) | sujood1 (filled in) |
/// | ruku1 | standing | itidal1 |
/// | ruku1 | prostrating 0.5 s (missed i'tidal) | sujood1 (filled in) |
/// | itidal1 | prostrating 0.5 s | sujood1 |
/// | sujood1 | standing 0.8 s | qiyam2 + `StartRecitation(2)` |
/// | sujood1 | bowing 0.5 s (missed qiyam 2) | ruku2 |
/// | qiyam2 | bowing 0.5 s | ruku2 |
/// | qiyam2 | prostrating 0.5 s (missed ruku) | sujood2 (filled in) |
/// | ruku2 | standing | itidal2 |
/// | ruku2 | prostrating 0.5 s (missed i'tidal) | sujood2 (filled in) |
/// | itidal2 | prostrating 0.5 s | sujood2 |
/// | sujood2 | sitting 5 s (gaps tolerated, see below) | finalSitting |
/// | finalSitting | standing 0.8 s, 180 s in the state, or no person > 10 s | done + `SessionEnded(completed)` |
///
/// All durations are constructor parameters (defaults from the spec).
///
/// **Filled in** means a missed Ruku and/or I'tidal is emitted as
/// zero-length [StateChanged] transitions at the same `tMs`, e.g. a missed
/// ruku in rak'ah 1 gives `qiyam1 -> ruku1 -> itidal1 -> sujood1`. A missed
/// jalsa needs nothing (the two prostrations and the jalsa are one state).
/// Qiyam states are never filled in: they are the audio states.
///
/// Everything else is ignored: standing in waiting (however long), hand
/// raises outside waiting (ruku raises, qunut), sitting in sujood1 (jalsa,
/// brief sitting before rak'ah 2), the second sujood, standing in sujood2
/// (extra rak'ahs get no audio) and prostrations in finalSitting (sujood
/// al-sahw before or after the salam).
///
/// **Hip-height check.** For every standing hold (both Qiyams and getting
/// up from the final sitting), a smoothed `standing`
/// reading counts only if its raw values do not say the user has left
/// standing (torso over 35 degrees or hip height under 0.8); such a reading
/// restarts the hold. Missing raw values are accepted (the classifier already
/// required hip height for `standing`, and the hip ratio is null until
/// calibration, e.g. after a missed takbir).
///
/// **Final-sitting hold.** The 5 s sitting hold in sujood2 tolerates short
/// gaps: readings whose hold posture is unknown (dropouts, heartbeats) for
/// at most [finalSittingGapMs] (1 s) in total do not restart it; any other
/// posture (standing, bowing, prostrating) does, and so does a longer total
/// gap. The hold still ends on a sitting reading.
///
/// **Ruku hip check.** For every bowing hold that confirms Ruku (both
/// rak'ahs, from any state), a smoothed `bowing` reading counts only if its
/// raw hip height is missing or at least [rukuMinHipRatio] (0.8); a lower one
/// restarts the hold. A real ruku keeps the hips at standing height (about
/// 1.0), while rising from sujood passes through a bowing-like torso with the
/// hips still low (0.6-0.76), which would otherwise enter ruku2 and skip
/// qiyam 2 (and its recitation) silently.
///
/// ## Rak'ah numbers
///
/// [StateChanged.rakah] is the rak'ah of the state entered: 0 for waiting and
/// takbir (before the prayer proper, matching the label files), 1 for
/// qiyam1..sujood1, 2 for qiyam2..finalSitting and done.
///
/// ## Recitation, early stop, pause and resume
///
/// A recitation is *open* from its [StartRecitation] until its
/// [StopRecitation]; while open it is either *playing* or *paused*. It can
/// only be open in its own Qiyam state. Every rule below looks at the raw
/// `torsoAngleDeg` and `hipHeightRatio`, because the smoothed posture lags by
/// ~270-470 ms (and keeps its last value for a while when frames stop). A
/// reading has **body data** when it carries at least one raw value; one
/// with neither (every heartbeat, and a frame with no usable person) is
/// *blind*, whatever its smoothed posture. A raw value says the user has
/// **left standing** when torso > [leaveTorsoDeg] (35 degrees) or hip <
/// [leaveHipRatio] (0.8); missing values are accepted.
///
/// While playing:
///
/// * **Early stop.** Body data showing left standing for [earlyStopHoldMs]
///   (0.2 s) emits [StopRecitation]. Body data inside the standing limits
///   breaks that run. Blind time *counts* toward the 0.2 s when the last
///   body data before it already showed left standing, or the torso leaning
///   past the standing limit (over [leanTorsoDeg], 20 degrees; counted from
///   the first such reading): the user was going down when the camera lost
///   them.
/// * **Pause.** Otherwise, no body data for more than [blindPauseMs]
///   (0.6 s; measured from the last body data, or from the start or resume
///   if later) emits [PauseRecitation]: a blind spot, possibly hiding a bow.
///
/// While paused:
///
/// * Body data arriving after a blind span longer than [maxResumeBlindMs]
///   (1 s, measured from the last body data, before the pause or during it,
///   to this reading) emits [StopRecitation]: a fast ruku and i'tidal fit in
///   about 2 s, so the standing now seen may be the i'tidal.
/// * Otherwise *resumable* body data for [earlyStopHoldMs], with no blind or
///   non-resumable reading in between, emits [ResumeRecitation]: the same
///   recitation continues from the start of the ayah it was paused in.
///   Resumable means inside the standing limits, smoothed posture
///   `standing` at confidence [resumeMinConfidence] (0.5) or more, and, once
///   any earlier reading carried a hip height ratio (calibration exists), a
///   non-null hip height ratio of at least [leaveHipRatio] (0.8). Torso-only
///   or low-confidence data can stop a recitation but never resume one.
/// * Body data showing left standing for [earlyStopHoldMs] (blind time
///   counting as above) emits [StopRecitation].
/// * Staying paused with no body data for more than [trackingLostMs] (2 s,
///   counted from the pause or the last body data, whichever is later) emits
///   [StopRecitation]: the user may have bowed and stood up again unseen. (A
///   backstop: the lost-tracking rule below usually ends it first.)
///
/// If one reading would emit both a [ResumeRecitation] and a later
/// [StopRecitation] (e.g. a resume on the reading where the state times
/// out or moves on), only the [StopRecitation] is emitted. Events must be
/// applied to the player strictly in the order they are returned.
///
/// In either case [StopRecitation] also fires on [TrackingLost], on leaving
/// the Qiyam state (e.g. Ruku confirmed while paused or with raw values
/// missing), and before a [SessionEnded]. A stopped recitation is final:
/// there is no resume after [StopRecitation] (and so none after
/// [TrackingLost]), every [ResumeRecitation] follows its own
/// [PauseRecitation], and each rak'ah's recitation starts at most once per
/// session ("never repeat": a resume continues, it does not restart).
///
/// ## Lost tracking
///
/// No person seen for more than 2 s: `StopRecitation` (if a recitation is
/// open, playing or paused), then [TrackingLost]; the machine freezes (no
/// transitions, hence never a [StartRecitation] or [ResumeRecitation]). The
/// next reading that sees a person emits [TrackingRestored] and restarts
/// every hold from that reading, so a Qiyam needs a fresh 0.8 s standing
/// hold after tracking returns. Timeouts keep running while frozen.
///
/// ## Ending
///
/// * finalSitting and no person for more than 10 s (measured from the last
///   reading that saw one): done, `SessionEnded(completed)`.
/// * Frozen for more than 30 s (measured from the [TrackingLost]) in any
///   other state: `SessionEnded(cameraLost)` (spec: "not recovered within
///   30 s -> end quietly"). The machine cannot tell a fallen phone from a
///   user who walked away, so both end the session.
/// * More than 180 s in one state (waiting: 10 minutes):
///   `SessionEnded(timeout)`, except finalSitting, where 180 s means done
///   with `SessionEnded(completed)`.
///
/// After [SessionEnded], [add] returns no more events until [reset], and
/// the [run] stream closes.
///
/// ## Ambiguities resolved (the rule: never play audio at the wrong time)
///
/// * **Prostration from waiting** enters sujood1 (takbir and ruku both
///   missed). Otherwise the user's real rak'ah 2 would be counted as rak'ah 1
///   and getting up after the salam would start the rak'ah 2 recitation.
/// * **Bowing from sujood1** enters ruku2 without audio (qiyam 2 too short
///   or unseen): silence, never a late start.
/// * **I'tidal** needs no hold (the spec gives none and it has no audio);
///   **getting up from finalSitting** uses the 0.8 s standing hold.
/// * **"Sitting lasts over 180 s"** is measured from entering finalSitting.
/// * **Out of order timestamps** are clamped to the previous reading's time.
class FajrStateMachine implements PrayerStateMachine {
  /// Standing hold after the takbir that enters qiyam1 (spec: 0.8 s).
  final int qiyam1HoldMs;

  /// Standing hold after a rak'ah-1 prostration that enters qiyam2
  /// (spec: 0.8 s).
  final int qiyam2HoldMs;

  /// Bowing hold that confirms Ruku (spec: 0.5 s).
  final int rukuHoldMs;

  /// Prostrating hold that confirms Sujood (spec: 0.5 s).
  final int sujoodHoldMs;

  /// Sitting hold after a rak'ah-2 prostration that enters the final sitting
  /// (spec: 5 s).
  final int finalSittingHoldMs;

  /// Standing hold in the final sitting that means the user got up: done.
  final int finalStandHoldMs;

  /// The final sitting lasting longer than this means done (spec: 180 s).
  final int finalSittingMaxMs;

  /// No person for longer than this in the final sitting means done
  /// (spec: 10 s).
  final int finalSittingOutOfFrameMs;

  /// Raw values beyond the standing limits for this long stop a recitation
  /// (spec: 0.2 s).
  final int earlyStopHoldMs;

  /// Raw torso angle from vertical above which the user has left standing
  /// (spec: 35 degrees).
  final double leaveTorsoDeg;

  /// Raw hip height ratio below which the user has left standing
  /// (spec: 0.8).
  final double leaveHipRatio;

  /// Raw torso angle from vertical above which the user leans past the
  /// standing limit (the classifier's 20 degrees). Body data like this does
  /// not stop a recitation by itself, but blind time right after it counts
  /// toward the early-stop hold, as after data showing left standing.
  final double leanTorsoDeg;

  /// A smoothed bowing reading with a raw hip height ratio below this does
  /// not count toward the Ruku hold (rising from sujood, not ruku).
  final double rukuMinHipRatio;

  /// No body data for longer than this while a recitation plays pauses it
  /// (a blind spot).
  final int blindPauseMs;

  /// A paused recitation may resume only if the whole blind span, from the
  /// last body data before the pause to the first body data after it, is at
  /// most this long; a longer one stops it for good. Even a fast ruku (bowing
  /// down, one tasbih, rising) takes about 2 s, so after a longer blind span the standing seen may be
  /// the i'tidal.
  final int maxResumeBlindMs;

  /// The smoothed confidence a reading needs to count toward a resume.
  final double resumeMinConfidence;

  /// Unknown or blind time (in total) that a final-sitting hold tolerates
  /// before it restarts.
  final int finalSittingGapMs;

  /// No person for longer than this freezes the machine (spec: 2 s).
  final int trackingLostMs;

  /// Frozen for longer than this ends the session with
  /// [EndReason.cameraLost] (spec edge cases: 30 s).
  final int cameraLostMs;

  /// The longest any state except waiting may last (spec: 180 s).
  final int stateTimeoutMs;

  /// The longest waiting may last (spec: 10 minutes).
  final int waitingTimeoutMs;

  FajrStateMachine({
    this.qiyam1HoldMs = 800,
    this.qiyam2HoldMs = 800,
    this.rukuHoldMs = 500,
    this.sujoodHoldMs = 500,
    this.finalSittingHoldMs = 5000,
    this.finalStandHoldMs = 800,
    this.finalSittingMaxMs = 180000,
    this.finalSittingOutOfFrameMs = 10000,
    this.earlyStopHoldMs = 200,
    this.leaveTorsoDeg = 35,
    this.leaveHipRatio = 0.8,
    this.leanTorsoDeg = 20,
    this.rukuMinHipRatio = 0.8,
    this.blindPauseMs = 600,
    this.maxResumeBlindMs = 1500,
    this.resumeMinConfidence = 0.5,
    this.finalSittingGapMs = 1000,
    this.trackingLostMs = 2000,
    this.cameraLostMs = 30000,
    this.stateTimeoutMs = 180000,
    this.waitingTimeoutMs = 600000,
  }) {
    void positive(int v, String name) {
      if (v <= 0) throw ArgumentError.value(v, name, 'must be positive');
    }

    positive(qiyam1HoldMs, 'qiyam1HoldMs');
    positive(qiyam2HoldMs, 'qiyam2HoldMs');
    positive(rukuHoldMs, 'rukuHoldMs');
    positive(sujoodHoldMs, 'sujoodHoldMs');
    positive(finalSittingHoldMs, 'finalSittingHoldMs');
    positive(finalStandHoldMs, 'finalStandHoldMs');
    positive(finalSittingMaxMs, 'finalSittingMaxMs');
    positive(finalSittingOutOfFrameMs, 'finalSittingOutOfFrameMs');
    positive(earlyStopHoldMs, 'earlyStopHoldMs');
    positive(blindPauseMs, 'blindPauseMs');
    positive(maxResumeBlindMs, 'maxResumeBlindMs');
    if (finalSittingGapMs < 0) {
      throw ArgumentError.value(
          finalSittingGapMs, 'finalSittingGapMs', 'must not be negative');
    }
    positive(trackingLostMs, 'trackingLostMs');
    positive(cameraLostMs, 'cameraLostMs');
    positive(stateTimeoutMs, 'stateTimeoutMs');
    positive(waitingTimeoutMs, 'waitingTimeoutMs');
    if (!(leaveTorsoDeg > 0)) {
      throw ArgumentError.value(leaveTorsoDeg, 'leaveTorsoDeg', 'must be > 0');
    }
    if (!(leaveHipRatio > 0)) {
      throw ArgumentError.value(leaveHipRatio, 'leaveHipRatio', 'must be > 0');
    }
    if (!(leanTorsoDeg > 0 && leanTorsoDeg <= leaveTorsoDeg)) {
      throw ArgumentError.value(
          leanTorsoDeg, 'leanTorsoDeg', 'must be in (0, leaveTorsoDeg]');
    }
    if (!(rukuMinHipRatio > 0)) {
      throw ArgumentError.value(
          rukuMinHipRatio, 'rukuMinHipRatio', 'must be > 0');
    }
  }

  PrayerState _state = PrayerState.waiting;
  int? _lastT;
  int _stateEnteredMs = 0;
  int _lastSeenMs = 0;
  bool _frozen = false;
  int _lostAtMs = 0;
  bool _ended = false;

  // Current run of identical hold keys (see _holdKey).
  Posture? _runPosture;
  int _runStartMs = 0;

  // Recitation bookkeeping.
  bool _started1 = false;
  bool _started2 = false;
  _Audio _audio = _Audio.none;
  int _audioRakah = 0;
  int _audioSinceMs = 0; // last Start, Resume or Pause
  int? _leaveStartMs; // run of body data showing left standing
  int? _leanStartMs; // run of body data leaning past leanTorsoDeg (or leaving)
  int? _standStartMs; // run of standing body data while paused
  int? _lastRawMs; // last reading with body data
  bool _hipSeen = false; // some reading had a hip height ratio (calibrated)

  // Final-sitting hold (sujood2 -> finalSitting), tolerating short gaps.
  int? _sitStartMs;
  int _sitGapMs = 0;

  /// The current state.
  PrayerState get state => _state;

  /// True while tracking is lost.
  bool get frozen => _frozen;

  /// True once [SessionEnded] has been emitted.
  bool get ended => _ended;

  /// Clears all state, as at the start of a session.
  void reset() {
    _state = PrayerState.waiting;
    _lastT = null;
    _stateEnteredMs = 0;
    _lastSeenMs = 0;
    _frozen = false;
    _lostAtMs = 0;
    _ended = false;
    _runPosture = null;
    _runStartMs = 0;
    _started1 = false;
    _started2 = false;
    _audio = _Audio.none;
    _audioRakah = 0;
    _audioSinceMs = 0;
    _leaveStartMs = null;
    _leanStartMs = null;
    _standStartMs = null;
    _lastRawMs = null;
    _hipSeen = false;
    _sitStartMs = null;
    _sitGapMs = 0;
  }

  /// Runs [smoothed] through a fresh session. The stream closes after
  /// [SessionEnded].
  @override
  Stream<PrayerEvent> run(Stream<PostureReading> smoothed) async* {
    reset();
    await for (final r in smoothed) {
      final events = add(r);
      for (final e in events) {
        yield e;
      }
      if (_ended) return;
    }
  }

  /// Adds one smoothed reading and returns the events it causes, in order.
  ///
  /// The events must be applied to the player strictly in the order given
  /// (and across calls, in the order of the calls). If one reading would
  /// cause both a [ResumeRecitation] and a later [StopRecitation], only the
  /// [StopRecitation] is emitted: there is no point fading audio back in for
  /// a moment.
  List<PrayerEvent> add(PostureReading r) {
    if (_ended) return const [];
    final out = _add(r);
    final stop = out.lastIndexWhere((e) => e is StopRecitation);
    if (stop > 0) {
      for (var i = stop - 1; i >= 0; i--) {
        if (out[i] is ResumeRecitation) out.removeAt(i);
      }
    }
    return out;
  }

  List<PrayerEvent> _add(PostureReading r) {
    final last = _lastT;
    final t = last != null && r.tMs < last ? last : r.tMs;
    if (last == null) {
      _stateEnteredMs = t;
      _lastSeenMs = t;
      _runStartMs = t;
    }
    _lastT = t;
    final out = <PrayerEvent>[];

    // Tracking restored.
    final seen = r.posture != Posture.unknown ||
        r.hipHeightRatio != null ||
        r.torsoAngleDeg != null;
    if (seen) {
      _lastSeenMs = t;
      if (_frozen) {
        _frozen = false;
        _runPosture = null; // every hold restarts from this reading
        _sitStartMs = null;
        _sitGapMs = 0;
        out.add(TrackingRestored(t));
      }
    }

    // Hold run.
    final key = _holdKey(r);
    if (key != _runPosture) {
      _runPosture = key;
      _runStartMs = t;
    }

    // Early stop, pause and resume from raw values.
    final hasRaw = r.hipHeightRatio != null || r.torsoAngleDeg != null;
    final prevRaw = _lastRawMs;
    if (hasRaw) _lastRawMs = t;
    switch (_audio) {
      case _Audio.playing:
        _whilePlaying(r, t, hasRaw, out);
      case _Audio.paused:
        _whilePaused(r, t, hasRaw, prevRaw, out);
      case _Audio.none:
        break;
    }
    // After the resume checks: they ask whether an *earlier* reading had a
    // hip height.
    if (r.hipHeightRatio != null) _hipSeen = true;

    // Tracking lost.
    if (!_frozen && t - _lastSeenMs > trackingLostMs) {
      _stop(out, t);
      _frozen = true;
      _lostAtMs = t;
      out.add(TrackingLost(t));
    }

    // Endings that run even while frozen.
    if (_frozen) {
      if (_state == PrayerState.finalSitting &&
          t - _lastSeenMs > finalSittingOutOfFrameMs) {
        _finish(out, t);
        return out;
      }
      if (t - _lostAtMs > cameraLostMs) {
        _end(out, t, EndReason.cameraLost);
        return out;
      }
    }
    final limit = switch (_state) {
      PrayerState.waiting => waitingTimeoutMs,
      PrayerState.finalSitting => finalSittingMaxMs,
      _ => stateTimeoutMs,
    };
    if (t - _stateEnteredMs > limit) {
      if (_state == PrayerState.finalSitting) {
        _finish(out, t);
      } else {
        _end(out, t, EndReason.timeout);
      }
      return out;
    }

    if (!_frozen) _advance(r, t, last == null ? 0 : t - last, out);
    return out;
  }

  /// Time without body data at [t], counted from the last body data or the
  /// last Start/Resume/Pause, whichever is later.
  int _blindFor(int t) {
    final raw = _lastRawMs;
    return t - (raw != null && raw > _audioSinceMs ? raw : _audioSinceMs);
  }

  /// Extends or breaks the left-standing run; true when it has lasted the
  /// early-stop hold. Blind readings extend a run that is already going.
  bool _leftStanding(PostureReading r, int t, bool hasRaw) {
    if (hasRaw) {
      final torso = r.torsoAngleDeg;
      if (_leaving(r) || (torso != null && torso > leanTorsoDeg)) {
        _leanStartMs ??= t;
      } else {
        _leanStartMs = null;
      }
      if (!_leaving(r)) {
        _leaveStartMs = null;
        return false;
      }
      final start = _leaveStartMs ??= t;
      return t - start >= earlyStopHoldMs;
    }
    // Blind: the time counts if the last body data showed the user leaving
    // standing, or already leaning past the standing limit.
    final start = _leaveStartMs ?? _leanStartMs;
    return start != null && t - start >= earlyStopHoldMs;
  }

  void _whilePlaying(
      PostureReading r, int t, bool hasRaw, List<PrayerEvent> out) {
    if (_leftStanding(r, t, hasRaw)) {
      _stop(out, t);
    } else if (!hasRaw &&
        _leaveStartMs == null &&
        _blindFor(t) > blindPauseMs) {
      _audio = _Audio.paused;
      _audioSinceMs = t;
      _standStartMs = null;
      out.add(PauseRecitation(t, rakah: _audioRakah));
    }
  }

  void _whilePaused(PostureReading r, int t, bool hasRaw, int? prevRaw,
      List<PrayerEvent> out) {
    if (_leftStanding(r, t, hasRaw)) {
      _stop(out, t);
      return;
    }
    if (!hasRaw) {
      _standStartMs = null; // resuming needs unbroken standing body data
      if (_blindFor(t) > trackingLostMs) _stop(out, t);
      return;
    }
    // Body data again: the blind span since the last body data (before the
    // pause, or since a flicker of body data during it) must have been short
    // enough that no ruku can have fitted in it.
    if (t - (prevRaw ?? _audioSinceMs) > maxResumeBlindMs) {
      _stop(out, t);
      return;
    }
    if (_leaveStartMs != null || !_resumable(r)) {
      _standStartMs = null;
      return;
    }
    final start = _standStartMs ??= t;
    if (t - start >= earlyStopHoldMs) {
      _audio = _Audio.playing;
      _audioSinceMs = t;
      _standStartMs = null;
      out.add(ResumeRecitation(t, rakah: _audioRakah));
    }
  }

  /// Whether body data inside the standing limits is good enough to count
  /// toward a resume: the smoothed posture is standing at confidence
  /// [resumeMinConfidence] or more and, once any earlier reading had a hip
  /// height ratio (calibration exists), the hip height is known and at least
  /// [leaveHipRatio]. Torso-only or low-confidence data can still stop a
  /// recitation, but never resume one.
  bool _resumable(PostureReading r) {
    if (r.posture != Posture.standing) return false;
    if (r.confidence < resumeMinConfidence) return false;
    if (_hipSeen) {
      final hip = r.hipHeightRatio;
      if (hip == null || hip < leaveHipRatio) return false;
    }
    return true;
  }

  /// Tracks the final-sitting hold in sujood2 at [t]; true once sitting has
  /// been held [finalSittingHoldMs] (counted from entering sujood2 at the
  /// earliest). Unknown or blind readings for at most [finalSittingGapMs] in
  /// total do not restart it; any other posture (standing, bowing,
  /// prostrating) does.
  bool _finalSittingHeld(PostureReading r, int t, int dt) {
    switch (_holdKey(r)) {
      case Posture.sitting:
        _sitStartMs ??= t;
      case Posture.unknown:
        if (_sitStartMs != null) {
          _sitGapMs += dt;
          if (_sitGapMs > finalSittingGapMs) _sitStartMs = null;
        }
      case _:
        _sitStartMs = null;
    }
    final start = _sitStartMs;
    if (start == null) {
      _sitGapMs = 0;
      return false;
    }
    final from = start > _stateEnteredMs ? start : _stateEnteredMs;
    return _holdKey(r) == Posture.sitting && t - from >= finalSittingHoldMs;
  }

  void _advance(PostureReading r, int t, int dt, List<PrayerEvent> out) {
    bool held(Posture p, int ms) => _held(p, t) >= ms;
    final bowing = held(Posture.bowing, rukuHoldMs);
    final prostrating = held(Posture.prostrating, sujoodHoldMs);
    switch (_state) {
      case PrayerState.waiting:
        if (r.takbirRaise) {
          _go(PrayerState.takbir, t, out);
        } else if (bowing) {
          _go(PrayerState.ruku1, t, out);
        } else if (prostrating) {
          _fillTo(PrayerState.sujood1, t, out);
        }
      case PrayerState.takbir:
        if (held(Posture.standing, qiyam1HoldMs)) {
          _go(PrayerState.qiyam1, t, out);
          if (!_started1) {
            _started1 = true;
            _startRecitation(out, t, 1);
          }
        } else if (bowing) {
          _go(PrayerState.ruku1, t, out);
        } else if (prostrating) {
          _fillTo(PrayerState.sujood1, t, out);
        }
      case PrayerState.qiyam1:
        if (bowing) {
          _go(PrayerState.ruku1, t, out);
        } else if (prostrating) {
          _fillTo(PrayerState.sujood1, t, out);
        }
      case PrayerState.ruku1:
        if (r.posture == Posture.standing) {
          _go(PrayerState.itidal1, t, out);
        } else if (prostrating) {
          _fillTo(PrayerState.sujood1, t, out);
        }
      case PrayerState.itidal1:
        if (prostrating) _go(PrayerState.sujood1, t, out);
      case PrayerState.sujood1:
        if (held(Posture.standing, qiyam2HoldMs)) {
          _go(PrayerState.qiyam2, t, out);
          if (!_started2) {
            _started2 = true;
            _startRecitation(out, t, 2);
          }
        } else if (bowing) {
          _go(PrayerState.ruku2, t, out);
        }
      case PrayerState.qiyam2:
        if (bowing) {
          _go(PrayerState.ruku2, t, out);
        } else if (prostrating) {
          _fillTo(PrayerState.sujood2, t, out);
        }
      case PrayerState.ruku2:
        if (r.posture == Posture.standing) {
          _go(PrayerState.itidal2, t, out);
        } else if (prostrating) {
          _fillTo(PrayerState.sujood2, t, out);
        }
      case PrayerState.itidal2:
        if (prostrating) _go(PrayerState.sujood2, t, out);
      case PrayerState.sujood2:
        if (_finalSittingHeld(r, t, dt)) {
          _go(PrayerState.finalSitting, t, out);
        }
      case PrayerState.finalSitting:
        if (held(Posture.standing, finalStandHoldMs)) _finish(out, t);
      case PrayerState.done:
        break;
    }
  }

  /// Enters [sujood] (sujood1 or sujood2) from an earlier state, filling in
  /// a missed Ruku and I'tidal with zero-length transitions at [t], so the
  /// emitted chain always reads ... -> ruku -> itidal -> sujood.
  void _fillTo(PrayerState sujood, int t, List<PrayerEvent> out) {
    final (ruku, itidal) = sujood == PrayerState.sujood1
        ? (PrayerState.ruku1, PrayerState.itidal1)
        : (PrayerState.ruku2, PrayerState.itidal2);
    if (_state != ruku) _go(ruku, t, out);
    _go(itidal, t, out);
    _go(sujood, t, out);
  }

  /// The posture a reading contributes to hold runs. A smoothed `standing`
  /// whose raw values say the user has left standing counts as unknown, so
  /// it restarts a Qiyam hold (the hip-height check); so does a smoothed
  /// `bowing` with the hips low (the ruku hip check).
  Posture _holdKey(PostureReading r) {
    final hip = r.hipHeightRatio;
    return switch (r.posture) {
      Posture.standing when _leaving(r) => Posture.unknown,
      Posture.bowing when hip != null && hip < rukuMinHipRatio =>
        Posture.unknown,
      final p => p,
    };
  }

  bool _leaving(PostureReading r) {
    final torso = r.torsoAngleDeg;
    final hip = r.hipHeightRatio;
    return (torso != null && torso > leaveTorsoDeg) ||
        (hip != null && hip < leaveHipRatio);
  }

  /// How long [p] has been held at [t], counted from the later of the run
  /// start and the current state's entry; -1 if [p] is not the current run.
  int _held(Posture p, int t) {
    if (_runPosture != p) return -1;
    final from = _runStartMs > _stateEnteredMs ? _runStartMs : _stateEnteredMs;
    return t - from;
  }

  void _go(PrayerState to, int t, List<PrayerEvent> out) {
    // Leaving a Qiyam ends its recitation, playing or paused.
    _stop(out, t);
    final from = _state;
    _state = to;
    _stateEnteredMs = t;
    _sitStartMs = null;
    _sitGapMs = 0;
    out.add(StateChanged(t, from: from, to: to, rakah: rakahOf(to)));
  }

  void _startRecitation(List<PrayerEvent> out, int t, int rakah) {
    _audio = _Audio.playing;
    _audioRakah = rakah;
    _audioSinceMs = t;
    _leaveStartMs = null;
    _leanStartMs = null;
    _standStartMs = null;
    out.add(StartRecitation(t, rakah: rakah));
  }

  /// Emits StopRecitation if a recitation is open (playing or paused), then
  /// ends it for good.
  void _stop(List<PrayerEvent> out, int t) {
    if (_audio == _Audio.none) return;
    _audio = _Audio.none;
    _leaveStartMs = null;
    _leanStartMs = null;
    _standStartMs = null;
    out.add(StopRecitation(t));
  }

  void _finish(List<PrayerEvent> out, int t) {
    _go(PrayerState.done, t, out);
    _end(out, t, EndReason.completed);
  }

  void _end(List<PrayerEvent> out, int t, EndReason reason) {
    _stop(out, t);
    _ended = true;
    out.add(SessionEnded(t, reason: reason));
  }

  /// The rak'ah reported with [StateChanged] when entering [s].
  static int rakahOf(PrayerState s) => switch (s) {
        PrayerState.waiting || PrayerState.takbir => 0,
        PrayerState.qiyam1 ||
        PrayerState.ruku1 ||
        PrayerState.itidal1 ||
        PrayerState.sujood1 =>
          1,
        PrayerState.qiyam2 ||
        PrayerState.ruku2 ||
        PrayerState.itidal2 ||
        PrayerState.sujood2 ||
        PrayerState.finalSitting ||
        PrayerState.done =>
          2,
      };
}

/// The open recitation, if any.
enum _Audio { none, playing, paused }
