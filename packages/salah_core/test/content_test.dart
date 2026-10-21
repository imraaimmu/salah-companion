import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

/// A complete catalog: every manifest ayah, duration 1000 + surah + ayah ms.
MapAudioCatalog fullCatalog({Set<(int, int)> without = const {}}) =>
    MapAudioCatalog({
      for (final s in surahManifest)
        for (var a = 1; a <= s.ayahCount; a++)
          if (!without.contains((s.number, a)))
            (s.number, a): CatalogEntry(
              'assets/audio/test/${s.number}_$a.m4a',
              Duration(milliseconds: 1000 + s.number + a),
            ),
    });

void main() {
  group('manifest', () {
    test('has Al-Fatiha and the 15 pilot surahs in mushaf order', () {
      expect(surahManifest.map((s) => s.number), [
        1,
        93,
        94,
        95,
        97,
        102,
        103,
        105,
        106,
        107,
        108,
        109,
        110,
        112,
        113,
        114,
      ]);
      expect(pilotSurahs, hasLength(15));
      expect(pilotSurahs.any((s) => s.number == fatiha), isFalse);
    });

    test('ayah counts follow the Hafs numbering', () {
      const hafs = {
        1: 7,
        93: 11,
        94: 8,
        95: 8,
        97: 5,
        102: 8,
        103: 3,
        105: 5,
        106: 4,
        107: 7,
        108: 3,
        109: 6,
        110: 3,
        112: 4,
        113: 5,
        114: 6,
      };
      expect({for (final s in surahManifest) s.number: s.ayahCount}, hafs);
      expect(surahManifest.fold<int>(0, (n, s) => n + s.ayahCount), 93);
    });

    test('every entry has names, a meaning and a length', () {
      for (final s in surahManifest) {
        expect(s.arabicName, isNotEmpty, reason: '$s');
        expect(s.transliteratedName, isNotEmpty, reason: '$s');
        expect(s.englishMeaning, isNotEmpty, reason: '$s');
        expect(s.letterCount, greaterThan(0), reason: '$s');
      }
    });

    test('lookup', () {
      expect(surahInfo(112)!.transliteratedName, 'Al-Ikhlas');
      expect(surahInfo(2), isNull);
    });
  });

  group('pair rules', () {
    test('a good pair has no issues', () {
      expect(checkPair(93, 94), isEmpty);
      expect(checkPair(109, 112), isEmpty); // skips two surahs: allowed
    });

    test('rak\'ah 2 earlier in the mushaf', () {
      expect(checkPair(94, 93), contains(PairIssue.rakah2Earlier));
    });

    test('skipping exactly one surah', () {
      // 110 -> 112 skips Al-Masad (111), which is not in the pilot list.
      expect(checkPair(110, 112), contains(PairIssue.skipsOneSurah));
      // 103 -> 105 skips Al-Humazah (104).
      expect(checkPair(103, 105), contains(PairIssue.skipsOneSurah));
      // 95 -> 97 skips Al-'Alaq (96).
      expect(checkPair(95, 97), contains(PairIssue.skipsOneSurah));
      // Also when the order is reversed.
      expect(checkPair(112, 110), contains(PairIssue.skipsOneSurah));
      expect(checkPair(102, 105), isNot(contains(PairIssue.skipsOneSurah)));
    });

    test('rak\'ah 1 shorter by ayah count', () {
      // An-Nasr (3 ayahs, 80 letters) before Al-Falaq (5 ayahs, 71 letters).
      expect(checkPair(110, 113), [PairIssue.rakah1Shorter]);
    });

    test('rak\'ah 1 shorter by letter count', () {
      // Ash-Sharh (8 ayahs, 102 letters) before At-Tin (8 ayahs, 157).
      expect(checkPair(94, 95), [PairIssue.rakah1Shorter]);
    });

    test('equal length is allowed', () {
      expect(checkPair(102, 103), isEmpty);
      final a = surahInfo(95)!, b = surahInfo(102)!;
      expect(a.ayahCount, b.ayahCount);
      expect(checkPair(95, 102), isEmpty);
    });

    test('Al-Falaq then An-Nas breaks the length rule', () {
      expect(checkPair(113, 114), [PairIssue.rakah1Shorter]);
    });

    test('unknown surahs, Al-Fatiha and the same surah twice', () {
      expect(checkPair(2, 94), [PairIssue.unknownSurah]);
      expect(checkPair(1, 94), [PairIssue.unknownSurah]);
      expect(checkPair(94, 94), [PairIssue.sameSurah]);
    });

    test('several issues at once', () {
      expect(checkPair(114, 112), [
        PairIssue.rakah2Earlier,
        PairIssue.skipsOneSurah,
      ]);
      expect(checkPair(108, 93), [
        PairIssue.rakah2Earlier,
        PairIssue.rakah1Shorter,
      ]);
    });
  });

  group('Auto pair table', () {
    test('every pair follows every draft rule', () {
      for (final (r1, r2) in autoPairTable) {
        expect(checkPair(r1, r2), isEmpty, reason: '($r1, $r2)');
      }
    });

    test('pairs are distinct pilot surahs and the table has no repeats', () {
      final pilot = pilotSurahs.map((s) => s.number).toSet();
      for (final (r1, r2) in autoPairTable) {
        expect(pilot, containsAll([r1, r2]));
      }
      expect(autoPairTable.toSet(), hasLength(autoPairTable.length));
    });

    test('contains the valid SPEC examples, not (110, 112)', () {
      for (final p in [
        (93, 94),
        (102, 103),
        (105, 106),
        (107, 108),
        (109, 112),
      ]) {
        expect(autoPairTable, contains(p));
      }
      expect(autoPairTable, isNot(contains((110, 112))));
    });

    test('each opening surah is paired with its nearest valid later surah', () {
      final pilot = pilotSurahs.map((s) => s.number).toList();
      for (final r1 in pilot) {
        final later = pilot.where((r2) => r2 > r1 && checkPair(r1, r2).isEmpty);
        if (later.isEmpty) {
          expect(autoPairTable.any((p) => p.$1 == r1), isFalse, reason: '$r1');
        } else {
          expect(autoPairTable, contains((r1, later.first)), reason: '$r1');
        }
      }
    });
  });

  group('MapAudioCatalog.fromJson', () {
    test('parses clips and the placeholder flag', () {
      final c = MapAudioCatalog.fromJson({
        'placeholder': true,
        'clips': [
          {'surah': 1, 'ayah': 1, 'path': 'a.m4a', 'durationMs': 2100},
          {'surah': 1, 'ayah': 2, 'path': 'b.m4a', 'durationMs': 1900},
        ],
      });
      expect(c.placeholder, isTrue);
      expect(c.length, 2);
      expect(c.entry(1, 1)!.assetPath, 'a.m4a');
      expect(c.entry(1, 2)!.duration, const Duration(milliseconds: 1900));
      expect(c.entry(1, 3), isNull);
    });

    test('rejects bad input', () {
      expect(() => MapAudioCatalog.fromJson({}), throwsFormatException);
      expect(
        () => MapAudioCatalog.fromJson({
          'clips': [
            {'surah': 1, 'ayah': 1, 'path': 'a', 'durationMs': 0},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => MapAudioCatalog.fromJson({
          'clips': [
            {'surah': 1, 'ayah': 1, 'path': 'a', 'durationMs': 5},
            {'surah': 1, 'ayah': 1, 'path': 'b', 'durationMs': 5},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => MapAudioCatalog.fromJson({
          'clips': [
            {'surah': '1', 'ayah': 1, 'path': 'a', 'durationMs': 5},
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('ContentRepository', () {
    final repo = ContentRepository(fullCatalog());

    test('Auto mode uses the table entry and wraps around', () {
      const s = SessionSettings(autoPairs: true, autoIndex: 0);
      expect(repo.surahsFor(s), autoPairTable[0]);
      expect(repo.surahsFor(s.copyWith(autoIndex: 3)), autoPairTable[3]);
      expect(
        repo.surahsFor(s.copyWith(autoIndex: autoPairTable.length + 1)),
        autoPairTable[1],
      );
      expect(repo.surahsFor(s.copyWith(autoIndex: -1)), autoPairTable.last);
    });

    test('manual pick is kept, in any order', () {
      const s = SessionSettings(
        autoPairs: false,
        surahRakah1: 114,
        surahRakah2: 113,
      );
      expect(repo.surahsFor(s), (114, 113));
    });

    test('manual pick without content falls back to the Auto pair', () {
      const s = SessionSettings(
        autoPairs: false,
        surahRakah1: 2,
        surahRakah2: 94,
        autoIndex: 2,
      );
      expect(repo.surahsFor(s), autoPairTable[2]);
      expect(
        repo.surahsFor(s.copyWith(surahRakah1: 93, surahRakah2: 1)),
        autoPairTable[2],
      );
    });

    test('rejects an empty table', () {
      expect(
        () => ContentRepository(fullCatalog(), autoPairs: const []),
        throwsArgumentError,
      );
    });

    test(
      'planFor rak\'ah 1: Al-Fatiha then the first surah, real durations',
      () {
        const s = SessionSettings(
          autoPairs: false,
          surahRakah1: 109,
          surahRakah2: 112,
          openingDuaMs: 6000,
          rakah2PreRollMs: 1500,
          ayahGapMs: 1200,
          ameenGapMs: 1500,
        );
        final plan = repo.planFor(1, s);
        expect(plan.clips.map((c) => '${c.surah}:${c.ayah}'), [
          for (var a = 1; a <= 7; a++) '1:$a',
          for (var a = 1; a <= 6; a++) '109:$a',
        ]);
        expect(plan.clips.first.assetPath, 'assets/audio/test/1_1.m4a');
        expect(plan.clips.last.duration, const Duration(milliseconds: 1115));
        expect(plan.preRoll, const Duration(milliseconds: 6000));
        expect(plan.gapAfterAyah, const Duration(milliseconds: 1200));
        expect(plan.gapAfterFatiha, const Duration(milliseconds: 1500));
      },
    );

    test('planFor rak\'ah 2 uses the second surah and its pre-roll', () {
      const s = SessionSettings(
        autoPairs: false,
        surahRakah1: 109,
        surahRakah2: 112,
        rakah2PreRollMs: 1500,
        openingDuaMs: 18000,
      );
      final plan = repo.planFor(2, s);
      expect(plan.clips, hasLength(7 + 4));
      expect(plan.clips.skip(7).map((c) => c.surah).toSet(), {112});
      expect(plan.preRoll, const Duration(milliseconds: 1500));
    });

    test('planFor in Auto mode follows the table', () {
      const s = SessionSettings(autoPairs: true, autoIndex: 0);
      final (r1, r2) = autoPairTable[0];
      expect(repo.planFor(1, s).clips.last.surah, r1);
      expect(repo.planFor(2, s).clips.last.surah, r2);
    });

    test('planFor clamps the ayah gap and negative pauses', () {
      const s = SessionSettings(
        ayahGapMs: 9000,
        openingDuaMs: -5,
        ameenGapMs: -1,
      );
      final plan = repo.planFor(1, s);
      expect(plan.gapAfterAyah, const Duration(milliseconds: 3000));
      expect(plan.preRoll, Duration.zero);
      expect(plan.gapAfterFatiha, Duration.zero);
      expect(
        repo.planFor(1, s.copyWith(ayahGapMs: -10)).gapAfterAyah,
        Duration.zero,
      );
    });

    test(
      'planFor rak\'ahs 3 and 4: Al-Fatiha only, no Ameen gap, the later '
      'rak\'ahs\' pre-roll',
      () {
        const s = SessionSettings(
          autoPairs: false,
          surahRakah1: 109,
          surahRakah2: 112,
          openingDuaMs: 18000,
          rakah2PreRollMs: 1500,
          ayahGapMs: 1200,
          ameenGapMs: 1500,
        );
        for (final k in [3, 4]) {
          final plan = repo.planFor(k, s);
          expect(
              plan.clips.map((c) => '${c.surah}:${c.ayah}'),
              [
                for (var a = 1; a <= 7; a++) '1:$a',
              ],
              reason: 'rak\'ah $k');
          expect(plan.preRoll, const Duration(milliseconds: 1500));
          expect(plan.gapAfterAyah, const Duration(milliseconds: 1200));
          expect(plan.gapAfterFatiha, Duration.zero);
          // Playback ends with Al-Fatiha's last ayah: no trailing silence.
          final timeline = RecitationScheduler(plan);
          expect(timeline.total, timeline.clips.last.end);
        }
        // Matches Prayer.hasSurah for every prayer.
        for (final p in Prayer.values) {
          for (var k = 1; k <= p.rakahCount; k++) {
            final surahClips =
                repo.planFor(k, s).clips.where((c) => c.surah != fatiha);
            expect(surahClips.isNotEmpty, p.hasSurah(k),
                reason: '${p.name} rak\'ah $k');
          }
        }
      },
    );

    test('planFor rejects other rak\'ahs', () {
      expect(
        () => repo.planFor(0, const SessionSettings()),
        throwsArgumentError,
      );
      expect(
        () => repo.planFor(5, const SessionSettings()),
        throwsArgumentError,
      );
    });

    test('planFor throws when a file is missing', () {
      final partial = ContentRepository(fullCatalog(without: {(94, 8)}));
      const s = SessionSettings(
        autoPairs: false,
        surahRakah1: 93,
        surahRakah2: 94,
      );
      expect(partial.planFor(1, s).clips, hasLength(7 + 11));
      expect(
        () => partial.planFor(2, s),
        throwsA(
          isA<MissingAudioException>()
              .having((e) => e.surah, 'surah', 94)
              .having((e) => e.ayah, 'ayah', 8),
        ),
      );
    });

    test('missingAudio lists gaps in the bundle', () {
      expect(repo.missingAudio(), isEmpty);
      final partial = ContentRepository(
        fullCatalog(without: {(1, 7), (114, 2)}),
      );
      expect(partial.missingAudio(), [(1, 7), (114, 2)]);
    });

    test('is a RecitationPlanner', () {
      expect(repo, isA<RecitationPlanner>());
    });
  });
}
