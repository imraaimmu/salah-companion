/// Pure timeline logic for the recitation player (#16). No Flutter imports,
/// so it is unit-tested without a platform player.
library;

import 'package:salah_core/salah_core.dart';

/// One entry of the gapless playlist: an ayah clip or a stretch of silence.
class TimelineSegment {
  /// The ayah, or null for silence.
  final AyahClip? clip;
  final Duration duration;

  /// Offset of this segment from the start of the playlist.
  final Duration start;

  const TimelineSegment._(this.clip, this.duration, this.start);

  bool get isSilence => clip == null;
  Duration get end => start + duration;

  @override
  String toString() => isSilence
      ? 'Silence(${duration.inMilliseconds} ms @ ${start.inMilliseconds})'
      : 'Clip(${clip!.surah}:${clip!.ayah} @ ${start.inMilliseconds})';
}

/// Where to continue after a pause: playlist [index], [offset] into it.
class ResumePoint {
  final int index;
  final Duration offset;
  const ResumePoint(this.index, this.offset);

  @override
  bool operator ==(Object other) =>
      other is ResumePoint && other.index == index && other.offset == offset;

  @override
  int get hashCode => Object.hash(index, offset);

  @override
  String toString() => 'ResumePoint($index, ${offset.inMilliseconds} ms)';
}

/// The playlist for one [RecitationPlan]:
///
/// pre-roll silence, ayah 1, gap, ayah 2, gap, ... Al-Fatiha's last ayah is
/// followed by gapAfterAyah + gapAfterFatiha (the Ameen pause). Nothing
/// follows the last ayah. Zero-length silences are left out, and silences
/// longer than [maxSilence] are split, because the player builds them by
/// clipping a bundled silence file of that length.
class RecitationTimeline {
  final List<TimelineSegment> segments;

  RecitationTimeline._(this.segments);

  factory RecitationTimeline.fromPlan(
    RecitationPlan plan, {
    Duration maxSilence = const Duration(seconds: 10),
  }) {
    if (maxSilence <= Duration.zero) {
      throw ArgumentError.value(maxSilence, 'maxSilence', 'must be positive');
    }
    final out = <TimelineSegment>[];
    var t = Duration.zero;
    void silence(Duration d) {
      var left = d;
      while (left > Duration.zero) {
        final piece = left > maxSilence ? maxSilence : left;
        out.add(TimelineSegment._(null, piece, t));
        t += piece;
        left -= piece;
      }
    }

    if (plan.clips.isEmpty) return RecitationTimeline._(const []);
    silence(plan.preRoll);
    for (var i = 0; i < plan.clips.length; i++) {
      final c = plan.clips[i];
      out.add(TimelineSegment._(c, c.duration, t));
      t += c.duration;
      if (i == plan.clips.length - 1) break;
      final next = plan.clips[i + 1];
      final endOfFatiha = c.surah == fatiha && next.surah != fatiha;
      silence(
        plan.gapAfterAyah + (endOfFatiha ? plan.gapAfterFatiha : Duration.zero),
      );
    }
    return RecitationTimeline._(List.unmodifiable(out));
  }

  bool get isEmpty => segments.isEmpty;
  Duration get total => segments.isEmpty ? Duration.zero : segments.last.end;

  /// Where to resume after pausing at [offset] into segment [index]:
  ///
  /// * in an ayah: the start of that ayah, so no words are skipped;
  /// * in a silence (pre-roll or gap): the same point, so only the remaining
  ///   silence is waited out.
  ///
  /// Out-of-range input is clamped to the timeline.
  ResumePoint resumePointFor(int index, Duration offset) {
    if (segments.isEmpty) return const ResumePoint(0, Duration.zero);
    if (index < 0) return const ResumePoint(0, Duration.zero);
    if (index >= segments.length) {
      return ResumePoint(segments.length - 1, Duration.zero);
    }
    final s = segments[index];
    if (!s.isSilence) return ResumePoint(index, Duration.zero);
    final o = offset < Duration.zero
        ? Duration.zero
        : (offset > s.duration ? s.duration : offset);
    return ResumePoint(index, o);
  }

  /// The ayah that is playing or comes next at [index], or null after the
  /// last ayah.
  AyahClip? clipAtOrAfter(int index) {
    for (var i = index < 0 ? 0 : index; i < segments.length; i++) {
      final c = segments[i].clip;
      if (c != null) return c;
    }
    return null;
  }
}

/// Volume levels for a linear ramp from [from] to [to] over [duration], one
/// per [step] tick, ending exactly at [to]. Just [to] if [duration] is zero.
List<double> volumeRamp(
  double from,
  double to,
  Duration duration, {
  Duration step = const Duration(milliseconds: 20),
}) {
  if (duration <= Duration.zero) return [to];
  final n = (duration.inMicroseconds / step.inMicroseconds).ceil();
  return [for (var i = 1; i <= n; i++) from + (to - from) * i / n];
}
