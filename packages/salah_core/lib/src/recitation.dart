/// Recitation plan types. See docs/SPEC.md, section "Audio and recitation content".
library;

class AyahClip {
  final String assetPath;
  final int surah;
  final int ayah;

  /// Length of the audio file. Used by the scheduler to build a timeline.
  final Duration duration;

  const AyahClip({
    required this.assetPath,
    required this.surah,
    required this.ayah,
    required this.duration,
  });

  @override
  String toString() => 'AyahClip($surah:$ayah)';
}

/// What to play for one rak'ah: Al-Fatiha's ayahs followed by the surah's
/// (rak'ahs 1 and 2), or Al-Fatiha's alone (rak'ahs 3 and 4).
class RecitationPlan {
  final List<AyahClip> clips;

  /// Silence before the first clip (opening-dua pause in rak'ah 1, 1.5 s in
  /// later rak'ahs).
  final Duration preRoll;

  /// Silence after each ayah.
  final Duration gapAfterAyah;

  /// Extra silence after Al-Fatiha's last ayah, for Ameen (default 1.5 s).
  /// The total gap after Al-Fatiha is gapAfterAyah + gapAfterFatiha.
  final Duration gapAfterFatiha;

  const RecitationPlan({
    required this.clips,
    required this.preRoll,
    required this.gapAfterAyah,
    this.gapAfterFatiha = const Duration(milliseconds: 1500),
  });
}
