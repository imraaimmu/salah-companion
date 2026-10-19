/// Replays labelled prayers through the full pipeline and prints a summary.
///
///     dart run bin/replay.dart <dir>              # *.recording.ndjson + labels
///     dart run bin/replay.dart --matrix N [--seed S]
///                                                 # every case x seeds
///                                                 # S+1..S+N (S default 0),
///                                                 # clean and perturbed
///     dart run bin/replay.dart --batch N [--seed S]
///                                                 # generateSyntheticBatch
///     common: [--time-scale X] [--grace MS] [--pixel-noise PX] [--strict]
///             [--verbose]
///
/// `--pixel-noise PX` (synthetic modes) replaces the random pixel noise of
/// every perturbed prayer with PX pixels (a stress run; clean matrix prayers
/// stay clean). `--grace MS` sets the overrun grace (default 500 ms).
///
/// Heartbeats are inserted exactly as the engine emits them (docs/SPEC.md
/// section 5): only after 100 ms with no camera frame, at lastFrameT +
/// k*100 ms, never interleaved with frames; see lib/src/replay.dart.
///
/// Columns: wrong-time starts, overruns (still playing, not paused, beyond
/// the grace) and the worst overrun; `overrun0`, the same playing stretches
/// past the label with no grace at all (any audio after the label left
/// qiyam; reported, not gating); blind-spot pauses and resumes, and
/// `resumeBad`, resumes outside qiyam (wrong-time); missed qiyam (share of
/// eligible rak'ahs); prayers
/// whose final sitting was wrongly reached or not; rak'ah-1 starts during
/// the labelled takbir standing (`r1 early`, not wrong-time, see
/// lib/src/replay.dart; --strict scores them as wrong-time); label qiyam
/// start -> StartRecitation for rak'ah 1 and 2 (ms, p50/p90) and the rak'ah-1
/// starts more than 0.3 s off; `r2std` from the first standing-labelled
/// frame of qiyam2; label leaving qiyam -> silence (the final pause or
/// stop); `cutShort`, recitations stopped for good over 1 s before the label
/// left qiyam.
///
/// See lib/src/replay.dart for how each column is scored. Exit code 1 when
/// any wrong-time audio (wrong-time start, overrun or resume outside qiyam)
/// was found.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:salah_core/salah_core.dart';

const _usage = 'usage: dart run bin/replay.dart (<dir> | --matrix N '
    '[--seed S] | --batch N [--seed S]) [--time-scale X] [--grace MS] '
    '[--pixel-noise PX] [--strict] [--verbose]';

