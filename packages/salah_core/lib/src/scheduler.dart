/// Recitation timeline arithmetic (#16). See docs/SPEC.md, section "Audio
/// and recitation content" -> "Reciter and pace".
///
/// A [RecitationPlan] plays as:
///
/// ```text
/// preRoll | clip 0 | gap | clip 1 | gap | ... | clip n-1
/// ```
///
/// * The gap after every clip but the last is [RecitationPlan.gapAfterAyah].
/// * The gap after Al-Fatiha's last ayah (the last clip of the leading run of
///   surah 1 clips) is `gapAfterAyah + gapAfterFatiha`, for the user's Ameen.
/// * There is no trailing silence after the last clip of the plan: playback
///   (and [RecitationPlayer.play]) ends when the last ayah ends, so
///   [RecitationScheduler.total] is the end of the last clip (or the
///   pre-roll, for a plan with no clips).
///
/// Every interval is half-open, `[start, end)`: at exactly a clip's end the
/// position is already in the gap after it (or [ScheduledPhase.finished]).
library;

import 'interfaces.dart';
import 'recitation.dart';

/// One clip of a plan placed on the timeline.
class ScheduledClip {
  /// Index into [RecitationPlan.clips].
  final int index;
  final AyahClip clip;

  /// Offset of the clip's first sample from the start of the plan (the
  /// moment [RecitationPlayer.play] was called).
  final Duration start;

  /// Silence after this clip (zero for the last clip).
  final Duration gapAfter;

  const ScheduledClip({
    required this.index,
    required this.clip,
    required this.start,
    required this.gapAfter,
  });

  Duration get duration => clip.duration;

  /// Offset of the clip's end (the start of its gap).
  Duration get end => start + clip.duration;

  /// Offset of the end of the gap after this clip (the next clip's start).
  Duration get gapEnd => end + gapAfter;

  @override
  String toString() =>
      'ScheduledClip(#$index ${clip.surah}:${clip.ayah} at ${start.inMilliseconds} ms, '
      '${clip.duration.inMilliseconds} ms + gap ${gapAfter.inMilliseconds} ms)';
}

/// What is heard at a moment of the timeline.
enum ScheduledPhase {
  /// The silence before the first clip.
  preRoll,

  /// A clip is playing.
  clip,

  /// The silence after a clip (the Ameen gap included).
  gap,

  /// Past the end of the last clip.
  finished,
}

/// A position on the timeline, from [RecitationScheduler.positionAt].
class ScheduledPosition {
  final ScheduledPhase phase;

  /// The clip playing ([ScheduledPhase.clip]) or the clip the gap follows
  /// ([ScheduledPhase.gap]); the last clip when [ScheduledPhase.finished]
  /// (null if the plan has no clips); null in the pre-roll.
  final ScheduledClip? clip;

  /// Time since the start of the current phase (into the pre-roll, the clip
  /// or the gap; past the end when finished).
  final Duration offset;

  /// Time left in the current phase (zero when finished).
  final Duration remaining;

  const ScheduledPosition({
    required this.phase,
    required this.clip,
    required this.offset,
    required this.remaining,
  });

  /// [clip]'s index, or null.
  int? get clipIndex => clip?.index;

  @override
  String toString() => 'ScheduledPosition(${phase.name}, clip $clipIndex, '
      '+${offset.inMilliseconds} ms, ${remaining.inMilliseconds} ms left)';
}

/// The timeline of one [RecitationPlan]: clip start offsets, the total
/// length, positions and resume points.
class RecitationScheduler {
  final RecitationPlan plan;

  /// Every clip, in plan order, with its start offset.
  final List<ScheduledClip> clips;

  /// Total length: the end of the last clip (the pre-roll if no clips).
  final Duration total;

  RecitationScheduler._(this.plan, this.clips, this.total);

  factory RecitationScheduler(RecitationPlan plan) {
    final clips = timeline(plan);
    return RecitationScheduler._(
        plan, clips, clips.isEmpty ? plan.preRoll : clips.last.end);
  }

  /// The start offset of each clip of [plan] (see the library docs for the
  /// gaps).
  static List<ScheduledClip> timeline(RecitationPlan plan) {
    _checkNonNegative(plan.preRoll, 'preRoll');
    _checkNonNegative(plan.gapAfterAyah, 'gapAfterAyah');
    _checkNonNegative(plan.gapAfterFatiha, 'gapAfterFatiha');
    final fatihaLast = fatihaLastIndex(plan);
    final out = <ScheduledClip>[];
    var t = plan.preRoll;
    for (var i = 0; i < plan.clips.length; i++) {
      final c = plan.clips[i];
      _checkNonNegative(c.duration, 'clips[$i].duration');
      final last = i == plan.clips.length - 1;
      final gap = last
          ? Duration.zero
          : i == fatihaLast
              ? plan.gapAfterAyah + plan.gapAfterFatiha
              : plan.gapAfterAyah;
      out.add(ScheduledClip(index: i, clip: c, start: t, gapAfter: gap));
      t += c.duration + gap;
    }
    return List.unmodifiable(out);
  }

  /// Index of Al-Fatiha's last ayah: the last clip of the leading run of
  /// surah 1 clips; -1 when the plan does not start with Al-Fatiha.
  static int fatihaLastIndex(RecitationPlan plan) {
    var i = -1;
    while (i + 1 < plan.clips.length && plan.clips[i + 1].surah == 1) {
      i++;
    }
    return i;
  }

  static void _checkNonNegative(Duration d, String name) {
    if (d.isNegative) {
      throw ArgumentError.value(d, name, 'must not be negative');
    }
  }

  /// What is heard [t] after the start of the plan. Negative [t] counts as
  /// zero.
  ScheduledPosition positionAt(Duration t) {
    if (t.isNegative) t = Duration.zero;
    if (t < plan.preRoll) {
      return ScheduledPosition(
          phase: ScheduledPhase.preRoll,
          clip: null,
          offset: t,
          remaining: plan.preRoll - t);
    }
    if (clips.isEmpty || t >= total) {
      return ScheduledPosition(
          phase: ScheduledPhase.finished,
          clip: clips.isEmpty ? null : clips.last,
          offset: t - total,
          remaining: Duration.zero);
    }
    // Binary search for the last clip starting at or before t.
    var lo = 0, hi = clips.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (clips[mid].start <= t) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final c = clips[lo];
    if (t < c.end) {
      return ScheduledPosition(
          phase: ScheduledPhase.clip,
          clip: c,
          offset: t - c.start,
          remaining: c.end - t);
    }
    return ScheduledPosition(
        phase: ScheduledPhase.gap,
        clip: c,
        offset: t - c.end,
        remaining: c.gapEnd - t);
  }

  /// Where playback continues after a pause at [pausedAt], matching
  /// [RecitationPlayer.pause] / [RecitationPlayer.resume]: the start of the
  /// ayah that was playing, so no words are skipped; [pausedAt] itself when
  /// paused in the pre-roll or a gap (the rest of the silence is kept);
  /// [total] when already finished. Negative [pausedAt] counts as zero.
  Duration resumePointFor(Duration pausedAt) {
    final p = positionAt(pausedAt);
    return switch (p.phase) {
      ScheduledPhase.clip => p.clip!.start,
      ScheduledPhase.finished => total,
      ScheduledPhase.preRoll ||
      ScheduledPhase.gap =>
        pausedAt.isNegative ? Duration.zero : pausedAt,
    };
  }
}
