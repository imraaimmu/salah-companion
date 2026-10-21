/// The anchor-based prayer state machine for the five fard prayers. See
/// docs/SPEC.md, section "Prayer logic" (states, rules, replay cases) and
/// the edge-case table.
library;

import 'dart:async';

import 'interfaces.dart';
import 'posture.dart';
import 'prayer.dart';

/// The state machine before it covered every prayer. Kept so existing code
/// keeps compiling: `FajrStateMachine()` is a Fajr machine (the default
/// [SalahStateMachine.prayer]).
typedef FajrStateMachine = SalahStateMachine;

/// Smoothed postures -> prayer states and events, for a prayer of
/// N = [Prayer.rakahCount] rak'ahs (Fajr 2, Maghrib 3, Dhuhr, Asr and
/// Isha 4).
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
/// States only move forward, and the rak'ah only grows. The states do not
/// depend on the rak'ah; the machine keeps the current rak'ah k ([rakah])
/// and reports it with every [StateChanged]. A *hold* of posture P for d ms
/// means: the smoothed posture has been P on every reading for at least
/// d ms, counted only from when the current state was entered (so a hold
/// never starts before its anchor) and only from the last
/// [TrackingRestored].
///
/// | From | Condition | To |
/// | --- | --- | --- |
/// | waiting | `takbirRaise`, and no sitting or prostrating reading in the last [takbirAfterLowMs] (5 s) | takbir |
/// | waiting | bowing 0.5 s (missed takbir) | ruku, k = 1; N > 2: count uncertain unless the entry is trusted (below) |
/// | waiting | prostrating 0.5 s (missed takbir and ruku) | sujood, k = 1 (filled in); N > 2: count uncertain |
/// | takbir | standing 0.8 s | qiyam, k = 1 + `StartRecitation(1)` |
/// | takbir | bowing 0.5 s | ruku, k = 1 |
/// | takbir | prostrating 0.5 s (missed ruku) | sujood, k = 1 (filled in) |
/// | qiyam | bowing 0.5 s | ruku |
/// | qiyam | prostrating 0.5 s (missed ruku) | sujood (filled in) |
/// | ruku | standing | itidal |
/// | ruku | prostrating 0.5 s (missed i'tidal) | sujood (filled in) |
/// | itidal | prostrating 0.5 s | sujood |
/// | itidal | standing 0.5 s, then bowing [secondRukuMs] (1.2 s), then standing 0.5 s (a second ruku: the prostrations were missed) | itidal; count uncertain |
/// | sujood, k < N, not (k = 2 < N) | standing 0.8 s | qiyam, k + 1 + `StartRecitation(k + 1)` |
/// | sujood, k < N, not (k = 2 < N) | bowing 0.5 s (missed qiyam) | ruku, k + 1 |
/// | sujood, k < N, not (k = 2 < N) | sitting [longSittingMs] (8 s, gaps tolerated) | sujood; count uncertain |
/// | sujood, k = 2 < N | sitting [middleSittingHoldMs] (3 s, gaps tolerated) | middleSitting |
/// | sujood, k = 2 < N | standing 0.8 s (middle sitting not confirmed) | qiyam, k = 3, **silent** |
/// | sujood, k = 2 < N | bowing 0.5 s | ruku, k = 3 |
/// | middleSitting | standing 0.8 s | qiyam, k = 3 + `StartRecitation(3)` |
/// | middleSitting | bowing 0.5 s (missed qiyam) | ruku, k = 3 |
/// | sujood, k = N | sitting 5 s (gaps tolerated, see below) | finalSitting |
/// | sujood, k = N | sitting [finalStandAfterSitMs] (3 s, gaps tolerated) after the last prostration, then standing 0.8 s | finalSitting (filled in) -> done + `SessionEnded(completed)` (never a recitation) |
/// | finalSitting | standing 0.8 s, 180 s in the state, or no person > 10 s | done + `SessionEnded(completed)` |
///
/// All durations are constructor parameters (defaults from the spec). For
/// Fajr (N = 2) this is exactly the two-rak'ah machine: there is no middle
/// sitting, and sujood of rak'ah 2 leads to the final sitting.
///
/// **Filled in** means a missed Ruku and/or I'tidal is emitted as
/// zero-length [StateChanged] transitions at the same `tMs`, e.g. a missed
/// ruku gives `qiyam -> ruku -> itidal -> sujood`, all with the same rak'ah.
/// A missed jalsa needs nothing (the two prostrations and the jalsa are one
/// state). Qiyam is never filled in: it is the audio state.
///
/// Everything else is ignored: standing in waiting (however long), hand
/// raises outside waiting (ruku raises, qunut, **the raise when standing up
/// from the middle sitting**), sitting in sujood shorter than the holds
/// above (jalsa, a brief sitting before standing), the second sujood,
/// prostrations in middleSitting (the second prostration after a long jalsa
/// that already entered it), standing in sujood of rak'ah N (extra rak'ahs
/// get no audio) and prostrations in finalSitting (sujood al-sahw before or
/// after the salam).
///
/// **Hip-height check.** For every standing hold (every Qiyam and getting
/// up from the final sitting), a smoothed `standing`
/// reading counts only if its raw values do not say the user has left
/// standing (torso over 35 degrees or hip height under 0.8); such a reading
/// restarts the hold. Missing raw values are accepted (the classifier already
/// required hip height for `standing`, and the hip ratio is null until
/// calibration, e.g. after a missed takbir).
///
/// **Sitting holds.** Every sitting hold in sujood (the 5 s final-sitting
/// hold, the 3 s middle-sitting hold, the 8 s long sitting and the 3 s
/// sitting before the final stand) tolerates short gaps: readings whose hold posture is
/// unknown (dropouts, heartbeats) for at most [finalSittingGapMs] (1 s) in
/// total do not restart them; any other posture (standing, bowing,
/// prostrating) does, and so does a longer total gap. The hold still ends
/// on a sitting reading.
///
/// **Ruku hip check.** For every bowing hold that confirms Ruku (every
/// rak'ah, from any state), a smoothed `bowing` reading counts only if its
/// raw hip height is missing or at least [rukuMinHipRatio] (0.8); a lower one
/// restarts the hold. A real ruku keeps the hips at standing height (about
/// 1.0), while rising from sujood passes through a bowing-like torso with the
/// hips still low (0.6-0.76), which would otherwise enter the next ruku and
/// skip its qiyam (and its recitation) silently.
///
/// ## Rak'ah numbers and recitations
///
/// [StateChanged.rakah] is the rak'ah of the state entered: 0 for waiting and
/// takbir (before the prayer proper, matching the label files), k for
/// qiyam, ruku, itidal and sujood of rak'ah k, 2 for middleSitting, N for
/// finalSitting and done.
///
/// `StartRecitation(k)` fires at most once per rak'ah k (1..N), on entering
/// its qiyam, and never while the count is uncertain (below). What it
/// plays is the planner's business: Al-Fatiha and a surah in rak'ahs 1 and
/// 2, Al-Fatiha only in rak'ahs 3 and 4 ([Prayer.hasSurah]).
///
/// ## Keeping count (the rule: silence when the count is in doubt)
///
/// The anchors keep the rak'ah count: a rak'ah's standing part is closed by
/// a prostration, and the next qiyam needs a confirmed standing after one.
/// Rak'ah 3 needs the middle sitting as its anchor. Rak'ah 1 is only ever
/// entered from waiting or takbir, so a later standing can never be taken
/// for rak'ah 1, and a rak'ah-3 or rak'ah-4 qiyam can only follow a
/// rak'ah-2 sujood.
///
/// * **Middle sitting not confirmed.** Standing for 0.8 s in sujood of
///   rak'ah 2 (N > 2) without the 3 s sitting (a short or unseen middle
///   tashahhud) enters qiyam of rak'ah 3 *silently*: the user is most likely
///   in rak'ah 3 (so the count goes on and rak'ah 4 can still recite), but
///   without the anchor the machine cannot rule out that it counted one
///   rak'ah too many, so rak'ah 3 is not recited. If it did over-count, the
///   real middle sitting shows up later as a long sitting where none
///   belongs and makes the count uncertain (next point).
/// * **A long sitting where none belongs.** Sitting held [longSittingMs]
///   (8 s, gaps tolerated as for the other sitting holds) in sujood of a
///   rak'ah k < N other than the middle sitting's (k = 2 < N) means a
///   tashahhud the machine did not expect: it has lost a rak'ah (e.g. all
///   prostrations of an earlier rak'ah unseen, or a session started in the
///   middle of the prayer). A jalsa or a brief sitting before standing is
///   well under 8 s.
/// * **Untrusted entry (N > 2).** Entering the count from waiting without
///   the takbir is trusted (rak'ah 1 silent, the rest recite) only when the
///   user was first seen standing: a standing hold of 0.8 s in waiting
///   before any sitting or prostrating hold (0.5 s), and none since, then
///   bowing. A prostration in waiting, or a bow after a sitting or
///   prostration or without a standing seen first, may be a session started
///   mid-prayer (e.g. in rak'ah 2's sujood, so the middle tashahhud would
///   be taken for a jalsa and getting up after the salam for a qiyam): the
///   count is uncertain from the start. (Fajr keeps entering rak'ah 1's
///   sujood from a prostration; a late start there shows up as a long
///   sitting where none belongs.)
/// * **A second ruku in itidal.** A whole second ruku cycle in itidal:
///   standing held 0.5 s ([itidalStandMs]), then bowing held
///   [secondRukuMs] (1.2 s, with the ruku hip check), then standing held
///   0.5 s again, all before any prostration. It means the prostrations of
///   that rak'ah were missed and the user is already in the next rak'ah. A
///   bow on the way down to sujood (a hands-first descent, ~0.5-1 s with
///   the hips high) or after a standing flicker in ruku never stands up
///   again, so it is ignored.
/// * **Long blindness mid-prayer.** Tracking returning after more than
///   [countLostMs] (8 s) with no person seen, while in takbir, qiyam, ruku,
///   itidal, sujood or middleSitting: a whole rak'ah's standing part or
///   prostrations may have passed unseen.
///
/// Once the count is uncertain ([countUncertain]) the machine keeps
/// tracking states and rak'ahs as above, but emits no further
/// [StartRecitation] for the rest of the session (a recitation already open
/// is unaffected; none is open in these situations). Missing a recitation is
/// acceptable; reciting Al-Fatiha in what is really a sitting, an i'tidal or
/// after the salam is not.
///
/// **Takbir guard.** A takbir raise in waiting within [takbirAfterLowMs]
/// (5 s) of a smoothed sitting or prostrating reading is ignored: it is the
/// hand raise of someone standing up from a sitting (the middle tashahhud of
/// a prayer already under way when the session started), not the opening
/// takbir, which is said standing.
///
/// **Known limit.** The machine trusts [prayer]. If the user prays fewer
/// rak'ahs than the prayer has (e.g. 2 in a session started as Dhuhr), the
/// final tashahhud looks like the middle one, and getting up after the salam
/// is taken for qiyam 3 (Al-Fatiha). The UI must make the chosen prayer
/// clear. Praying more rak'ahs than N plays nothing after rak'ah N.
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
///   When the last body data already showed the torso tilting past
///   [leanPauseTorsoDeg] (12 degrees, inside the standing limits but more
///   than a person stands), the pause comes after [leanPauseMs] (0.3 s)
///   instead: the user may be starting to bow just as the camera loses
///   them, and 0.6 s plus the time to notice would let the audio play into
///   the ruku.
///
/// While paused:
///
/// * Body data arriving after a blind span longer than [maxResumeBlindMs]
///   (1.5 s, measured from the last body data, before the pause or during
///   it, to this reading) emits [StopRecitation]: a fast ruku and i'tidal
///   fit in about 2 s, so the standing now seen may be the i'tidal.
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
///   with `SessionEnded(completed)`. A long middle tashahhud is a state like
///   any other: over 180 s ends the session.
///
/// After [SessionEnded], [add] returns no more events until [reset], and
/// the [run] stream closes.
///
/// ## Ambiguities resolved (the rule: never play audio at the wrong time)
///
/// * **Prostration from waiting** enters sujood of rak'ah 1 (takbir and
///   ruku both missed). Otherwise the user's real rak'ah 2 would be counted
///   as rak'ah 1 and getting up after the salam would start a recitation.
/// * **Bowing from sujood or middleSitting** enters the next ruku without
///   audio (its qiyam too short or unseen): silence, never a late start.
/// * **I'tidal** needs no hold (the spec gives none and it has no audio);
///   **getting up from finalSitting** uses the 0.8 s standing hold.
/// * **A final tashahhud the 5 s hold never confirms** (dropouts adding up
///   to more than 1 s): sitting held 3 s (gaps tolerated) after the last
///   prostration of rak'ah N, then standing held 0.8 s, is getting up after
///   the salam: the final sitting is filled in (a zero-length state at the
///   same `tMs`) and the session is done. Without this the session would wait in sujood until
///   the 180 s timeout. Standing in the last sujood without such a sitting
///   (an extra rak'ah) still changes nothing.
/// * **"Sitting lasts over 180 s"** is measured from entering finalSitting.
/// * **A long jalsa in rak'ah 2** (N > 2) may enter middleSitting before the
///   second prostration; that prostration is ignored and qiyam 3 still needs
///   a confirmed standing after it.
/// * **Out of order timestamps** are clamped to the previous reading's time.
class SalahStateMachine implements PrayerStateMachine {
  /// The prayer being followed; sets the rak'ah count N.
  final Prayer prayer;

