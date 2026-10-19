/// End-to-end replay harness: a labelled recording is run frame by frame
/// through [RuleBasedClassifier] -> [MajoritySmoother] -> [FajrStateMachine]
/// and the emitted events are scored against the ground-truth labels. See
/// docs/SPEC.md, section "Pose detection and classification" -> "Accuracy
/// targets", and docs/recording-format.md (labels are ground truth).
///
/// ## Clock
///
/// Frames are fed in file order. Heartbeats are inserted exactly as the
/// engine emits them (docs/SPEC.md section 5, [PoseFrame.heartbeat]): only
/// after [defaultHeartbeatMs] with no camera frame, stamped
/// `lastFrameT + k * 100` on the sensor clock for k = 1, 2, ... while that
/// is strictly before the next frame's `tMs`, and never interleaved with
/// frames (a frame resets the heartbeat clock). So frames 100 ms apart get
/// no heartbeat, 150 ms apart one. Heartbeats go through the classifier too
/// (it returns an unknown reading with no raw values), exactly like the
/// app's data flow. A recorded frame with `people: []` is a camera frame in
/// which no person was detected: it is fed as a frame (an unknown reading)
/// and resets the heartbeat clock like any other frame; it is not a gap.
/// (A heartbeat written into the recording, also `people: []`, see
/// docs/recording-format.md, is fed the same way and gives the same unknown
/// reading as an inserted one.) Nothing is fed after the last frame.
///
/// ## Scoring
///
/// *Qiyam runs* are the maximal runs of touching label intervals with the
/// same state `qiyam1` or `qiyam2` (posture is ignored: an `unknown` or
/// qunut frame inside a qiyam is still qiyam). Time not covered by any qiyam
/// run, including unlabelled gaps, is *outside qiyam*.
///
/// * **Wrong-time start:** a `StartRecitation(r)` whose `tMs` is not inside
///   a `qiyam{r}` run, except an *early start*: a `StartRecitation(1)` while
///   the label is `takbir` (the user standing still right after the opening
///   takbir), directly followed by a `qiyam1` run. Early starts match that
///   run, are listed in [ReplayResult.earlyStartsMs] (how long before the
///   `qiyam1` label) and are judged against the spec's rak'ah-1 latency
///   target instead: those more than [ReplayOptions.takbirToleranceMs]
///   (0.3 s) early are counted in [ReplayResult.earlyBeyondTolerance].
///   [ReplayOptions.strict] scores them as wrong-time starts instead.
///
///   Why: the labels put the takbir event where the hands are back at rest
///   and keep `takbir` for a fixed 800 ms of standing after it (a copy of
///   the machine's hold, not a movement), while the classifier fires the
///   event once the smoothed wrist height has dropped 0.17 torso lengths
///   from its peak, i.e. during the lowering (measured on the 520-prayer
///   batch, seed 7777: up to ~290 ms before the label, median ~85 ms; a few
///   fire up to ~310 ms after it). The machine's 0.8 s hold
///   therefore ends up to ~0.3 s before the labelled `qiyam1`. The user is
///   already standing in the prayer, the SessionController still plays the
///   opening-dua pause first, and the spec's target for this is "takbir
///   confirmed to Al-Fatiha start: opening-dua pause +/- 0.3 s".
/// * **Playing:** a recitation is *open* from its `StartRecitation` until the
///   next `StopRecitation` or `SessionEnded` (or the last fed reading if
///   neither comes), and *plays* (is audible) from its `StartRecitation` or a
///   `ResumeRecitation` until the next `PauseRecitation`, `StopRecitation` or
///   `SessionEnded`. Paused time is silent and never scored as wrong-time.
/// * **Overrun (still playing):** every stretch of playing time outside
///   qiyam counts beyond a grace of [ReplayOptions.graceMs] (default 500 ms)
///   after the label left qiyam. The grace covers the labels putting the
///   qiyam end at the first frame of the bow while the machine needs 0.2 s
///   of raw data to stop (measured p90 about 0.26 s); the spec's "bowing to
///   silence" target is 1.0 s. [ReplayResult.overrunsAtZeroGrace] counts the
///   same stretches with no grace at all: reported, never gating. Playing
///   time of an early rak'ah-1 start before the `qiyam1` run it matched is
///   not counted (it is judged by the latency target instead). The
///   stretch's "left
///   qiyam" moment is the end of the qiyam run just before it (if that ended
///   after the recitation started), or else the stretch start (a start or
///   resume outside qiyam, which is already wrong-time).
/// * **Resumed outside qiyam:** a `ResumeRecitation(r)` whose `tMs` is not
///   inside a `qiyam{r}` run (the labelled takbir standing just before the
///   run an early start matched also counts as inside, as for starts, unless
///   [ReplayOptions.strict]). Wrong-time audio, like a wrong-time start.
/// * **Missed qiyam:** a `qiyam{r}` run with no `StartRecitation(r)` inside
///   it. `qiyam1` runs count only when the labels have a takbir event (the
///   spec: "no recitation when the user stood after a detected takbir or
///   prostration"); the eligible runs are the rak'ahs counted.
/// * **Start latency** (per rak'ah): `StartRecitation(r).tMs` minus the start
///   of the first `qiyam{r}` run. Signed. The opening-dua and 1.5 s pauses
///   belong to the SessionController and are not included.
/// * **Stop latency** (per recitation): the end of its last playing stretch
///   (the moment it went silent for good: the final pause or the stop) minus
///   the end of the qiyam run the recitation started in (or the first one
///   that starts after it). Signed. A recitation whose `StopRecitation`
///   (final, no resume possible) comes more than [ReplayOptions.cutShortMs]
///   (1 s) before the label leaves qiyam is counted as a *premature stop* (audio
///   cut short while the user was still in qiyam, not wrong-time).
/// * **Rak'ah count:** the machine reached `finalSitting` (and so rak'ah 2)
///   exactly when the labels contain `finalSitting`.
library;

