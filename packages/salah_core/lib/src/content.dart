/// Surah manifest, Auto pair table and recitation planning (#17).
/// See docs/SPEC.md, section "Audio and recitation content".
library;

import 'prayer.dart';
import 'recitation.dart';
import 'session.dart';

/// One surah the app can recite.
class SurahInfo {
  final int number;

  /// Name as it appears in the Tanzil Quran text.
  final String arabicName;
  final String transliteratedName;
  final String englishMeaning;

  /// Ayah count in the Hafs numbering. Al-Fatiha counts the basmalah as
  /// ayah 1.
  final int ayahCount;

  /// Arabic letters (Unicode category Lo) in the Tanzil Uthmani 1.1 text of
  /// the surah, without the basmalah that precedes it. A rough length
  /// measure for the Auto pair rules; printed by
  /// `scripts/fetch_quran_text.py --stats`.
  final int letterCount;

  const SurahInfo({
    required this.number,
    required this.arabicName,
    required this.transliteratedName,
    required this.englishMeaning,
    required this.ayahCount,
    required this.letterCount,
  });

  @override
  String toString() => 'SurahInfo($number $transliteratedName)';
}

/// Al-Fatiha. Always recited first; it cannot be removed.
const int fatiha = 1;

/// Al-Fatiha and the pilot surahs, in mushaf order. The religious reviewer
/// confirms the final list (#26).
const List<SurahInfo> surahManifest = [
  SurahInfo(
    number: 1,
    arabicName: 'الفاتحة',
    transliteratedName: 'Al-Fatiha',
    englishMeaning: 'The Opening',
    ayahCount: 7,
    letterCount: 139,
  ),
  SurahInfo(
    number: 93,
    arabicName: 'الضحى',
    transliteratedName: 'Ad-Duha',
    englishMeaning: 'The Morning Brightness',
    ayahCount: 11,
    letterCount: 164,
  ),
  SurahInfo(
    number: 94,
    arabicName: 'الشرح',
    transliteratedName: 'Ash-Sharh',
    englishMeaning: 'The Opening Up of the Heart',
    ayahCount: 8,
    letterCount: 102,
  ),
  SurahInfo(
    number: 95,
    arabicName: 'التين',
    transliteratedName: 'At-Tin',
    englishMeaning: 'The Fig',
    ayahCount: 8,
    letterCount: 157,
  ),
  SurahInfo(
    number: 97,
    arabicName: 'القدر',
    transliteratedName: 'Al-Qadr',
    englishMeaning: 'The Night of Decree',
    ayahCount: 5,
    letterCount: 112,
  ),
  SurahInfo(
    number: 102,
    arabicName: 'التكاثر',
    transliteratedName: 'At-Takathur',
    englishMeaning: 'Competing for More',
    ayahCount: 8,
    letterCount: 122,
  ),
  SurahInfo(
    number: 103,
    arabicName: 'العصر',
    transliteratedName: "Al-'Asr",
    englishMeaning: 'Time',
    ayahCount: 3,
    letterCount: 71,
  ),
  SurahInfo(
    number: 105,
    arabicName: 'الفيل',
    transliteratedName: 'Al-Fil',
    englishMeaning: 'The Elephant',
    ayahCount: 5,
    letterCount: 96,
  ),
  SurahInfo(
    number: 106,
    arabicName: 'قريش',
    transliteratedName: 'Quraysh',
    englishMeaning: 'Quraysh',
    ayahCount: 4,
    letterCount: 75,
  ),
  SurahInfo(
    number: 107,
    arabicName: 'الماعون',
    transliteratedName: "Al-Ma'un",
    englishMeaning: 'Small Kindnesses',
    ayahCount: 7,
    letterCount: 114,
  ),
  SurahInfo(
    number: 108,
    arabicName: 'الكوثر',
    transliteratedName: 'Al-Kawthar',
    englishMeaning: 'Abundance',
    ayahCount: 3,
    letterCount: 42,
  ),
  SurahInfo(
    number: 109,
    arabicName: 'الكافرون',
    transliteratedName: 'Al-Kafirun',
    englishMeaning: 'The Disbelievers',
    ayahCount: 6,
    letterCount: 95,
  ),
  SurahInfo(
    number: 110,
    arabicName: 'النصر',
    transliteratedName: 'An-Nasr',
    englishMeaning: 'The Help',
    ayahCount: 3,
    letterCount: 80,
  ),
  SurahInfo(
    number: 112,
    arabicName: 'الإخلاص',
    transliteratedName: 'Al-Ikhlas',
    englishMeaning: 'Sincerity',
    ayahCount: 4,
    letterCount: 47,
  ),
  SurahInfo(
    number: 113,
    arabicName: 'الفلق',
    transliteratedName: 'Al-Falaq',
    englishMeaning: 'The Daybreak',
    ayahCount: 5,
    letterCount: 71,
  ),
  SurahInfo(
    number: 114,
    arabicName: 'الناس',
    transliteratedName: 'An-Nas',
    englishMeaning: 'Mankind',
    ayahCount: 6,
    letterCount: 80,
  ),
];