  /// Standing hold after the takbir that enters qiyam1 (spec: 0.8 s).
  final int qiyam1HoldMs;

  /// Standing hold after a prostration (or the middle sitting) that enters
  /// the qiyam of rak'ah 2, 3 or 4 (spec: 0.8 s).
  final int qiyamHoldMs;

  /// Sitting hold after a rak'ah-2 prostration that enters the middle
  /// sitting of a 3- or 4-rak'ah prayer (3 s; gaps tolerated as for the
  /// final sitting).
  final int middleSittingHoldMs;

  /// Sitting held this long in sujood where no tashahhud belongs makes the
  /// rak'ah count uncertain (8 s; gaps tolerated as for the final sitting).
  final int longSittingMs;

  /// Bowing held this long in itidal, after a standing i'tidal of
  /// [itidalStandMs] and followed by standing again for [itidalStandMs]
  /// before any prostration, is a second ruku: the prostrations of the
  /// rak'ah were missed and the count is uncertain (1.2 s).
  final int secondRukuMs;

  /// Standing held in itidal before a second ruku can count, and again after
  /// it (0.5 s).
  final int itidalStandMs;

  /// Sitting (gaps tolerated) held this long after the prostrations of the
  /// last rak'ah, then standing held [finalStandHoldMs], ends the session as
  /// done even if the final sitting was never confirmed (3 s).
  final int finalStandAfterSitMs;