import 'classifier.dart';
import 'pose.dart';
import 'posture.dart';
import 'prayer.dart';
import 'recording.dart';
import 'smoother.dart';
import 'state_machine.dart';

/// Heartbeat period of the real engine.
const int defaultHeartbeatMs = 100;

/// Default overrun grace (see the library docs).
const int defaultGraceMs = 500;

/// The spec's rak'ah-1 tolerance: "takbir confirmed to Al-Fatiha start:
/// opening-dua pause +/- 0.3 s".
const int defaultTakbirToleranceMs = 300;

/// Knobs for [replay].
class ReplayOptions {
  /// Gap after which heartbeats are inserted, and their period.
  final int heartbeatMs;

  /// Grace after the label leaves qiyam before a still-playing recitation
  /// counts as wrong-time audio (the spec's bowing-to-silence target is
  /// 1.0 s; the harness gates at half that).
  final int graceMs;

  /// An early rak'ah-1 start (see the library docs) more than this before
  /// the labelled `qiyam1` misses the spec's rak'ah-1 latency target.
  final int takbirToleranceMs;

  /// A final stop more than this before the label leaves qiyam counts as a
  /// premature stop (audio cut short; not wrong-time).
  final int cutShortMs;

  /// Score early rak'ah-1 starts as wrong-time starts.
  final bool strict;

  /// Keep every smoothed reading in [ReplayResult.readings] (for diagnosis).
  final bool keepReadings;

  const ReplayOptions({
    this.heartbeatMs = defaultHeartbeatMs,
    this.graceMs = defaultGraceMs,
    this.takbirToleranceMs = defaultTakbirToleranceMs,
    this.cutShortMs = 1000,
    this.strict = false,
    this.keepReadings = false,
  });
}

/// A recitation that started outside its own qiyam.
class WrongStart {
  final int tMs;
  final int rakah;

  /// The labelled state at [tMs], null when unlabelled.
  final PrayerState? labelState;

  const WrongStart(this.tMs, this.rakah, this.labelState);

  @override
  String toString() =>
      'WrongStart(rakah $rakah at $tMs ms, label ${labelState?.name})';
}

/// A recitation still playing outside qiyam beyond the grace.
class Overrun {
  final int rakah;

  /// When the label left qiyam (or the window start, see library docs).
  final int leftQiyamMs;

  /// When playback stopped (or the stretch outside qiyam ended).
  final int untilMs;

  /// Time beyond the grace.
  final int overrunMs;

  /// The labelled state just after [leftQiyamMs].
  final PrayerState? labelState;

  const Overrun(this.rakah, this.leftQiyamMs, this.untilMs, this.overrunMs,
      this.labelState);

  @override
  String toString() => 'Overrun(rakah $rakah, left qiyam $leftQiyamMs ms -> '
      '$untilMs ms, +$overrunMs ms over grace, label ${labelState?.name})';
}