/// The surahs a user can pick for rak'ah 1 or 2 (everything but Al-Fatiha).
final List<SurahInfo> pilotSurahs = List.unmodifiable(
  surahManifest.where((s) => s.number != fatiha),
);

final Map<int, SurahInfo> _byNumber = {
  for (final s in surahManifest) s.number: s,
};

/// The manifest entry for [number], or null if the app does not have it.
SurahInfo? surahInfo(int number) => _byNumber[number];

/// Why a (rak'ah 1, rak'ah 2) pair breaks one of the draft Auto rules.
enum PairIssue {
  /// One of the surahs is not in the manifest, or it is Al-Fatiha.
  unknownSurah,

  /// Both rak'ahs use the same surah.
  sameSurah,

  /// Rak'ah 2 comes earlier in the mushaf than rak'ah 1.
  rakah2Earlier,

  /// Exactly one surah lies between them in the mushaf.
  skipsOneSurah,

  /// Rak'ah 1 has fewer ayahs or fewer letters than rak'ah 2.
  rakah1Shorter,
}

/// Checks a pair against the draft Auto rules in docs/SPEC.md:
///
/// * rak'ah 2 comes later in the mushaf than rak'ah 1;
/// * no pair skips exactly one surah (every surah between pilot surahs is
///   a short surah of Juz 'Amma, whether or not it is in the pilot list);
/// * rak'ah 1 is not shorter than rak'ah 2, by ayah count **and** by
///   letter count (the stricter reading, until the reviewer rules).
///
/// An empty result means the pair follows every rule. For a pair the user
/// picks, the UI only notes [PairIssue.rakah2Earlier] gently and allows it.
List<PairIssue> checkPair(int rakah1, int rakah2) {
  final a = surahInfo(rakah1);
  final b = surahInfo(rakah2);
  if (a == null || b == null || rakah1 == fatiha || rakah2 == fatiha) {
    return const [PairIssue.unknownSurah];
  }
  if (rakah1 == rakah2) return const [PairIssue.sameSurah];
  final issues = <PairIssue>[];
  if (rakah2 < rakah1) issues.add(PairIssue.rakah2Earlier);
  if ((rakah2 - rakah1).abs() == 2) issues.add(PairIssue.skipsOneSurah);
  if (a.ayahCount < b.ayahCount || a.letterCount < b.letterCount) {
    issues.add(PairIssue.rakah1Shorter);
  }
  return issues;
}

/// The Auto pair table: one pair per day, in this order.
///
/// **Draft, pending religious review (#26).** Built from the draft rules in
/// [checkPair]: for each pilot surah that can open a pair, the nearest later
/// surah that follows every rule, plus the SPEC example (109, 112). The SPEC
/// example (110, 112) is left out because it skips exactly one surah
/// (Al-Masad, 111). Al-Kawthar, Al-Ikhlas, Al-Falaq and An-Nas never open a
/// pair: every later surah is longer, so (113, 114) is not in the table.
const List<(int, int)> autoPairTable = [
  (93, 94),
  (94, 103),
  (95, 102),
  (97, 103),
  (102, 103),
  (103, 108),
  (105, 106),
  (106, 112),
  (107, 108),
  (109, 110),
  (109, 112),
];

/// One bundled audio file.
class CatalogEntry {
  final String assetPath;
  final Duration duration;

  const CatalogEntry(this.assetPath, this.duration);
}

/// Maps surah:ayah to a bundled audio file and its length.
abstract interface class AudioCatalog {
  /// The file for [surah]:[ayah], or null if it is not bundled.
  CatalogEntry? entry(int surah, int ayah);
}

/// An [AudioCatalog] held in memory, usually parsed from the catalog JSON
/// written by `scripts/make_placeholder_audio.py` (and, later, by the real
/// recording pipeline, #18).
///
/// JSON shape:
/// `{"clips": [{"surah": 1, "ayah": 1, "path": "assets/...", "durationMs": 2100}, ...]}`.
/// Other top-level fields (source, licence, placeholder flag) are ignored.
class MapAudioCatalog implements AudioCatalog {
  final Map<(int, int), CatalogEntry> _entries;

  /// Whether the catalog says its audio is placeholder tones.
  final bool placeholder;

  MapAudioCatalog(
    Map<(int, int), CatalogEntry> entries, {
    this.placeholder = false,
  }) : _entries = Map.unmodifiable(entries);

  factory MapAudioCatalog.fromJson(Map<String, Object?> json) {
    final clips = json['clips'];
    if (clips is! List) {
      throw const FormatException('audio catalog: "clips" must be a list');
    }
    final entries = <(int, int), CatalogEntry>{};
    for (final c in clips) {
      if (c is! Map) {
        throw const FormatException('audio catalog: clip must be an object');
      }
      final surah = c['surah'];
      final ayah = c['ayah'];
      final path = c['path'];
      final ms = c['durationMs'];
      if (surah is! int ||
          ayah is! int ||
          path is! String ||
          ms is! int ||
          ms <= 0) {
        throw FormatException('audio catalog: bad clip $c');
      }
      if (entries.containsKey((surah, ayah))) {
        throw FormatException('audio catalog: duplicate clip $surah:$ayah');
      }
      entries[(surah, ayah)] = CatalogEntry(path, Duration(milliseconds: ms));
    }
    return MapAudioCatalog(entries, placeholder: json['placeholder'] == true);
  }