  /// Tracking returning after more than this without a person, mid-prayer,
  /// makes the rak'ah count uncertain (8 s).
  final int countLostMs;

  /// A takbir raise this soon after a sitting or prostrating reading is not
  /// the opening takbir (5 s).
  final int takbirAfterLowMs;

  /// Bowing hold that confirms Ruku (spec: 0.5 s).
  final int rukuHoldMs;

  /// Prostrating hold that confirms Sujood (spec: 0.5 s).
  final int sujoodHoldMs;

  /// Sitting hold after a prostration of the last rak'ah that enters the
  /// final sitting (spec: 5 s).
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

  /// Raw torso angle above which the last body data before a blind spot
  /// shortens the pause to [leanPauseMs] (12 degrees).
  final double leanPauseTorsoDeg;

  /// No body data for longer than this after body data with the torso past
  /// [leanPauseTorsoDeg] pauses a playing recitation (0.3 s).
  final int leanPauseMs;

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

  SalahStateMachine({
    this.prayer = Prayer.fajr,
    this.qiyam1HoldMs = 800,
    this.qiyamHoldMs = 800,
    this.middleSittingHoldMs = 3000,
    this.longSittingMs = 8000,
    this.secondRukuMs = 1200,
    this.itidalStandMs = 500,
    this.finalStandAfterSitMs = 3000,
    this.countLostMs = 8000,
    this.takbirAfterLowMs = 5000,
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
    this.leanPauseTorsoDeg = 12,
    this.leanPauseMs = 300,
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
    positive(qiyamHoldMs, 'qiyamHoldMs');
    positive(middleSittingHoldMs, 'middleSittingHoldMs');
    positive(longSittingMs, 'longSittingMs');
    positive(secondRukuMs, 'secondRukuMs');
    positive(itidalStandMs, 'itidalStandMs');
    positive(finalStandAfterSitMs, 'finalStandAfterSitMs');
    positive(countLostMs, 'countLostMs');
    if (takbirAfterLowMs < 0) {
      throw ArgumentError.value(
          takbirAfterLowMs, 'takbirAfterLowMs', 'must not be negative');
    }
    positive(rukuHoldMs, 'rukuHoldMs');
    positive(sujoodHoldMs, 'sujoodHoldMs');
    positive(finalSittingHoldMs, 'finalSittingHoldMs');
    positive(finalStandHoldMs, 'finalStandHoldMs');
    positive(finalSittingMaxMs, 'finalSittingMaxMs');
    positive(finalSittingOutOfFrameMs, 'finalSittingOutOfFrameMs');
    positive(earlyStopHoldMs, 'earlyStopHoldMs');
    positive(blindPauseMs, 'blindPauseMs');
    positive(leanPauseMs, 'leanPauseMs');
    if (!(leanPauseTorsoDeg > 0 && leanPauseTorsoDeg <= leanTorsoDeg)) {
      throw ArgumentError.value(leanPauseTorsoDeg, 'leanPauseTorsoDeg',
          'must be in (0, leanTorsoDeg]');
    }
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
  int _rakah = 0;
  bool _uncertain = false;
  int? _lastLowMs; // last smoothed sitting or prostrating reading
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
  final Set<int> _started = {};
  _Audio _audio = _Audio.none;
  int _audioRakah = 0;
  int _audioSinceMs = 0; // last Start, Resume or Pause
  int? _leaveStartMs; // run of body data showing left standing
  int? _leanStartMs; // run of body data leaning past leanTorsoDeg (or leaving)
  int? _standStartMs; // run of standing body data while paused
  int? _lastRawMs; // last reading with body data
  double? _lastRawTorso; // its torso angle
  bool _hipSeen = false; // some reading had a hip height ratio (calibrated)

  // Sitting hold in sujood (-> middleSitting or finalSitting), tolerating
  // short gaps.
  int? _sitStartMs;
  int _sitGapMs = 0;

  // Itidal: a standing i'tidal seen, then a second ruku held (see
  // [secondRukuMs]).
  bool _itidalStood = false;
  bool _itidalBowed = false;

  // Sujood of the last rak'ah: sitting held [finalStandAfterSitMs].
  bool _satAfterLast = false;

  // Waiting: a sitting or prostrating hold seen, and a standing hold seen
  // before any.
  bool _waitLow = false;
  bool _stoodFirst = false;

  /// The current state.
  PrayerState get state => _state;

  /// The current rak'ah: 0 in waiting and takbir, then 1..N.
  int get rakah => _rakah;

  /// True once the rak'ah count is in doubt (see the class docs): no
  /// recitation starts for the rest of the session.
  bool get countUncertain => _uncertain;

  /// True while tracking is lost.
  bool get frozen => _frozen;

  /// True once [SessionEnded] has been emitted.
  bool get ended => _ended;

  /// Clears all state, as at the start of a session.
  void reset() {
    _state = PrayerState.waiting;
    _rakah = 0;
    _uncertain = false;
    _lastLowMs = null;
    _lastT = null;
    _stateEnteredMs = 0;
    _lastSeenMs = 0;
    _frozen = false;
    _lostAtMs = 0;
    _ended = false;
    _runPosture = null;
    _runStartMs = 0;
    _started.clear();
    _audio = _Audio.none;
    _audioRakah = 0;
    _audioSinceMs = 0;
    _leaveStartMs = null;
    _leanStartMs = null;
    _standStartMs = null;
    _lastRawMs = null;
    _lastRawTorso = null;
    _hipSeen = false;
    _sitStartMs = null;
    _sitGapMs = 0;
    _itidalStood = false;
    _itidalBowed = false;
    _satAfterLast = false;
    _waitLow = false;
    _stoodFirst = false;
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
      final unseenMs = t - _lastSeenMs;
      _lastSeenMs = t;
      if (_frozen) {
        _frozen = false;
        if (unseenMs > countLostMs && _countingState) _uncertain = true;
        _runPosture = null; // every hold restarts from this reading
        _sitStartMs = null;
        _sitGapMs = 0;
        out.add(TrackingRestored(t));
      }
    }

    if (r.posture == Posture.sitting || r.posture == Posture.prostrating) {
      _lastLowMs = t;
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
    if (hasRaw) {
      _lastRawMs = t;
      _lastRawTorso = r.torsoAngleDeg;
    }
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
        _blindFor(t) > _pauseAfterMs) {
      _audio = _Audio.paused;
      _audioSinceMs = t;
      _standStartMs = null;
      out.add(PauseRecitation(t, rakah: _audioRakah));
    }
  }

  /// Blind time after which a playing recitation pauses: [leanPauseMs] when
  /// the last body data showed the torso past [leanPauseTorsoDeg], else
  /// [blindPauseMs].
  int get _pauseAfterMs {
    final torso = _lastRawTorso;
    return torso != null && torso > leanPauseTorsoDeg
        ? leanPauseMs
        : blindPauseMs;
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

  /// Tracks a sitting hold in sujood at [t] and returns how long sitting
  /// has been held, or -1 (counted from entering sujood at the earliest;
  /// call once per reading). Unknown or blind readings for at most
  /// [finalSittingGapMs] in total do not restart it; any other posture
  /// (standing, bowing, prostrating) does. The hold only ends on a sitting
  /// reading: on an unknown one this returns -1.
  int _sittingFor(PostureReading r, int t, int dt) {
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
      return -1;
    }
    final from = start > _stateEnteredMs ? start : _stateEnteredMs;
    return _holdKey(r) == Posture.sitting ? t - from : -1;
  }

  /// States in which a long blindness may hide a change of rak'ah.
  bool get _countingState => switch (_state) {
        PrayerState.takbir ||
        PrayerState.qiyam ||
        PrayerState.ruku ||
        PrayerState.itidal ||
        PrayerState.sujood ||
        PrayerState.middleSitting =>
          true,
        _ => false,
      };

  void _advance(PostureReading r, int t, int dt, List<PrayerEvent> out) {
    bool held(Posture p, int ms) => _held(p, t) >= ms;
    final bowing = held(Posture.bowing, rukuHoldMs);
    final prostrating = held(Posture.prostrating, sujoodHoldMs);
    final n = prayer.rakahCount;
    final k = _rakah;
    switch (_state) {
      case PrayerState.waiting:
        final low = _lastLowMs;
        if (held(Posture.sitting, sujoodHoldMs) ||
            held(Posture.prostrating, sujoodHoldMs)) {
          _waitLow = true;
        } else if (!_waitLow && held(Posture.standing, qiyam1HoldMs)) {
          _stoodFirst = true;
        }
        if (r.takbirRaise && (low == null || t - low > takbirAfterLowMs)) {
          _go(PrayerState.takbir, t, out);
        } else if (bowing) {
          // Missed takbir. Trusted (rak'ah 1 silent, the rest recite) only
          // if the user was seen standing before any sitting or prostration.
          if (n > 2 && (!_stoodFirst || _waitLow)) _uncertain = true;
          _go(PrayerState.ruku, t, out, rakah: 1);
        } else if (prostrating) {
          // Takbir and ruku unseen: the session may have started mid-prayer.
          if (n > 2) _uncertain = true;
          _fillTo(1, t, out);
        }
      case PrayerState.takbir:
        if (held(Posture.standing, qiyam1HoldMs)) {
          _enterQiyam(1, t, out);
        } else if (bowing) {
          _go(PrayerState.ruku, t, out, rakah: 1);
        } else if (prostrating) {
          _fillTo(1, t, out);
        }
      case PrayerState.qiyam:
        if (bowing) {
          _go(PrayerState.ruku, t, out);
        } else if (prostrating) {
          _fillTo(k, t, out);
        }
      case PrayerState.ruku:
        if (r.posture == Posture.standing) {
          _go(PrayerState.itidal, t, out);
        } else if (prostrating) {
          _fillTo(k, t, out);
        }
      case PrayerState.itidal:
        if (prostrating) {
          _go(PrayerState.sujood, t, out);
        } else if (!_itidalStood) {
          _itidalStood = held(Posture.standing, itidalStandMs);
        } else if (!_itidalBowed) {
          _itidalBowed = held(Posture.bowing, secondRukuMs);
        } else if (held(Posture.standing, itidalStandMs)) {
          // A whole second ruku cycle: this rak'ah's prostrations unseen.
          // (A hands-first descent bows on the way down, but never stands
          // up again before prostrating.)
          _uncertain = true;
        }
      case PrayerState.sujood:
        final sat = _sittingFor(r, t, dt);
        if (k >= n) {
          if (sat >= finalStandAfterSitMs) {
            _satAfterLast = true;
          } else if (prostrating) {
            _satAfterLast = false; // only a sitting after the last prostration
          }
          if (sat >= finalSittingHoldMs) {
            _go(PrayerState.finalSitting, t, out);
          } else if (_satAfterLast &&
              held(Posture.standing, finalStandHoldMs)) {
            // A final sitting too gappy to confirm, then getting up: fill
            // the final sitting in (zero length), then done.
            _go(PrayerState.finalSitting, t, out);
            _finish(out, t);
          }
        } else if (k == 2 && prayer.hasMiddleSitting) {
          if (sat >= middleSittingHoldMs) {
            _go(PrayerState.middleSitting, t, out);
          } else if (held(Posture.standing, qiyamHoldMs)) {
            // No confirmed middle sitting: count on, but stay silent.
            _enterQiyam(3, t, out, silent: true);
          } else if (bowing) {
            _go(PrayerState.ruku, t, out, rakah: 3);
          }
        } else if (held(Posture.standing, qiyamHoldMs)) {
          _enterQiyam(k + 1, t, out);
        } else if (bowing) {
          _go(PrayerState.ruku, t, out, rakah: k + 1);
        } else if (sat >= longSittingMs) {
          _uncertain = true; // a tashahhud where none belongs
        }
      case PrayerState.middleSitting:
        if (held(Posture.standing, qiyamHoldMs)) {
          _enterQiyam(3, t, out);
        } else if (bowing) {
          _go(PrayerState.ruku, t, out, rakah: 3);
        }
      case PrayerState.finalSitting:
        if (held(Posture.standing, finalStandHoldMs)) _finish(out, t);
      case PrayerState.done:
        break;
    }
  }

  /// Enters the qiyam of [rakah] and, unless [silent], the count is
  /// uncertain or it already started, its recitation.
  void _enterQiyam(int rakah, int t, List<PrayerEvent> out,
      {bool silent = false}) {
    _go(PrayerState.qiyam, t, out, rakah: rakah);
    if (_started.add(rakah) && !silent && !_uncertain) {
      _startRecitation(out, t, rakah);
    }
  }

  /// Enters sujood of [rakah] from an earlier state, filling in a missed
  /// Ruku and I'tidal with zero-length transitions at [t], so the emitted
  /// chain always reads ... -> ruku -> itidal -> sujood.
  void _fillTo(int rakah, int t, List<PrayerEvent> out) {
    if (_state != PrayerState.ruku) {
      _go(PrayerState.ruku, t, out, rakah: rakah);
    }
    _go(PrayerState.itidal, t, out);
    _go(PrayerState.sujood, t, out);
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

  void _go(PrayerState to, int t, List<PrayerEvent> out, {int? rakah}) {
    // Leaving a Qiyam ends its recitation, playing or paused.
    _stop(out, t);
    final from = _state;
    _state = to;
    if (rakah != null) _rakah = rakah;
    _stateEnteredMs = t;
    _sitStartMs = null;
    _sitGapMs = 0;
    _itidalStood = false;
    _itidalBowed = false;
    _satAfterLast = false;
    final reported = switch (to) {
      PrayerState.waiting || PrayerState.takbir => 0,
      _ => _rakah,
    };
    out.add(StateChanged(t, from: from, to: to, rakah: reported));
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
}

/// The open recitation, if any.
enum _Audio { none, playing, paused }
