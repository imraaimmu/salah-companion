/// Content seams backed by salah_core's manifest and Auto pair table (#17).
library;

import 'package:salah_core/salah_core.dart';

import 'seams.dart';

/// Surah names from the content manifest (`surahManifest`): the pilot
/// surahs a user can pick, in mushaf order.
class ManifestSurahNames implements SurahNames {
  const ManifestSurahNames();

  @override
  List<int> get available => [for (final s in pilotSurahs) s.number];

  @override
  String nameOf(int surah) =>
      surahInfo(surah)?.transliteratedName ?? 'Surah $surah';
}

/// [TodaysSurahs] from a [RecitationPlanner] (the [ContentRepository] in the
/// real app), so the home line always names what the session will recite.
TodaysSurahs todaysSurahsFrom(RecitationPlanner planner) => planner.surahsFor;

/// The Auto table and manual-pick rules of [ContentRepository], without any
/// audio (for demo mode and previews, where no catalog is loaded).
(int, int) manifestTodaysSurahs(SessionSettings settings) =>
    _noAudio.surahsFor(settings);

final ContentRepository _noAudio = ContentRepository(MapAudioCatalog(const {}));
