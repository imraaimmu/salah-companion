/// Writes seeded synthetic Fajr prayers as recording + label NDJSON files.
///
///     dart run bin/generate_synthetic.dart <out-dir> [--count N] [--seed S]
///         [--time-scale X] [--case NAME] [--clean]
///
/// Without --case, cycles through every SyntheticCase with random
/// perturbations (generateSyntheticBatch). With --case, writes N prayers of
/// that case with seeds S, S+1, ...
///
/// --clean turns all perturbations off for every generated prayer: with
/// --case, N clean prayers of that case; without it, N clean prayers cycling
/// through every case with seeds S, S+1, ...
library;

import 'dart:io';

import 'package:salah_core/salah_core.dart';

const _usage = 'usage: dart run bin/generate_synthetic.dart <out-dir> '
    '[--count N] [--seed S] [--time-scale X] [--case NAME] [--clean]';

void main(List<String> args) {
  String? outDir;
  var count = 13;
  var seed = 1;
  var timeScale = 1.0;
  SyntheticCase? only;
  var clean = false;
  try {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      String next() {
        if (i + 1 >= args.length) throw FormatException('$a needs a value');
        return args[++i];
      }

      switch (a) {
        case '--count':
          count = int.parse(next());
        case '--seed':
          seed = int.parse(next());
        case '--time-scale':
          timeScale = double.parse(next());
        case '--case':
          only = SyntheticCase.values.byName(next());
        case '--clean':
          clean = true;
        case '-h' || '--help':
          stdout.writeln(_usage);
          stdout.writeln(
              'cases: ${SyntheticCase.values.map((c) => c.name).join(', ')}');
          return;
        default:
          if (a.startsWith('-') || outDir != null) {
            throw FormatException('unexpected argument "$a"');
          }
          outDir = a;
      }
    }
    if (outDir == null) throw const FormatException('missing <out-dir>');
    if (count < 1) throw const FormatException('--count must be >= 1');
    if (timeScale <= 0) throw const FormatException('--time-scale must be > 0');
  } on Object catch (e) {
    stderr.writeln(e is FormatException ? e.message : '$e');
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  final dir = Directory(outDir)..createSync(recursive: true);
  final Iterable<SyntheticPrayer> prayers;
  final options = clean
      ? SyntheticOptions.clean(timeScale: timeScale)
      : SyntheticOptions(timeScale: timeScale);
  if (only != null) {
    final c = only;
    prayers = [
      for (var i = 0; i < count; i++)
        generateSyntheticPrayer(c, seed: seed + i, options: options),
    ];
  } else if (clean) {
    const cases = SyntheticCase.values;
    prayers = [
      for (var i = 0; i < count; i++)
        generateSyntheticPrayer(cases[i % cases.length],
            seed: seed + i,
            options: options,
            name: 'synthetic-${(i + 1).toString().padLeft(4, '0')}-'
                '${cases[i % cases.length].name}-clean-s${seed + i}'),
    ];
  } else {
    prayers = generateSyntheticBatch(count, seed: seed, timeScale: timeScale);
  }
  for (final p in prayers) {
    File('${dir.path}/${p.recordingFileName}')
        .writeAsStringSync(p.encodeRecordingText());
    File('${dir.path}/${p.labelsFileName}')
        .writeAsStringSync(p.encodeLabelsText());
    stdout.writeln('${p.name}: ${p.recording.frames.length} frames, '
        '${(p.labels.intervals.last.endMs / 1000).toStringAsFixed(1)} s');
  }
}