/// A labelled qiyam run.
class QiyamRun {
  final int rakah;
  final int startMs;
  final int endMs;
  const QiyamRun(this.rakah, this.startMs, this.endMs);

  bool contains(int tMs) => tMs >= startMs && tMs < endMs;

  @override
  String toString() => 'qiyam$rakah [$startMs, $endMs)';
}

/// The outcome of one [replay].
class ReplayResult {
  final String name;

  /// Every event the state machine emitted, in order.
  final List<PrayerEvent> events;

  /// Smoothed readings fed to the machine (only with
  /// [ReplayOptions.keepReadings]).
  final List<PostureReading> readings;

  final int frames;
  final int heartbeats;

  /// Qiyam runs eligible for the missed-qiyam count (the rak'ahs counted).
  final List<QiyamRun> eligibleQiyam;
  final List<WrongStart> wrongStarts;

  /// For each early rak'ah-1 start, how long before the `qiyam1` label.
  final List<int> earlyStartsMs;
  final List<Overrun> overruns;

  /// The same playing stretches outside qiyam as [overruns], counted with no
  /// grace at all (any audio past the label). Reported, not wrong-time.
  final List<Overrun> overrunsAtZeroGrace;

  /// Resumes outside their own qiyam (wrong-time audio).
  final List<WrongStart> wrongResumes;

  /// Every PauseRecitation / ResumeRecitation emitted.
  final int pauses;
  final int resumes;
  final List<QiyamRun> missed;
  final int takbirToleranceMs;

  /// Label qiyam start -> StartRecitation, per rak'ah (1, 2); absent when
  /// there was no start or no labelled qiyam of that rak'ah.
  final Map<int, int> startLatencyMs;

  /// First `standing`-labelled instant of the first `qiyam{r}` run ->
  /// StartRecitation(r), per rak'ah: the spec's "steady standing to
  /// Al-Fatiha start" (the label switches to qiyam2 at the middle of the
  /// rise, standing starts at 80 % of it).
  final Map<int, int> startFromStandingMs;

  /// Label leaving qiyam -> StopRecitation, per rak'ah.
  final Map<int, int> stopLatencyMs;

  /// Stops more than [ReplayOptions.cutShortMs] before the label left
  /// qiyam.
  final int prematureStops;

  final bool reachedFinal;
  final bool expectedFinal;
  final PrayerState finalState;
  final EndReason? endReason;

  const ReplayResult({
    required this.name,
    required this.events,
    required this.readings,
    required this.frames,
    required this.heartbeats,
    required this.eligibleQiyam,
    required this.wrongStarts,
    required this.earlyStartsMs,
    required this.overruns,
    this.overrunsAtZeroGrace = const [],
    required this.wrongResumes,
    required this.pauses,
    required this.resumes,
    required this.missed,
    required this.takbirToleranceMs,
    required this.startLatencyMs,
    required this.startFromStandingMs,
    required this.stopLatencyMs,
    required this.prematureStops,
    required this.reachedFinal,
    required this.expectedFinal,
    required this.finalState,
    required this.endReason,
  });

  /// Any recitation starting, resuming, or still playing, outside qiyam.
  bool get wrongTimeAudio =>
      wrongStarts.isNotEmpty || overruns.isNotEmpty || wrongResumes.isNotEmpty;

  /// The longest overrun beyond the grace, 0 if none.
  int get worstOverrunMs =>
      overruns.fold(0, (m, o) => o.overrunMs > m ? o.overrunMs : m);

  bool get rakahCountOk => reachedFinal == expectedFinal;

  /// Early rak'ah-1 starts beyond the spec's tolerance.
  int get earlyBeyondTolerance =>
      earlyStartsMs.where((e) => e > takbirToleranceMs).length;

  /// One-line description of everything that went wrong, empty if nothing.
  String get problems => [
        ...wrongStarts.map((w) => '$w'),
        ...overruns.map((o) => '$o'),
        ...wrongResumes.map((w) => 'resumed outside qiyam: $w'),
        ...missed.map((m) => 'missed $m'),
        for (final e in earlyStartsMs)
          if (e > takbirToleranceMs) 'rakah 1 started $e ms before qiyam1',
        if (!rakahCountOk)
          'final sitting ${reachedFinal ? 'reached' : 'not reached'} '
              '(state ${finalState.name}, end ${endReason?.name})',
      ].join('; ');
}

