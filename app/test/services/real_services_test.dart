import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/services/content_services.dart';
import 'package:salah_companion/src/services/pose_placement_check.dart';
import 'package:salah_companion/src/services/pose_session_runner.dart';
import 'package:salah_companion/src/services/real_services.dart';
import 'package:salah_core/salah_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real services load the bundled catalog and wire every seam', () async {
    final real = await RealServices.load();
    expect(real.content.missingAudio(), isEmpty);
    final s = real.wrap(child: const SizedBox());
    const settings = SessionSettings(autoIndex: 3);
    expect(s.todaysSurahs(settings), autoPairTable[3]);
    expect(s.surahNames.nameOf(93), 'Ad-Duha');
    expect(s.surahNames.available, [for (final p in pilotSurahs) p.number]);
    for (final p in Prayer.values) {
      final runner = s.sessionRunnerFactory(settings, p);
      expect(runner, isA<PoseSessionRunner>());
      expect((runner as PoseSessionRunner).prayer, p);
      expect(runner.machine.prayer, p);
    }
    expect(real.content.planFor(1, settings).clips.first.surah, fatiha);
    // Rak'ahs 3 and 4 (Dhuhr, Asr, Maghrib, Isha): Al-Fatiha only.
    for (final r in [3, 4]) {
      final clips = real.content.planFor(r, settings).clips;
      expect(clips, isNotEmpty);
      expect(clips.every((c) => c.surah == fatiha), isTrue, reason: '$r');
    }
    final check = s.placementCheckFactory();
    expect(check, isA<PosePlacementCheck>());
  });

  test('demo names and pairs come from the manifest', () {
    expect(const ManifestSurahNames().nameOf(114), 'An-Nas');
    expect(
      manifestTodaysSurahs(const SessionSettings(autoIndex: 0)),
      autoPairTable[0],
    );
    expect(
      manifestTodaysSurahs(
        const SessionSettings(
          autoPairs: false,
          surahRakah1: 112,
          surahRakah2: 113,
        ),
      ),
      (112, 113),
    );
  });
}