void main(List<String> args) {
  String? dir;
  int? matrix;
  int? batch;
  int? seed;
  double? pixelNoise;
  var timeScale = 0.05;
  var grace = defaultGraceMs;
  var verbose = false;
  var strict = false;
  try {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      String next() {
        if (i + 1 >= args.length) throw FormatException('$a needs a value');
        return args[++i];
      }

      switch (a) {
        case '--matrix':
          matrix = int.parse(next());
        case '--batch':
          batch = int.parse(next());
        case '--seed':
          seed = int.parse(next());
        case '--time-scale':
          timeScale = double.parse(next());
        case '--grace':
          grace = int.parse(next());
        case '--pixel-noise':
          pixelNoise = double.parse(next());
        case '--strict':
          strict = true;
        case '--verbose' || '-v':
          verbose = true;
        case '-h' || '--help':
          stdout.writeln(_usage);
          return;
        default:
          if (a.startsWith('-') || dir != null) {
            throw FormatException('unexpected argument "$a"');
          }
          dir = a;
      }
    }
    final modes = [dir, matrix, batch].where((m) => m != null).length;
    if (modes != 1) {
      throw const FormatException('give exactly one of <dir>, --matrix, '
          '--batch');
    }
    if (timeScale <= 0) throw const FormatException('--time-scale must be > 0');
    if (grace < 0) throw const FormatException('--grace must be >= 0');
    if (pixelNoise != null && (pixelNoise < 0 || dir != null)) {
      throw const FormatException(
          '--pixel-noise needs --matrix or --batch and a value >= 0');
    }
    if (seed != null && dir != null) {
      throw const FormatException('--seed needs --matrix or --batch');
    }
  } on Object catch (e) {
    stderr.writeln(e is FormatException ? e.message : '$e');
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  final options = ReplayOptions(graceMs: grace, strict: strict);
  final groups = <String, List<ReplayResult>>{};
  void add(String group, ReplayResult r) => (groups[group] ??= []).add(r);

  final sw = Stopwatch()..start();
  if (dir != null) {
    final files = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.recording.ndjson'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final base =
          f.path.substring(0, f.path.length - '.recording.ndjson'.length);
      final lf = File('$base.labels.ndjson');
      if (!lf.existsSync()) {
        stderr.writeln('skipping ${f.path}: no labels file');
        continue;
      }
      final rec = decodeRecording(f.readAsStringSync());
      final labels = decodeLabels(lf.readAsStringSync());
      final name = base.split(Platform.pathSeparator).last;
      add(name, replay(rec, labels, name: name, options: options));
    }
  } else if (matrix != null) {
    final offset = seed ?? 0;
    for (final c in SyntheticCase.values) {
      for (var s = offset + 1; s <= offset + matrix; s++) {
        final clean = generateSyntheticPrayer(c,
            seed: s, options: SyntheticOptions.clean(timeScale: timeScale));
        add(
            '${c.name} clean',
            replay(clean.recording, clean.labels,
                name: clean.name, options: options));
        final rng = math.Random(s * 1009 + c.index);
        var opts = SyntheticOptions.random(rng, timeScale: timeScale);
        if (pixelNoise != null) opts = opts.copyWith(pixelNoise: pixelNoise);
        final noisy = generateSyntheticPrayer(c,
            seed: s, options: opts, name: 'synthetic-${c.name}-s$s-perturbed');
        add(
            '${c.name} perturbed',
            replay(noisy.recording, noisy.labels,
                name: noisy.name, options: options));
      }
    }
  } else {
    for (final p in generateSyntheticBatch(batch!,
        seed: seed ?? 7777, timeScale: timeScale, pixelNoise: pixelNoise)) {
      add(p.scenario.name,
          replay(p.recording, p.labels, name: p.name, options: options));
    }
  }
  sw.stop();

  final all = [for (final g in groups.values) ...g];
  stdout.writeln(_table(groups, ReplaySummary(all)));
  stdout.writeln('${all.length} prayers in ${sw.elapsedMilliseconds} ms');

  final summary = ReplaySummary(all);
  if (verbose || summary.failures.isNotEmpty) {
    final failures = summary.failures.toList();
    if (failures.isNotEmpty) stdout.writeln('\nFailures:');
    for (final r in failures) {
      stdout.writeln('  ${r.name}: ${r.problems}');
    }
  }
  if (summary.wrongStarts + summary.overruns + summary.wrongResumes > 0) {
    exitCode = 1;
  }
}

String _table(Map<String, List<ReplayResult>> groups, ReplaySummary total) {
  const head = [
    'group',
    'n',
    'rak',
    'wrongStart',
    'overrun',
    'worstMs',
    'overrun0',
    'pause',
    'resume',
    'resumeBad',
    'missed',
    'rakWrong',
    'r1 early',
    'r1 p50/p90',
    'r1 off>0.3s',
    'r2 p50/p90',
    'r2std p50/p90',
    'stop p50/p90',
    'cutShort',
  ];
  String ms(int? v) => v == null ? '-' : '$v';
  List<String> row(String name, ReplaySummary s) => [
        name,
        '${s.prayers}',
        '${s.rakahs}',
        '${s.wrongStarts}',
        '${s.overruns}',
        '${s.worstOverrunMs}',
        '${s.overrunsAtZeroGrace}',
        '${s.pauses}',
        '${s.resumes}',
        '${s.wrongResumes}',
        '${s.missed} (${(100 * s.missedRate).toStringAsFixed(1)}%)',
        '${s.rakahCountWrong}',
        '${s.earlyStarts}',
        '${ms(s.startP(1, 50))}/${ms(s.startP(1, 90))}',
        '${s.rakah1OffTarget()}',
        '${ms(s.startP(2, 50))}/${ms(s.startP(2, 90))}',
        '${ms(s.startStdP(2, 50))}/${ms(s.startStdP(2, 90))}',
        '${ms(s.stopP(50))}/${ms(s.stopP(90))}',
        '${s.prematureStops}',
      ];
  final rows = [
    head,
    for (final e in groups.entries) row(e.key, ReplaySummary(e.value)),
    if (groups.length > 1) row('TOTAL', total),
  ];
  final widths = [
    for (var c = 0; c < head.length; c++)
      rows.map((r) => r[c].length).reduce(math.max),
  ];
  final buf = StringBuffer();
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    buf.writeln([
      for (var c = 0; c < r.length; c++)
        c == 0 ? r[c].padRight(widths[c]) : r[c].padLeft(widths[c]),
    ].join('  '));
    if (i == 0 || (i == rows.length - 2 && groups.length > 1)) {
      buf.writeln(widths.map((w) => '-' * w).join('  '));
    }
  }
  return buf.toString();
}