/// Runs [recording] through the pipeline and scores it against [labels].
///
/// Fresh pipeline modules are used unless given; given ones are reset first.
ReplayResult replay(
  Recording recording,
  LabelSet labels, {
  String? name,
  RuleBasedClassifier? classifier,
  MajoritySmoother? smoother,
  FajrStateMachine? machine,
  ReplayOptions options = const ReplayOptions(),
}) {
  final c = classifier ?? RuleBasedClassifier();
  final s = smoother ?? MajoritySmoother();
  final m = machine ?? FajrStateMachine();
  c.reset();
  s.reset();
  m.reset();

  final events = <PrayerEvent>[];
  final readings = <PostureReading>[];
  var heartbeats = 0;
  var lastT = 0;
  var frameCount = 0;

  bool feed(PoseFrame f) {
    final smoothed = s.add(c.classify(f));
    if (options.keepReadings) readings.add(smoothed);
    events.addAll(m.add(smoothed));
    lastT = f.tMs;
    return m.ended;
  }

  int? prev;
  for (final f in recording.frames) {
    if (prev != null) {
      // A heartbeat at every multiple of heartbeatMs after the previous
      // frame that comes strictly before the next frame.
      for (var t = prev + options.heartbeatMs;
          t < f.tMs;
          t += options.heartbeatMs) {
        heartbeats++;
        if (feed(PoseFrame.heartbeat(t,
            imageW: recording.header.imageW,
            imageH: recording.header.imageH))) {
          break;
        }
      }
      if (m.ended) break;
    }
    frameCount++;
    if (feed(f)) break;
    prev = f.tMs;
  }

  return score(labels, events,
      name: name ?? labels.recording,
      endMs: lastT,
      graceMs: options.graceMs,
      cutShortMs: options.cutShortMs,
      takbirToleranceMs: options.takbirToleranceMs,
      strict: options.strict,
      readings: readings,
      frames: frameCount,
      heartbeats: heartbeats,
      finalState: m.state);
}

/// Merges touching label intervals with the same qiyam state.
List<QiyamRun> qiyamRuns(LabelSet labels) {
  final out = <QiyamRun>[];
  for (final iv in labels.intervals) {
    final r = switch (iv.state) {
      PrayerState.qiyam1 => 1,
      PrayerState.qiyam2 => 2,
      _ => 0,
    };
    if (r == 0) continue;
    if (out.isNotEmpty && out.last.rakah == r && out.last.endMs == iv.startMs) {
      out[out.length - 1] = QiyamRun(r, out.last.startMs, iv.endMs);
    } else {
      out.add(QiyamRun(r, iv.startMs, iv.endMs));
    }
  }
  return out;
}

