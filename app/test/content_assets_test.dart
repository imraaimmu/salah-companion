// Checks the bundled content against the manifest in salah_core: every
// ayah has a placeholder clip that exists and is small, the catalog loads
// through the asset bundle, and the Quran text keeps Tanzil's notice.
//
// The placeholder audio is generated, not committed. If it is missing (a
// fresh clone), setUpAll runs `python3 scripts/make_placeholder_audio.py`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/audio/asset_audio_catalog.dart';
import 'package:salah_core/salah_core.dart';

const silencePath = 'assets/audio/silence_10s.wav';

/// Runs the generator if any catalog clip or the silence file is missing.
Future<void> ensurePlaceholderAudio(AssetAudioCatalog catalog) async {
  final files = [
    for (final s in surahManifest)
      for (var a = 1; a <= s.ayahCount; a++)
        catalog.entry(s.number, a)?.assetPath ?? '',
    silencePath,
  ];
  if (files.every((f) => f.isNotEmpty && File(f).existsSync())) return;
  final r = await Process.run('python3', [
    '../scripts/make_placeholder_audio.py',
    '--if-missing',
  ]);
  if (r.exitCode != 0) {
    fail(
      'Placeholder audio is missing and could not be generated. Run '
      '`python3 scripts/make_placeholder_audio.py` from the repository '
      'root.\n${r.stdout}\n${r.stderr}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('placeholder audio catalog', () {
    late AssetAudioCatalog catalog;

    setUpAll(() async {
      catalog = await AssetAudioCatalog.load(bundle: rootBundle);
      await ensurePlaceholderAudio(catalog);
    });

    test('is marked placeholder and covers every manifest ayah', () {
      expect(catalog.placeholder, isTrue);
      expect(catalog.length, 93);
      expect(ContentRepository(catalog).missingAudio(), isEmpty);
    });

    test('every clip exists, is 1-1.5 s and the set stays small', () {
      var bytes = 0;
      for (final s in surahManifest) {
        for (var a = 1; a <= s.ayahCount; a++) {
          final e = catalog.entry(s.number, a)!;
          final f = File(e.assetPath);
          expect(f.existsSync(), isTrue, reason: e.assetPath);
          bytes += f.lengthSync();
          expect(e.duration.inMilliseconds, inInclusiveRange(1000, 1500));
          expect(e.assetPath, endsWith('.wav'));
          // 16 kHz mono 16-bit: the file length matches the catalog duration.
          final pcm = f.lengthSync() - 44;
          expect(pcm, 16000 * 2 * e.duration.inMilliseconds ~/ 1000);
        }
      }
      expect(bytes, lessThan(4 * 1024 * 1024));
    });

    test('the silence file used for gaps exists and is bundled', () {
      // Read from disk: the asset bundle was built before setUpAll could
      // generate it on a fresh clone. pubspec bundles the whole folder.
      final f = File(silencePath);
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), 44 + 8000 * 2 * 10);
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('- assets/audio/\n'),
      );
    });

    test('plans built from it carry real durations', () {
      final plan = ContentRepository(catalog)
          .planFor(1, const SessionSettings());
      expect(plan.clips.first.assetPath, 'assets/audio/placeholder/001001.wav');
      expect(plan.clips.every((c) => c.duration > Duration.zero), isTrue);
    });

    test('rejects malformed JSON', () {
      expect(() => AssetAudioCatalog.parse('[]'), throwsFormatException);
    });
  });

  group('Quran text', () {
    late Map<String, Object?> json;

    setUpAll(() async {
      json = jsonDecode(
        await rootBundle.loadString('assets/quran/uthmani.json'),
      ) as Map<String, Object?>;
    });

    test('names the Tanzil source and keeps its copyright block', () {
      expect(json['source'], startsWith('Tanzil Quran Text (Uthmani'));
      final block = (json['copyright']! as List).cast<String>().join('\n');
      expect(
        block,
        contains('PLEASE DO NOT REMOVE OR CHANGE THIS COPYRIGHT BLOCK'),
      );
      expect(block, contains('CHANGING IT IS NOT ALLOWED'));
    });

    test('has every manifest surah with the manifest ayah count and name', () {
      final surahs = json['surahs']! as Map<String, Object?>;
      expect(
        surahs.keys.map(int.parse).toList(),
        surahManifest.map((s) => s.number).toList(),
      );
      for (final s in surahManifest) {
        final entry = surahs['${s.number}']! as Map<String, Object?>;
        expect((entry['ayahs']! as List), hasLength(s.ayahCount), reason: '$s');
        expect(entry['name'], s.arabicName, reason: '$s');
      }
    });
  });
}