  @override
  CatalogEntry? entry(int surah, int ayah) => _entries[(surah, ayah)];

  int get length => _entries.length;
}

/// Thrown when the catalog lacks a file the plan needs.
class MissingAudioException implements Exception {
  final int surah;
  final int ayah;
  const MissingAudioException(this.surah, this.ayah);

  @override
  String toString() => 'MissingAudioException: no audio for $surah:$ayah';
}

/// The manifest, the Auto table and the audio catalog together.
class ContentRepository implements RecitationPlanner {
  final AudioCatalog catalog;
  final List<(int, int)> autoPairs;

  ContentRepository(this.catalog, {this.autoPairs = autoPairTable}) {
    if (autoPairs.isEmpty) {
      throw ArgumentError.value(autoPairs, 'autoPairs', 'must not be empty');
    }
  }

  /// The Auto pair for [autoIndex]; wraps around the table, so the index can
  /// simply grow by one per completed session.
  (int, int) autoPairAt(int autoIndex) =>
      autoPairs[autoIndex % autoPairs.length];

  /// Rak'ah 1 and 2 surahs. In Auto mode, the table entry for
  /// [SessionSettings.autoIndex]. A manual pick keeps any order the user
  /// chose; a pick the app has no content for (for example a stale stored
  /// setting) falls back to the Auto pair, so a session never plays nothing.
  @override
  (int rakah1, int rakah2) surahsFor(SessionSettings settings) {
    if (settings.autoPairs) return autoPairAt(settings.autoIndex);
    final r1 = settings.surahRakah1;
    final r2 = settings.surahRakah2;
    if (r1 == fatiha ||
        r2 == fatiha ||
        surahInfo(r1) == null ||
        surahInfo(r2) == null) {
      return autoPairAt(settings.autoIndex);
    }
    return (r1, r2);
  }

  /// The recitation for [rakah] (1..[Prayer.maxRakahs]), each clip with its
  /// bundled file and real duration:
  ///
  /// * rak'ahs 1 and 2 ([Prayer.rakahHasSurah]): Al-Fatiha's 7 ayahs, then
  ///   every ayah of the rak'ah's surah ([surahsFor]), with the Ameen gap
  ///   after Al-Fatiha;
  /// * rak'ahs 3 and 4: Al-Fatiha only, with no Ameen gap (no surah
  ///   follows; playback ends with Al-Fatiha's last ayah).
  ///
  /// Rak'ah 1 waits for the opening dua, every later rak'ah for
  /// [SessionSettings.rakah2PreRollMs] (the pause after standing up). The
  /// same in every prayer, silent (Dhuhr, Asr) or not. Gaps come from the
  /// settings; the ayah gap is clamped to 0..3 s as the SPEC allows.
  ///
  /// Throws [ArgumentError] for a rak'ah outside 1..4 and
  /// [MissingAudioException] when the catalog lacks a needed file.
  @override
  RecitationPlan planFor(int rakah, SessionSettings settings) {
    if (rakah < 1 || rakah > Prayer.maxRakahs) {
      throw ArgumentError.value(
          rakah, 'rakah', 'must be 1 to ${Prayer.maxRakahs}');
    }
    final withSurah = Prayer.rakahHasSurah(rakah);
    final (r1, r2) = surahsFor(settings);
    final clips = [
      ..._clipsOf(fatiha),
      if (withSurah) ..._clipsOf(rakah == 1 ? r1 : r2),
    ];
    return RecitationPlan(
      clips: List.unmodifiable(clips),
      preRoll: Duration(
        milliseconds: _nonNegative(
          rakah == 1 ? settings.openingDuaMs : settings.rakah2PreRollMs,
        ),
      ),
      gapAfterAyah: Duration(
        milliseconds: settings.ayahGapMs.clamp(0, 3000).toInt(),
      ),
      gapAfterFatiha: withSurah
          ? Duration(milliseconds: _nonNegative(settings.ameenGapMs))
          : Duration.zero,
    );
  }

  /// Every manifest ayah that has no file in the catalog, as (surah, ayah).
  /// Empty when the bundle is complete (the automated file-count check).
  List<(int, int)> missingAudio() => [
        for (final s in surahManifest)
          for (var a = 1; a <= s.ayahCount; a++)
            if (catalog.entry(s.number, a) == null) (s.number, a),
      ];

  List<AyahClip> _clipsOf(int surah) {
    final info = surahInfo(surah)!;
    return [for (var a = 1; a <= info.ayahCount; a++) _clip(surah, a)];
  }

  AyahClip _clip(int surah, int ayah) {
    final e = catalog.entry(surah, ayah);
    if (e == null) throw MissingAudioException(surah, ayah);
    return AyahClip(
      assetPath: e.assetPath,
      surah: surah,
      ayah: ayah,
      duration: e.duration,
    );
  }

  static int _nonNegative(int ms) => ms < 0 ? 0 : ms;
}