/// Scores [events] against [labels]. [endMs] is the time of the last reading
/// fed (a recitation with no stop plays until then).
ReplayResult score(
  LabelSet labels,
  List<PrayerEvent> events, {
  required String name,
  required int endMs,
  int graceMs = defaultGraceMs,
  int cutShortMs = 1000,
  int takbirToleranceMs = defaultTakbirToleranceMs,
  bool strict = false,
  List<PostureReading> readings = const [],
  int frames = 0,
  int heartbeats = 0,
  PrayerState? finalState,
}) {
  final runs = qiyamRuns(labels);
  QiyamRun? runAt(int t) {
    for (final q in runs) {
      if (q.contains(t)) return q;
    }
    return null;
  }

  final wrong = <WrongStart>[];
  final early = <int>[];
  final matched = <QiyamRun>{};
  final overruns = <Overrun>[];
  final overruns0 = <Overrun>[];
  final wrongResumes = <WrongStart>[];
  var pauses = 0;
  var resumes = 0;
  final startLat = <int, int>{};
  final startStd = <int, int>{};
  final stopLat = <int, int>{};
  var premature = 0;
  var reachedFinal = false;
  EndReason? endReason;
  var state = PrayerState.waiting;

  for (var i = 0; i < events.length; i++) {
    final e = events[i];
    switch (e) {
      case StateChanged(:final to):
        state = to;
        if (to == PrayerState.finalSitting) reachedFinal = true;
      case SessionEnded(:final reason):
        endReason = reason;
      case PauseRecitation():
        pauses++;
      case ResumeRecitation(:final rakah, tMs: final t):
        resumes++;
        var ok = runAt(t)?.rakah == rakah;
        if (!ok && rakah == 1 && !strict) {
          // The labelled takbir standing just before qiyam1 (early start).
          final iv = labels.intervalAt(t);
          final next = runs.where((q) => q.startMs > t).firstOrNull;
          ok = iv != null &&
              iv.state == PrayerState.takbir &&
              next != null &&
              next.rakah == 1 &&
              next.startMs == iv.endMs;
        }
        if (!ok) wrongResumes.add(WrongStart(t, rakah, labels.stateAt(t)));
      case StartRecitation(:final rakah, tMs: final t):
        var run = runAt(t);
        int? earlyRunStart;
        if (run == null && rakah == 1 && !strict) {
          final iv = labels.intervalAt(t);
          final next = runs.where((q) => q.startMs > t).firstOrNull;
          if (iv != null &&
              iv.state == PrayerState.takbir &&
              next != null &&
              next.rakah == 1 &&
              next.startMs == iv.endMs) {
            run = next;
            early.add(next.startMs - t);
            earlyRunStart = next.startMs;
          }
        }
        if (run == null || run.rakah != rakah) {
          wrong.add(WrongStart(t, rakah, labels.stateAt(t)));
        } else {
          matched.add(run);
        }
        final firstOfRakah = runs.where((q) => q.rakah == rakah).firstOrNull;
        if (firstOfRakah != null) {
          startLat[rakah] = t - firstOfRakah.startMs;
          final std = labels.intervals
              .where((iv) =>
                  iv.posture == Posture.standing &&
                  iv.endMs > firstOfRakah.startMs &&
                  iv.startMs < firstOfRakah.endMs)
              .firstOrNull;
          if (std != null) {
            final from = std.startMs > firstOfRakah.startMs
                ? std.startMs
                : firstOfRakah.startMs;
            startStd[rakah] = t - from;
          }
        }

        // Open window [t, stop) and its playing stretches.
        var stop = endMs;
        var stopped = false;
        final playing = <(int, int)>[];
        int? from = t;
        for (var j = i + 1; j < events.length; j++) {
          final x = events[j];
          if (x is StopRecitation || x is SessionEnded) {
            stop = x.tMs;
            stopped = true;
            break;
          }
          if (x is StartRecitation) {
            // Never happens (the machine stops first); close defensively.
            stop = x.tMs;
            break;
          }
          if (x is PauseRecitation && from != null) {
            playing.add((from, x.tMs));
            from = null;
          } else if (x is ResumeRecitation && from == null) {
            from = x.tMs;
          }
        }
        if (from != null) playing.add((from, stop));
        for (var (a, b) in playing) {
          // An early start's playing time in the labelled takbir standing
          // is judged by the latency target, not as an overrun.
          if (earlyRunStart != null && a < earlyRunStart) {
            if (b <= earlyRunStart) continue;
            a = earlyRunStart;
          }
          _overruns(runs, labels, rakah, t, a, b, graceMs, overruns);
          _overruns(runs, labels, rakah, t, a, b, 0, overruns0);
        }

        // Stop latency against the run it started in (or the next one).
        final own = run ?? runs.where((q) => q.startMs > t).firstOrNull;
        if (stopped && own != null) {
          final silent = playing.isEmpty ? stop : playing.last.$2;
          stopLat[rakah] = silent - own.endMs;
          if (stop - own.endMs < -cutShortMs) premature++;
        }
      default:
        break;
    }
  }

  final hasTakbir = labels.takbirTimesMs.isNotEmpty;
  final eligible = [
    for (final q in runs)
      if (q.rakah == 2 || hasTakbir) q,
  ];
  final missed = [
    for (final q in eligible)
      if (!matched.contains(q)) q,
  ];

  return ReplayResult(
    name: name,
    events: List.unmodifiable(events),
    readings: List.unmodifiable(readings),
    frames: frames,
    heartbeats: heartbeats,
    eligibleQiyam: eligible,
    wrongStarts: wrong,
    earlyStartsMs: early,
    takbirToleranceMs: takbirToleranceMs,
    overruns: overruns,
    overrunsAtZeroGrace: overruns0,
    wrongResumes: wrongResumes,
    pauses: pauses,
    resumes: resumes,
    missed: missed,
    startLatencyMs: startLat,
    startFromStandingMs: startStd,
    stopLatencyMs: stopLat,
    prematureStops: premature,
    reachedFinal: reachedFinal,
    expectedFinal:
        labels.intervals.any((iv) => iv.state == PrayerState.finalSitting),
    finalState: finalState ?? state,
    endReason: endReason,
  );
}

