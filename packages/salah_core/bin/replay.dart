/// Replays labelled prayers through the full pipeline and prints a summary.
///
///     dart run bin/replay.dart <dir>              # *.recording.ndjson + labels
///     dart run bin/replay.dart --matrix N [--seed S]
///                                                 # every case x seeds
///                                                 # S+1..S+N (S default 0),
///                                                 # clean and perturbed
///     dart run bin/replay.dart --batch N [--seed S]
///                                                 # generateSyntheticBatch
///     common: [--prayer fajr|dhuhr|asr|maghrib|isha|all] [--time-scale X]
///             [--grace MS] [--pixel-noise PX] [--strict] [--verbose]
///
/// `--prayer` (synthetic modes; default fajr) picks the prayer to generate.
/// With `all`, the matrix runs every case that applies to each prayer, and
/// the batch cycles through the five prayers (prayer i is the (i mod 5)-th,
/// each cycling through its own cases). Group rows are named
/// `<prayer> <case> ...`, and a TOTAL row follows for every prayer, then the
/// overall TOTAL. Recordings read from a directory are replayed as the
/// prayer their labels name.
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
/// whose rak'ah count went wrong (`rakWrong`: final sitting wrongly reached
/// or not, or the machine in another rak'ah at the end of a labelled
/// sujood); rak'ah-1 starts during
/// the labelled takbir standing (`r1 early`, not wrong-time, see
/// lib/src/replay.dart; --strict scores them as wrong-time); label qiyam
/// start -> StartRecitation for rak'ah 1 to 4 (ms, p50/p90) and the rak'ah-1
/// starts more than 0.3 s off; `r2std` from the first standing-labelled
/// frame of qiyam 2; label leaving qiyam -> silence (the final pause or
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
    '[--seed S] | --batch N [--seed S]) '
    '[--prayer fajr|dhuhr|asr|maghrib|isha|all] [--time-scale X] '
    '[--grace MS] [--pixel-noise PX] [--strict] [--verbose]';

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
  List<Prayer>? prayers;
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
        case '--prayer':
          final v = next();
          prayers = v == 'all'
              ? Prayer.values
              : [
                  Prayer.values.firstWhere((p) => p.name == v,
                      orElse: () =>
                          throw FormatException('unknown prayer "$v"'))
                ];
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
    if (prayers != null && dir != null) {
      throw const FormatException('--prayer needs --matrix or --batch');
    }
  } on Object catch (e) {
    stderr.writeln(e is FormatException ? e.message : '$e');
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  final options = ReplayOptions(graceMs: grace, strict: strict);
  final ps = prayers ?? const [Prayer.fajr];
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
      add('${labels.prayer.name} $name',
          replay(rec, labels, name: name, options: options));
    }
  } else if (matrix != null) {
    final offset = seed ?? 0;
    for (final prayer in ps) {
      for (final c in SyntheticCase.forPrayer(prayer)) {
        for (var s = offset + 1; s <= offset + matrix; s++) {
          final clean = generateSyntheticPrayer(c,
              seed: s,
              prayer: prayer,
              options: SyntheticOptions.clean(timeScale: timeScale));
          add(
              '${prayer.name} ${c.name} clean',
              replay(clean.recording, clean.labels,
                  name: clean.name, options: options));
          final rng = math.Random(s * 1009 + c.index);
          var opts = SyntheticOptions.random(rng, timeScale: timeScale);
          if (pixelNoise != null) opts = opts.copyWith(pixelNoise: pixelNoise);
          final noisy = generateSyntheticPrayer(c,
              seed: s,
              prayer: prayer,
              options: opts,
              name: 'synthetic-${prayer.name}-${c.name}-s$s-perturbed');
          add(
              '${prayer.name} ${c.name} perturbed',
              replay(noisy.recording, noisy.labels,
                  name: noisy.name, options: options));
        }
      }
    }
  } else {
    for (final p in generateSyntheticBatch(batch!,
        seed: seed ?? 7777,
        timeScale: timeScale,
        pixelNoise: pixelNoise,
        prayers: ps)) {
      add('${p.prayer.name} ${p.scenario.name}',
          replay(p.recording, p.labels, name: p.name, options: options));
    }
  }
  sw.stop();

  // Groups sorted by prayer (in Prayer order), keeping insertion order
  // within a prayer.
  final byPrayer = <Prayer, Map<String, List<ReplayResult>>>{
    for (final p in Prayer.values) p: {},
  };
  groups.forEach((k, v) => byPrayer[v.first.prayer]![k] = v);
  final all = [for (final g in groups.values) ...g];
  stdout.writeln(_table(byPrayer, ReplaySummary(all)));
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

String _table(Map<Prayer, Map<String, List<ReplayResult>>> byPrayer,
    ReplaySummary total) {
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
    'r3 p50/p90',
    'r4 p50/p90',
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
        '${ms(s.startP(3, 50))}/${ms(s.startP(3, 90))}',
        '${ms(s.startP(4, 50))}/${ms(s.startP(4, 90))}',
        '${ms(s.startStdP(2, 50))}/${ms(s.startStdP(2, 90))}',
        '${ms(s.stopP(50))}/${ms(s.stopP(90))}',
        '${s.prematureStops}',
      ];
  final used = [
    for (final e in byPrayer.entries)
      if (e.value.isNotEmpty) e,
  ];
  final separators = <int>{1};
  final rows = [head];
  for (final e in used) {
    for (final g in e.value.entries) {
      rows.add(row(g.key, ReplaySummary(g.value)));
    }
    if (e.value.length > 1) {
      separators.add(rows.length);
      rows.add(row('${e.key.name.toUpperCase()} TOTAL',
          ReplaySummary([for (final g in e.value.values) ...g])));
    }
    separators.add(rows.length);
  }
  if (used.length > 1) rows.add(row('TOTAL', total));
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
    if (separators.contains(i + 1) && i + 1 < rows.length) {
      buf.writeln(widths.map((w) => '-' * w).join('  '));
    }
  }
  return buf.toString();
}
