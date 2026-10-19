/// A [RecitationPlanner] with made-up clips, for tests.
library;

import '../recitation.dart';
import '../session.dart';

/// Builds plans from [SessionSettings] the way the content repository (#17)
/// is expected to, with invented clip lengths: Al-Fatiha's 7 ayahs, then
/// [surahAyahs] ayahs of the rak'ah's surah. Rak'ah 1's pre-roll is
/// `openingDuaMs`, rak'ah 2's `rakah2PreRollMs`; the gaps come from
/// `ayahGapMs` and `ameenGapMs`. With `autoPairs` the surahs are
/// `autoPairs[autoIndex % length]`.
///
/// Plans are cached per (rak'ah, settings values), so equal requests return
/// identical plans and tests can compare with `same`. [requests] records
/// every [planFor] call.
class FakeRecitationPlanner implements RecitationPlanner {
  final List<(int, int)> pairs;
  final int surahAyahs;

  /// Length of every clip.
  final Duration clipDuration;

  final List<(int rakah, SessionSettings settings)> requests = [];
  final Map<String, RecitationPlan> _cache = {};

  FakeRecitationPlanner({
    this.pairs = const [(93, 94), (102, 103), (105, 106)],
    this.surahAyahs = 4,
    this.clipDuration = const Duration(seconds: 3),
  });

  @override
  (int, int) surahsFor(SessionSettings settings) => settings.autoPairs
      ? pairs[settings.autoIndex % pairs.length]
      : (settings.surahRakah1, settings.surahRakah2);

  @override
  RecitationPlan planFor(int rakah, SessionSettings settings) {
    if (rakah != 1 && rakah != 2) {
      throw ArgumentError.value(rakah, 'rakah', 'must be 1 or 2');
    }
    requests.add((rakah, settings));
    final (s1, s2) = surahsFor(settings);
    final surah = rakah == 1 ? s1 : s2;
    final key = '$rakah ${settings.toJson()}';
    return _cache[key] ??= RecitationPlan(
      clips: [
        for (var a = 1; a <= 7; a++) _clip(1, a),
        for (var a = 1; a <= surahAyahs; a++) _clip(surah, a),
      ],
      preRoll: Duration(
          milliseconds:
              rakah == 1 ? settings.openingDuaMs : settings.rakah2PreRollMs),
      gapAfterAyah: Duration(milliseconds: settings.ayahGapMs),
      gapAfterFatiha: Duration(milliseconds: settings.ameenGapMs),
    );
  }

  AyahClip _clip(int surah, int ayah) => AyahClip(
        assetPath: 'audio/${surah.toString().padLeft(3, '0')}'
            '${ayah.toString().padLeft(3, '0')}.m4a',
        surah: surah,
        ayah: ayah,
        duration: clipDuration,
      );
}