/// Adds the overruns of a recitation (started at [recStart]) playing over
/// [start, stop).
void _overruns(List<QiyamRun> runs, LabelSet labels, int rakah, int recStart,
    int start, int stop, int graceMs, List<Overrun> out) {
  // Walk the stretches of [start, stop) outside every qiyam run.
  var t = start;
  while (t < stop) {
    final inRun = runs.where((q) => q.contains(t)).firstOrNull;
    if (inRun != null) {
      t = inRun.endMs;
      continue;
    }
    final next = runs.where((q) => q.startMs > t).firstOrNull;
    final outEnd = next == null || next.startMs > stop ? stop : next.startMs;
    final before = runs.where((q) => q.endMs <= t).lastOrNull;
    final left = before != null && before.endMs > recStart ? before.endMs : t;
    // Only playing time counts: from the later of the grace end and t.
    final graceEnd = left + graceMs;
    final over = outEnd - (graceEnd > t ? graceEnd : t);
    if (over > 0) {
      out.add(Overrun(rakah, left, outEnd, over, labels.stateAt(left)));
    }
    t = outEnd;
  }
}

/// Nearest-rank percentile of [values] (0 < [p] <= 100); null when empty.
int? percentile(List<int> values, double p) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  var k = (p / 100 * sorted.length).ceil() - 1;
  if (k < 0) k = 0;
  if (k >= sorted.length) k = sorted.length - 1;
  return sorted[k];
}

/// Aggregate of many [ReplayResult]s.
class ReplaySummary {
  final List<ReplayResult> results;
  ReplaySummary(this.results);

  int get prayers => results.length;
  int get rakahs => results.fold(0, (n, r) => n + r.eligibleQiyam.length);
  int get wrongStarts => results.fold(0, (n, r) => n + r.wrongStarts.length);
  int get earlyStarts => results.fold(0, (n, r) => n + r.earlyStartsMs.length);
  int get earlyBeyondTolerance =>
      results.fold(0, (n, r) => n + r.earlyBeyondTolerance);

  /// The earliest rak'ah-1 start before its `qiyam1` label, 0 if none.
  int get maxEarlyMs => results.fold(
      0, (m, r) => r.earlyStartsMs.fold(m, (m2, e) => e > m2 ? e : m2));
  int get overruns => results.fold(0, (n, r) => n + r.overruns.length);

  /// Playing stretches past the label at grace 0 (reported, not gating).
  int get overrunsAtZeroGrace =>
      results.fold(0, (n, r) => n + r.overrunsAtZeroGrace.length);
  int get pauses => results.fold(0, (n, r) => n + r.pauses);
  int get resumes => results.fold(0, (n, r) => n + r.resumes);
  int get wrongResumes => results.fold(0, (n, r) => n + r.wrongResumes.length);
  int get worstOverrunMs =>
      results.fold(0, (m, r) => r.worstOverrunMs > m ? r.worstOverrunMs : m);
  int get wrongTimePrayers => results.where((r) => r.wrongTimeAudio).length;
  int get missed => results.fold(0, (n, r) => n + r.missed.length);
  int get rakahCountWrong => results.where((r) => !r.rakahCountOk).length;
  int get prematureStops => results.fold(0, (n, r) => n + r.prematureStops);

  /// Missed qiyam as a fraction of the eligible rak'ahs.
  double get missedRate => rakahs == 0 ? 0 : missed / rakahs;

  List<int> startLatencies(int rakah) => [
        for (final r in results)
          if (r.startLatencyMs[rakah] case final v?) v,
      ];

  List<int> stopLatencies() => [
        for (final r in results) ...r.stopLatencyMs.values,
      ];

  int? startP(int rakah, double p) => percentile(startLatencies(rakah), p);

  List<int> startFromStanding(int rakah) => [
        for (final r in results)
          if (r.startFromStandingMs[rakah] case final v?) v,
      ];

  int? startStdP(int rakah, double p) =>
      percentile(startFromStanding(rakah), p);

  /// Rak'ah-1 starts more than [tolMs] from the labelled qiyam1 start,
  /// either side (the spec's +/- 0.3 s).
  int rakah1OffTarget([int tolMs = defaultTakbirToleranceMs]) =>
      startLatencies(1).where((v) => v.abs() > tolMs).length;
  int? stopP(double p) => percentile(stopLatencies(), p);

  /// Results with any failure, for diagnosis.
  Iterable<ReplayResult> get failures => results.where((r) =>
      r.wrongTimeAudio ||
      r.missed.isNotEmpty ||
      !r.rakahCountOk ||
      r.earlyBeyondTolerance > 0);
}
