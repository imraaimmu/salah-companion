import 'dart:math';

import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// A tiny DSL for smoothed reading sequences at 15 fps.
// ---------------------------------------------------------------------------

const st = Posture.standing;
const bo = Posture.bowing;
const pr = Posture.prostrating;
const si = Posture.sitting;
const un = Posture.unknown;

/// Typical raw (torso degrees, hip ratio) per posture.
const Map<Posture, (double, double)> defaultRaw = {
  st: (5, 1.0),
  bo: (80, 0.9),
  pr: (70, 0.4),
  si: (10, 0.3),
};

/// Builds a sequence of smoothed readings. Frames are 1000/15 ms apart;
/// heartbeats ([lost]) are 100 ms apart. Segments can be named with a mark,
/// and [t] gives the first reading time at or after `mark + plusMs`.
class Script {
  final List<PostureReading> readings = [];
  final Map<String, int> marks = {};
  double _clock = 0;

  static const double frameMs = 1000 / 15;

  /// Parses e.g. `standing 3, takbir, standing 5 @q1, bowing 2 @r1, lost 3`.
  /// Tokens: `<posture> <seconds> [@mark]`, `takbir [@mark]` (one standing
  /// frame with a hand raise; default mark `takbir`), `raise [@mark]` (same,
  /// for later raises) and `lost <seconds> [@mark]` (heartbeats only).
  factory Script.parse(String text) => Script()..then(text);

  Script();

  int get now => _clock.round();

  void then(String text) {
    for (final raw in text.split(',')) {
      final parts = raw.trim().split(RegExp(r'\s+'));
      String? mark;
      if (parts.last.startsWith('@')) mark = parts.removeLast().substring(1);
      final word = parts.first;
      final secs = parts.length > 1 ? double.parse(parts[1]) : 0.0;
      switch (word) {
        case 'takbir':
          takbir(mark: mark ?? 'takbir');
        case 'raise':
          takbir(mark: mark);
        case 'lost':
          lost(secs, mark: mark);
        default:
          hold(Posture.values.byName(word), secs, mark: mark);
      }
    }
  }

  void _mark(String? mark) {
    if (mark != null) marks[mark] = now;
  }

  /// [seconds] of [p] frames. Raw values default to [defaultRaw]; pass
  /// [raw] false for none, or override [torso] / [hip].
  Script hold(Posture p, double seconds,
      {String? mark,
      bool raw = true,
      double? torso,
      double? hip,
      double conf = 0.9}) {
    _mark(mark);
    final n = (seconds * 15).round();
    final d = defaultRaw[p];
    for (var i = 0; i < n; i++) {
      readings.add(PostureReading(
        tMs: now,
        posture: p,
        confidence: p == un ? 0 : conf,
        torsoAngleDeg: torso ?? (raw ? d?.$1 : null),
        hipHeightRatio: hip ?? (raw ? d?.$2 : null),
      ));
      _clock += frameMs;
    }
    return this;
  }

  /// One standing frame carrying a takbir hand-raise event.
  Script takbir({String? mark}) {
    _mark(mark);
    readings.add(PostureReading(
        tMs: now,
        posture: st,
        confidence: 0.9,
        takbirRaise: true,
        torsoAngleDeg: 5,
        hipHeightRatio: 1.0));
    _clock += frameMs;
    return this;
  }

  /// [seconds] of 100 ms heartbeats (no person).
  Script lost(double seconds, {String? mark}) {
    _mark(mark);
    final n = (seconds * 10).round();
    for (var i = 0; i < n; i++) {
      readings.add(PostureReading.unknown(now));
      _clock += 100;
    }
    return this;
  }

  /// First reading time at or after [mark] + [plusMs].
  int t(String mark, [int plusMs = 0]) {
    final target = marks[mark]! + plusMs;
    return readings.firstWhere((r) => r.tMs >= target).tMs;
  }

  /// First reading time strictly after [ms].
  int after(int ms) => readings.firstWhere((r) => r.tMs > ms).tMs;

  /// Last reading time before [ms].
  int before(int ms) => readings.lastWhere((r) => r.tMs < ms).tMs;

  List<PrayerEvent> run([FajrStateMachine? m]) {
    final sm = m ?? FajrStateMachine();
    return [for (final r in readings) ...sm.add(r)];
  }
}

StateChanged sc(int t, PrayerState from, PrayerState to, int rakah) =>
    StateChanged(t, from: from, to: to, rakah: rakah);

const w = PrayerState.waiting;
const tk = PrayerState.takbir;
const q1 = PrayerState.qiyam1;
const r1 = PrayerState.ruku1;
const i1 = PrayerState.itidal1;
const s1 = PrayerState.sujood1;
const q2 = PrayerState.qiyam2;
const r2 = PrayerState.ruku2;
const i2 = PrayerState.itidal2;
const s2 = PrayerState.sujood2;
const fs = PrayerState.finalSitting;
const dn = PrayerState.done;

// ---------------------------------------------------------------------------
// A parametrised Fajr and its expected events.
// ---------------------------------------------------------------------------

class Variant {
  final double preStand;
  final bool takbir;
  final bool rukuRaise;
  final bool shafiiQunut;
  final bool malikiQunut;
  final bool briefSitting;
  final double jalsa;
  final bool missedRuku1;
  final bool missedRuku2;
  final double finalSit;
  final String sahw; // '', 'before', 'after'

  const Variant({
    this.preStand = 3,
    this.takbir = true,
    this.rukuRaise = false,
    this.shafiiQunut = false,
    this.malikiQunut = false,
    this.briefSitting = false,
    this.jalsa = 1,
    this.missedRuku1 = false,
    this.missedRuku2 = false,
    this.finalSit = 8,
    this.sahw = '',
  });
}

Script prayer(Variant v) {
  final s = Script()..hold(st, v.preStand, mark: 'pre');
  if (v.takbir) s.takbir(mark: 'takbir');
  for (final k in [1, 2]) {
    s.hold(st, 5, mark: 'q$k');
    if (k == 2 && v.malikiQunut) {
      s.then('raise, standing 1, raise, standing 2');
    }
    if (v.rukuRaise) s.takbir();
    final missed = k == 1 ? v.missedRuku1 : v.missedRuku2;
    if (missed) {
      // Bowing not recognised: unknown, but the raw torso is still seen.
      s.hold(un, 2, mark: 'r$k', torso: 80, hip: 0.9);
    } else {
      s.hold(bo, 2, mark: 'r$k');
    }
    s.hold(st, 1.5, mark: 'i$k');
    if (v.rukuRaise) s.takbir();
    if (k == 2 && v.shafiiQunut) {
      s.then('raise, standing 2, raise, standing 2, raise');
    }
    s.hold(pr, 2, mark: 's$k');
    s.hold(si, v.jalsa);
    s.hold(pr, 2);
    if (k == 1 && v.briefSitting) s.hold(si, 2);
  }
  s.hold(si, v.finalSit, mark: 'fs');
  if (v.sahw == 'before') {
    s.then('prostrating 2, sitting 1, prostrating 2, sitting 5');
  } else if (v.sahw == 'after') {
    s.then('prostrating 2, sitting 1, prostrating 2, sitting 4');
  }
  s.hold(st, 2, mark: 'up');
  return s;
}

List<PrayerEvent> expected(Script s, Variant v) {
  final e = <PrayerEvent>[];
  var state = w;
  void go(int t, PrayerState to, int rakah) {
    e.add(sc(t, state, to, rakah));
    state = to;
  }

  if (v.takbir) {
    go(s.t('takbir'), tk, 0);
    go(s.t('takbir', 800), q1, 1);
    e.add(StartRecitation(s.t('takbir', 800), rakah: 1));
    e.add(StopRecitation(s.t('r1', 200)));
  }
  for (final k in [1, 2]) {
    final missed = k == 1 ? v.missedRuku1 : v.missedRuku2;
    final ruku = k == 1 ? r1 : r2;
    final itidal = k == 1 ? i1 : i2;
    final sujood = k == 1 ? s1 : s2;
    if (!missed) {
      go(s.t('r$k', 500), ruku, k);
      go(s.t('i$k'), itidal, k);
    } else {
      // Filled in at the moment the prostration is confirmed.
      go(s.t('s$k', 500), ruku, k);
      go(s.t('s$k', 500), itidal, k);
    }
    go(s.t('s$k', 500), sujood, k);
    if (k == 1) {
      go(s.t('q2', 800), q2, 2);
      e.add(StartRecitation(s.t('q2', 800), rakah: 2));
      e.add(StopRecitation(s.t('r2', 200)));
    }
  }
  go(s.t('fs', 5000), fs, 2);
  go(s.t('up', 800), dn, 2);
  e.add(SessionEnded(s.t('up', 800), reason: EndReason.completed));
  return e;
}

void main() {
  group('DSL', () {
    test('parses segments, marks and heartbeats', () {
      final s = Script.parse('standing 1 @a, takbir, bowing 0.2, lost 0.3');
      expect(s.readings, hasLength(15 + 1 + 3 + 3));
      expect(s.marks, {'a': 0, 'takbir': 1000});
      expect(s.readings[15].takbirRaise, isTrue);
      expect(s.readings.last, PostureReading.unknown(s.readings.last.tMs));
      expect(s.readings[17].torsoAngleDeg, 80);
    });
  });

  group('full prayer', () {
    test('normal Fajr: every transition, audio and summary', () {
      const v = Variant();
      final s = prayer(v);
      final events = s.run();
      expect(events, expected(s, v));
      // Spot-check the literal sequence of states.
      expect(events.whereType<StateChanged>().map((e) => e.to).toList(),
          [tk, q1, r1, i1, s1, q2, r2, i2, s2, fs, dn]);
      expect(events.whereType<StateChanged>().map((e) => e.rakah).toList(),
          [0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2]);
    });

    final cases = <String, Variant>{
      'standing 30 s before takbir (iqamah): no audio until takbir':
          const Variant(preStand: 30),
      'Shafi\'i qunut (raised hands in i\'tidal of rak\'ah 2)':
          const Variant(shafiiQunut: true),
      'Maliki qunut (raised hands before ruku 2)':
          const Variant(malikiQunut: true),
      'raised hands at ruku and i\'tidal': const Variant(rukuRaise: true),
      'brief sitting before standing for rak\'ah 2':
          const Variant(briefSitting: true),
      'hurried jalsa (< 0.5 s)': const Variant(jalsa: 0.3),
      'long tashahhud (170 s): no premature done': const Variant(finalSit: 170),
      'sujood al-sahw before salam': const Variant(sahw: 'before'),
      'sujood al-sahw after salam': const Variant(sahw: 'after'),
    };
    cases.forEach((name, v) {
      test(name, () {
        final s = prayer(v);
        expect(s.run(), expected(s, v));
      });
    });

    test(
        'missed takbir: rak\'ah 1 silent, counting continues, rak\'ah 2 '
        'audio fires', () {
      const v = Variant(takbir: false, preStand: 10);
      final s = prayer(v);
      final events = s.run();
      expect(events, expected(s, v));
      expect(events.first, sc(s.t('r1', 500), w, r1, 1));
      expect(events.whereType<StartRecitation>().toList(),
          [StartRecitation(s.t('q2', 800), rakah: 2)]);
    });

    test('missed ruku in rak\'ah 1: prostration anchors, ruku filled in', () {
      const v = Variant(missedRuku1: true);
      final s = prayer(v);
      final events = s.run();
      expect(events, expected(s, v));
      final t = s.t('s1', 500);
      expect(
          events,
          containsAllInOrder([
            StopRecitation(s.t('r1', 200)),
            sc(t, q1, r1, 1),
            sc(t, r1, i1, 1),
            sc(t, i1, s1, 1),
          ]));
    });

    test('missed i\'tidal (ruku straight to prostration) is filled in', () {
      final s = Script.parse('standing 1, takbir, standing 2, bowing 1 @r, '
          'prostrating 1 @p');
      expect(s.run().sublist(4), [
        sc(s.t('r', 500), q1, r1, 1),
        sc(s.t('p', 500), r1, i1, 1),
        sc(s.t('p', 500), i1, s1, 1),
      ]);
    });

    test('takbir then straight to prostration fills ruku and i\'tidal', () {
      final s = Script.parse('standing 1, takbir, standing 0.5, '
          'prostrating 1 @p');
      final t = s.t('p', 500);
      expect(s.run(), [
        sc(s.t('takbir'), w, tk, 0),
        sc(t, tk, r1, 1),
        sc(t, r1, i1, 1),
        sc(t, i1, s1, 1),
      ]);
    });

    test('missed ruku in rak\'ah 2', () {
      const v = Variant(missedRuku2: true);
      final s = prayer(v);
      expect(s.run(), expected(s, v));
    });

    test('long tashahhud stays in finalSitting until the user stands', () {
      const v = Variant(finalSit: 170);
      final s = prayer(v);
      final events = s.run();
      final done = events.whereType<StateChanged>().last;
      expect(done.to, dn);
      expect(done.tMs, s.t('up', 800));
    });
  });

  group('waiting', () {
    test('standing for 9 minutes triggers nothing', () {
      expect(Script.parse('standing 540').run(), isEmpty);
    });

    test('raised hands later are not a takbir', () {
      final s = Script.parse(
          'standing 2, bowing 1 @r, standing 1 @i, raise, standing 2');
      expect(s.run(), [sc(s.t('r', 500), w, r1, 1), sc(s.t('i'), r1, i1, 1)]);
    });

    test('takbir with a short standing then bowing: no rak\'ah 1 audio', () {
      final s = Script.parse('standing 1, takbir, standing 0.5, bowing 1 @r');
      expect(s.run(), [
        sc(s.t('takbir'), w, tk, 0),
        sc(s.t('r', 500), tk, r1, 1),
      ]);
    });

    test(
        'missed takbir and missed ruku: prostration from waiting anchors '
        'sujood1, no rak\'ah 1 audio', () {
      final s = Script.parse('standing 3, prostrating 1 @p, sitting 1, '
          'prostrating 1, standing 2 @q');
      expect(s.run(), [
        sc(s.t('p', 500), w, r1, 1),
        sc(s.t('p', 500), r1, i1, 1),
        sc(s.t('p', 500), i1, s1, 1),
        sc(s.t('q', 800), s1, q2, 2),
        StartRecitation(s.t('q', 800), rakah: 2),
      ]);
    });

    test('a short bow (< 0.5 s) in waiting is ignored', () {
      expect(Script.parse('standing 2, bowing 0.4, standing 2').run(), isEmpty);
    });
  });

  group('rak\'ah 2 anchors', () {
    Script toSujood1() => Script.parse('standing 1, takbir, standing 2, '
        'bowing 1, standing 1, prostrating 1, sitting 0.5, prostrating 1');

    test('sitting in sujood1 never starts rak\'ah 2', () {
      final s = toSujood1()..hold(si, 60);
      expect(s.run().whereType<StartRecitation>().map((e) => e.rakah), [1]);
    });

    test('smoothed standing with raw hip below 0.8 does not count as Qiyam',
        () {
      // A misread during the brief sitting: smoothed "standing", but the raw
      // hip height says sitting.
      final s = toSujood1()
        ..hold(st, 3, hip: 0.3, torso: 10)
        ..hold(st, 2, mark: 'q');
      final events = s.run();
      expect(events.whereType<StartRecitation>().toList(), [
        StartRecitation(s.t('takbir', 800), rakah: 1),
        StartRecitation(s.t('q', 800), rakah: 2),
      ]);
    });

    test(
        'standing flicker during jalsa (smoothed standing < 0.8 s between '
        'sittings) never starts rak\'ah 2', () {
      final s = toSujood1()
        ..then('sitting 0.3, standing 0.2, sitting 0.2, standing 0.4, '
            'sitting 0.3, standing 0.75, sitting 0.4, prostrating 1')
        // A longer misread with sitting raw values: the hip check rejects it.
        ..hold(st, 2, torso: 10, hip: 0.35)
        ..hold(pr, 1)
        ..hold(si, 1)
        ..hold(st, 2, mark: 'q');
      final events = s.run();
      expect(events.whereType<StartRecitation>().toList(), [
        StartRecitation(s.t('takbir', 800), rakah: 1),
        StartRecitation(s.t('q', 800), rakah: 2),
      ]);
      expect(events.whereType<StateChanged>().where((e) => e.to == q2),
          [sc(s.t('q', 800), s1, q2, 2)]);
    });

    test('a standing hold with missing raw values is accepted', () {
      final s = toSujood1()..hold(st, 1, mark: 'q', raw: false);
      expect(s.run().last, StartRecitation(s.t('q', 800), rakah: 2));
    });

    test('standing 0.7 s after a prostration is not enough', () {
      final s = toSujood1()
        ..then('standing 0.7, sitting 1, standing 0.7, prostrating 1');
      expect(s.run().whereType<StartRecitation>().map((e) => e.rakah), [1]);
    });

    test(
        'rising from sujood misread as bowing (hips low) does not enter ruku2: '
        'qiyam 2 and its recitation still come', () {
      // Smoothed bowing for 600 ms (> the 0.5 s ruku hold) with the raw hip
      // at 0.65, as when getting up from the second prostration.
      final s = toSujood1()
        ..hold(bo, 0.6, torso: 60, hip: 0.65)
        ..hold(st, 2, mark: 'q');
      final events = s.run();
      expect(events.whereType<StateChanged>().map((e) => e.to),
          isNot(contains(r2)));
      expect(events.sublist(events.length - 2), [
        sc(s.t('q', 800), s1, q2, 2),
        StartRecitation(s.t('q', 800), rakah: 2),
      ]);
    });

    test('a real ruku (hips at standing height, or no hip value) still counts',
        () {
      final s = toSujood1()
        ..hold(st, 2, mark: 'q')
        ..hold(bo, 1, mark: 'r', hip: 1.0);
      expect(s.run().last, sc(s.t('r', 500), q2, r2, 2));
      final s2 = toSujood1()
        ..hold(st, 2, mark: 'q')
        ..hold(bo, 1, mark: 'r', torso: 80, raw: false);
      expect(s2.run().last, sc(s2.t('r', 500), q2, r2, 2));
    });

    test('bowing straight from sujood1 enters ruku2 without audio', () {
      final s = toSujood1()..then('standing 0.5, bowing 1 @r');
      final events = s.run();
      expect(events.last, sc(s.t('r', 500), s1, r2, 2));
      expect(events.whereType<StartRecitation>().map((e) => e.rakah), [1]);
    });

    test('standing in sujood2 (extra rak\'ah) plays nothing', () {
      final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
          'standing 1, prostrating 1, sitting 0.5, prostrating 1, '
          'standing 2, bowing 1, standing 1, prostrating 1 @p, sitting 0.5, '
          'prostrating 1, standing 20, bowing 1, standing 1');
      final events = s.run();
      expect(events.last, sc(s.t('p', 500), i2, s2, 2));
      expect(events.whereType<StartRecitation>().map((e) => e.rakah), [1, 2]);
    });

    const rak2Sujood = 'standing 1, takbir, standing 2, bowing 1, '
        'standing 1, prostrating 1, sitting 0.5, prostrating 1, '
        'standing 2, bowing 1, standing 1, prostrating 1 @p';

    test('final-sitting hold tolerates unknown/blind gaps of 1 s in total', () {
      // Review finding: one dropout in the 5 s used to restart the hold, so
      // a short tashahhud with a few unknown frames never reached it.
      final s = Script.parse('$rak2Sujood, sitting 2 @fs')
        ..lost(0.4)
        ..hold(un, 0.4, raw: false)
        ..hold(si, 4);
      final t0 = s.marks['fs']!;
      expect(s.run().whereType<StateChanged>().last,
          sc(s.after(t0 + 4999), s2, fs, 2));
    });

    test('final-sitting hold: gaps over 1 s in total restart it', () {
      final s = Script.parse('$rak2Sujood, sitting 2')
        ..lost(0.6)
        ..hold(si, 1)
        ..lost(0.6, mark: 'gap2')
        ..hold(si, 6, mark: 'again');
      // The second gap brings the total to 1.2 s: the hold restarts at the
      // first sitting frame after it.
      expect(s.run().whereType<StateChanged>().last,
          sc(s.t('again', 5000), s2, fs, 2));
    });

    test('final-sitting hold: any other posture restarts it', () {
      for (final other in [st, bo, pr]) {
        final s = Script.parse('$rak2Sujood, sitting 3')
          ..hold(other, 0.2)
          ..hold(si, 6, mark: 'again');
        expect(s.run().whereType<StateChanged>().last,
            sc(s.t('again', 5000), s2, fs, 2),
            reason: other.name);
      }
    });

    test('sitting must be held 5 s for the final sitting', () {
      final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
          'standing 1, prostrating 1, sitting 0.5, prostrating 1, '
          'standing 2, bowing 1, standing 1, prostrating 1, sitting 4.9, '
          'prostrating 1, sitting 5.5 @fs');
      expect(s.run().last, sc(s.t('fs', 5000), s2, fs, 2));
    });
  });

  group('early stop', () {
    Script reciting() => Script.parse('standing 1, takbir, standing 3');

    test(
        'raw torso > 35 degrees stops within 0.2-0.3 s while the smoothed '
        'posture still says standing', () {
      final s = reciting()
        ..hold(st, 0.4, mark: 'lean', torso: 50, hip: 0.95)
        ..hold(bo, 1, mark: 'bow');
      final events = s.run();
      final stop = events.whereType<StopRecitation>().single;
      final latency = stop.tMs - s.marks['lean']!;
      expect(latency, inInclusiveRange(200, 300));
      expect(stop.tMs, lessThan(s.marks['bow']!));
      expect(events.last, sc(s.t('bow', 500), q1, r1, 1));
    });

    test('raw hip below 0.8 stops too', () {
      final s = reciting()..hold(st, 1, mark: 'drop', torso: 10, hip: 0.7);
      expect(s.run().last, StopRecitation(s.t('drop', 200)));
    });

    test('a 0.13 s lean does not stop; the run must be continuous', () {
      final s = reciting()
        ..hold(st, 0.14, torso: 50)
        ..hold(st, 1)
        ..hold(st, 0.14, torso: 50)
        ..hold(st, 1);
      expect(s.run().whereType<StopRecitation>(), isEmpty);
    });

    // Frames every 66 ms with a heartbeat 30 ms after each. The last body
    // data before each heartbeat shows the lean, so the heartbeat's time
    // counts toward the 0.2 s: the stop lands on the first reading >= 200 ms
    // into the lean, the heartbeat at 228 ms (264 ms without heartbeats).
    test('interleaved heartbeats do not delay the stop', () {
      final s = reciting();
      final lean = s.now;
      s.marks['lean'] = lean;
      for (var i = 0; i < 6; i++) {
        s.readings.add(PostureReading(
            tMs: lean + i * 66,
            posture: st,
            confidence: 0.9,
            torsoAngleDeg: 60,
            hipHeightRatio: 0.9));
        s.readings.add(PostureReading.unknown(lean + i * 66 + 30));
      }
      expect(s.run().last, StopRecitation(lean + 228));
    });

    test(
        'end to end through MajoritySmoother: stop precedes the smoothed '
        'posture change by > 0 ms and lands 0.2-0.3 s after the bow starts',
        () {
      final raw = Script.parse('standing 2, takbir, standing 3')
        ..hold(bo, 2, mark: 'bow');
      final smoother = MajoritySmoother();
      final smoothed = [for (final r in raw.readings) smoother.add(r)];
      final m = FajrStateMachine();
      final events = [for (final r in smoothed) ...m.add(r)];
      final stop = events.whereType<StopRecitation>().single;
      final bow = raw.marks['bow']!;
      expect(stop.tMs - bow, inInclusiveRange(200, 300));
      final firstSmoothedBow =
          smoothed.firstWhere((r) => r.posture != st && r.tMs > bow).tMs;
      expect(stop.tMs, lessThan(firstSmoothedBow));
    });

    test(
        'stop fires once per recitation, and on leaving Qiyam if raw values '
        'were missing', () {
      final s = Script.parse('standing 1, takbir, standing 2')
        ..hold(bo, 1, mark: 'r', raw: false);
      final events = s.run();
      expect(events.sublist(events.length - 2), [
        StopRecitation(s.t('r', 500)),
        sc(s.t('r', 500), q1, r1, 1),
      ]);
    });

    test('no stop outside a recitation (i\'tidal lean, sujood)', () {
      final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
          'standing 1, prostrating 1, sitting 1');
      expect(s.run().whereType<StopRecitation>(), hasLength(1));
    });
  });

  group('blind spots (pause and resume)', () {
    Script reciting() => Script.parse('standing 1, takbir, standing 3 @q');
    List<PrayerEvent> audio(List<PrayerEvent> events) => [
          for (final e in events)
            if (e is StartRecitation ||
                e is StopRecitation ||
                e is PauseRecitation ||
                e is ResumeRecitation ||
                e is TrackingLost)
              e,
        ];

    test('no body data for > 0.6 s pauses; standing data for 0.2 s resumes',
        () {
      final s = reciting()
        ..lost(0.8, mark: 'blind')
        ..hold(st, 2, mark: 'back');
      final lastSeen = s.before(s.marks['blind']!);
      expect(audio(s.run()), [
        StartRecitation(s.t('takbir', 800), rakah: 1),
        PauseRecitation(s.after(lastSeen + 600), rakah: 1),
        ResumeRecitation(s.t('back', 200), rakah: 1),
      ]);
    });

    test('a blind spot of 0.6 s or less does nothing', () {
      final s = reciting()
        ..lost(0.5)
        ..hold(st, 2);
      expect(audio(s.run()), [StartRecitation(s.t('takbir', 800), rakah: 1)]);
    });

    test('smoothed standing with no raw values is still a blind spot', () {
      final s = reciting()
        ..hold(st, 0.8, mark: 'blind', raw: false)
        ..hold(st, 1, mark: 'back');
      final lastSeen = s.before(s.marks['blind']!);
      expect(audio(s.run()), [
        StartRecitation(s.t('takbir', 800), rakah: 1),
        PauseRecitation(s.after(lastSeen + 600), rakah: 1),
        ResumeRecitation(s.t('back', 200), rakah: 1),
      ]);
    });

    test('pause, then data shows the user left standing: final stop', () {
      final s = reciting()
        ..lost(0.8)
        ..hold(bo, 2, mark: 'down')
        ..hold(st, 2, mark: 'up');
      final events = s.run();
      expect(audio(events).sublist(2), [StopRecitation(s.t('down', 200))]);
      expect(events.whereType<StateChanged>().skip(2).toList(), [
        sc(s.t('down', 500), q1, r1, 1),
        sc(s.t('up'), r1, i1, 1),
      ]);
    });

    test('pause, then the state moves on (ruku confirmed unseen): stop', () {
      final s = reciting()
        ..lost(1)
        ..hold(bo, 1, mark: 'down', raw: false);
      final events = s.run();
      expect(events.sublist(events.length - 2), [
        StopRecitation(s.t('down', 500)),
        sc(s.t('down', 500), q1, r1, 1),
      ]);
      expect(events.whereType<ResumeRecitation>(), isEmpty);
    });

    test('pause, then tracking lost: stop for good, no resume on return', () {
      final s = reciting()
        ..lost(3, mark: 'blind')
        ..hold(st, 3, mark: 'back');
      final lastSeen = s.before(s.marks['blind']!);
      final lostAt = s.after(lastSeen + 2000);
      expect(audio(s.run()), [
        StartRecitation(s.t('takbir', 800), rakah: 1),
        PauseRecitation(s.after(lastSeen + 600), rakah: 1),
        StopRecitation(lostAt),
        TrackingLost(lostAt),
      ]);
    });

    test(
        'paused for 2 s without body data while the smoothed posture still '
        'sees a person: stop (the user may have bowed and stood up unseen)',
        () {
      final s = reciting()
        ..hold(st, 3, mark: 'blind', raw: false)
        ..hold(st, 2);
      final lastSeen = s.before(s.marks['blind']!);
      final pause = s.after(lastSeen + 600);
      final events = s.run();
      expect(audio(events), [
        StartRecitation(s.t('takbir', 800), rakah: 1),
        PauseRecitation(pause, rakah: 1),
        StopRecitation(s.after(pause + 2000)),
      ]);
    });

    test('never resumes after a stop', () {
      // Paused, then a lean seen for 0.2 s stops it; standing again later
      // (still qiyam1) must not bring it back.
      final s = reciting()
        ..lost(0.8)
        ..hold(st, 0.3, mark: 'lean', torso: 50)
        ..hold(st, 3)
        ..lost(1)
        ..hold(st, 2);
      final events = audio(s.run());
      expect(events.sublist(2), [StopRecitation(s.t('lean', 200))]);
    });

    test('resumes once per pause; a second blind spot pauses again', () {
      final s = reciting()
        ..lost(0.8)
        ..hold(st, 2, mark: 'back1')
        ..lost(0.8)
        ..hold(st, 2, mark: 'back2');
      final events = audio(s.run());
      expect(events.whereType<PauseRecitation>(), hasLength(2));
      expect(events.whereType<ResumeRecitation>().toList(), [
        ResumeRecitation(s.t('back1', 200), rakah: 1),
        ResumeRecitation(s.t('back2', 200), rakah: 1),
      ]);
      expect(events.whereType<StartRecitation>(), hasLength(1));
    });

    test('blind span over maxResumeBlindMs (1.5 s): stop, never resume', () {
      // Review finding: blind for 1.5-1.9 s then standing data resumed the
      // recitation, but a fast ruku fits in ~2 s, so that standing may be
      // the i'tidal. The span runs from the last body data before the pause
      // to the first body data after it.
      for (final (blindMs, resume) in [
        (900, true),
        (1400, true),
        (1600, false),
        (1900, false)
      ]) {
        final m = FajrStateMachine();
        final ev = <PrayerEvent>[];
        var t = 0;
        PostureReading stand(int t, {bool tk = false}) => PostureReading(
            tMs: t,
            posture: st,
            confidence: 0.9,
            takbirRaise: tk,
            hipHeightRatio: 1.0,
            torsoAngleDeg: 3);
        ev.addAll(m.add(stand(t, tk: true)));
        for (t = 66; t < 2000; t += 66) {
          ev.addAll(m.add(stand(t)));
        }
        final last = t - 66;
        // Unseen: the smoother still says standing for a moment, then
        // unknown; no raw values (heartbeats).
        for (t = last + 100; t < last + blindMs; t += 100) {
          ev.addAll(m.add(PostureReading(
              tMs: t, posture: t - last < 300 ? st : un, confidence: 0)));
        }
        final back = last + blindMs;
        for (t = back; t < back + 600; t += 66) {
          ev.addAll(m.add(stand(t)));
        }
        final audio = ev.where((e) => e is! StateChanged).toList();
        expect(audio[1], isA<PauseRecitation>(), reason: '$blindMs ms');
        if (resume) {
          expect(audio.sublist(2), [ResumeRecitation(back + 264, rakah: 1)],
              reason: '$blindMs ms');
        } else {
          expect(audio.sublist(2), [StopRecitation(back)],
              reason: '$blindMs ms');
        }
        expect(m.state, q1);
      }
    });

    test('resume needs confidence >= 0.5 and, once calibrated, hip >= 0.8', () {
      // Review finding: torso-only or low-confidence data resumed audio.
      List<PrayerEvent> resumes(void Function(Script s) back) {
        final s = reciting()..lost(0.8);
        back(s);
        return s.run().whereType<ResumeRecitation>().toList();
      }

      // Torso only (no ankle, so no hip height) after the hip was seen.
      expect(resumes((s) => s.hold(st, 1, hip: null, raw: false, torso: 5)),
          isEmpty);
      // Low smoothed confidence.
      expect(resumes((s) => s.hold(st, 1, conf: 0.4)), isEmpty);
      // Smoothed posture not (yet) standing, raw values fine.
      expect(resumes((s) => s.hold(un, 1, torso: 5, hip: 1.0)), isEmpty);
      // Good data resumes.
      expect(resumes((s) => s.hold(st, 1)), hasLength(1));
      // Not calibrated yet (no reading ever had a hip ratio): torso-only
      // standing at good confidence may resume.
      final u = Script()..hold(st, 1, raw: false, torso: 5);
      u.marks['takbir'] = u.now;
      u.readings.add(PostureReading(
          tMs: u.now,
          posture: st,
          confidence: 0.9,
          takbirRaise: true,
          torsoAngleDeg: 5));
      u
        ..hold(st, 3, raw: false, torso: 5)
        ..lost(0.8)
        ..hold(st, 1, raw: false, torso: 5, mark: 'back');
      expect(u.run().whereType<ResumeRecitation>().toList(),
          [ResumeRecitation(u.t('back', 200), rakah: 1)]);
    });

    test('a resume and a stop caused by the same reading: only the stop', () {
      // Paused, standing data comes back, and the 200 ms resume lands on the
      // very reading where qiyam1 times out (stateTimeoutMs chosen so).
      final s = reciting()
        ..lost(0.8)
        ..hold(st, 1, mark: 'back');
      final resumeAt = s.t('back', 200);
      final qiyamAt = s.t('takbir', 800);
      final events =
          s.run(FajrStateMachine(stateTimeoutMs: resumeAt - qiyamAt - 1));
      expect(events.whereType<ResumeRecitation>(), isEmpty);
      expect(events.sublist(events.length - 2), [
        StopRecitation(resumeAt),
        SessionEnded(resumeAt, reason: EndReason.timeout),
      ]);
      // Without the timeout the same reading resumes.
      expect(s.run().whereType<ResumeRecitation>().toList(),
          [ResumeRecitation(resumeAt, rakah: 1)]);
    });

    test('resume needs unbroken standing data for 0.2 s', () {
      final s = reciting()..lost(1);
      final back = s.now;
      // Standing frames with a heartbeat between each pair: never 0.2 s of
      // standing data without a blind reading.
      for (var i = 0; i < 10; i++) {
        s.readings.add(PostureReading(
            tMs: back + i * 150,
            posture: st,
            confidence: 0.9,
            torsoAngleDeg: 5,
            hipHeightRatio: 1));
        s.readings.add(PostureReading(
            tMs: back + i * 150 + 67,
            posture: st,
            confidence: 0.9,
            torsoAngleDeg: 5,
            hipHeightRatio: 1));
        s.readings.add(PostureReading.unknown(back + i * 150 + 100));
      }
      expect(s.run().whereType<ResumeRecitation>(), isEmpty);
    });

    test('no data after data showing a lean counts toward the 0.2 s stop', () {
      final s = reciting()
        ..hold(st, 0.14, mark: 'lean', torso: 50)
        ..lost(0.5);
      final events = audio(s.run());
      final stop = events.whereType<StopRecitation>().single;
      expect(stop.tMs - s.marks['lean']!, inInclusiveRange(200, 300));
      expect(events.whereType<PauseRecitation>(), isEmpty);
    });

    test('a blind spot while not reciting emits nothing', () {
      expect(Script.parse('standing 2, lost 1.5, standing 2').run(), isEmpty);
      final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
          'standing 1 @i, lost 1.5, standing 1, prostrating 1, lost 1, '
          'sitting 1');
      final events = s.run();
      final after = events.where((e) => e.tMs >= s.marks['i']!);
      expect(
          after.where((e) => e is! StateChanged), isEmpty); // no audio events
    });
  });

  group('lost tracking', () {
    test('mid-qiyam: stop + freeze, restore, no restart of rak\'ah 1', () {
      final s = Script.parse('standing 1, takbir, standing 3 @q, lost 3 @l, '
          'standing 3 @back, bowing 1 @r');
      final lastSeen = s.before(s.marks['l']!);
      final lostAt = s.after(lastSeen + 2000);
      expect(s.run(), [
        sc(s.t('takbir'), w, tk, 0),
        sc(s.t('takbir', 800), tk, q1, 1),
        StartRecitation(s.t('takbir', 800), rakah: 1),
        PauseRecitation(s.after(lastSeen + 600), rakah: 1),
        StopRecitation(lostAt),
        TrackingLost(lostAt),
        TrackingRestored(s.t('back')),
        sc(s.t('r', 500), q1, r1, 1),
      ]);
    });

    test('lost before Qiyam: the hold restarts from scratch on return', () {
      final s = Script.parse('standing 1, takbir, standing 0.6, lost 2.5, '
          'standing 0.6, lost 2.5 @l2, standing 2 @back');
      final events = s.run();
      expect(events.whereType<StartRecitation>().toList(),
          [StartRecitation(s.t('back', 800), rakah: 1)]);
      expect(events.sublist(events.length - 3), [
        TrackingRestored(s.t('back')),
        sc(s.t('back', 800), tk, q1, 1),
        StartRecitation(s.t('back', 800), rakah: 1),
      ]);
    });

    test('a gap of 2 s or less is not lost tracking', () {
      final s = Script.parse('standing 1, takbir, standing 2, lost 1.9, '
          'standing 1 @back');
      final events = s.run();
      expect(events.whereType<TrackingLost>(), isEmpty);
      // But a 1.9 s blind span is too long to resume after (a ruku fits).
      expect(events.whereType<ResumeRecitation>(), isEmpty);
      expect(events.whereType<StopRecitation>().toList(),
          [StopRecitation(s.t('back'))]);
    });

    test(
        'child in frame (unclear match reported as no person) mid-qiyam 2: '
        'stop and stay silent', () {
      final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
          'standing 1, prostrating 1, sitting 0.5, prostrating 1, '
          'standing 2 @q2, lost 4, standing 3, bowing 1 @r');
      final events = s.run();
      expect(events.whereType<StartRecitation>().map((e) => e.rakah), [1, 2]);
      expect(events.whereType<TrackingLost>(), hasLength(1));
      expect(events.last, sc(s.t('r', 500), q2, r2, 2));
    });

    test('lost for over 30 s ends the session (cameraLost)', () {
      final s = Script.parse('standing 1, takbir, standing 2 @q, lost 40');
      final events = s.run();
      final lost = events.whereType<TrackingLost>().single;
      expect(
          events.last,
          SessionEnded(s.after(lost.tMs + 30000),
              reason: EndReason.cameraLost));
      // takbir, qiyam, start, pause, stop, lost, end
      expect(events, hasLength(7));
    });

    test('final sitting and out of frame over 10 s: done', () {
      final s = prayer(const Variant());
      // Replace the stand-up with a walk-out.
      final cut = s.readings.indexWhere((r) => r.tMs >= s.marks['up']!);
      s.readings.removeRange(cut, s.readings.length);
      s.lost(12, mark: 'gone');
      final lastSeen = s.before(s.marks['gone']!);
      final events = s.run();
      expect(events.sublist(events.length - 3), [
        TrackingLost(s.after(lastSeen + 2000)),
        sc(s.after(lastSeen + 10000), fs, dn, 2),
        SessionEnded(s.after(lastSeen + 10000), reason: EndReason.completed),
      ]);
    });
  });

  group('timeouts', () {
    test('waiting: 10 minutes', () {
      final s = Script.parse('standing 601');
      expect(
          s.run(), [SessionEnded(s.after(600000), reason: EndReason.timeout)]);
    });

    test('no person from the start: lost after 2 s, cameraLost 30 s later', () {
      final s = Script.parse('lost 610');
      final events = s.run();
      expect(events.first, TrackingLost(2100));
      expect(events.last, SessionEnded(32200, reason: EndReason.cameraLost));
    });

    test('qiyam held over 180 s: stop, then timeout', () {
      final s = Script.parse('standing 1, takbir, standing 185');
      final q = s.t('takbir', 800);
      final events = s.run();
      expect(events.sublist(events.length - 2), [
        StopRecitation(s.after(q + 180000)),
        SessionEnded(s.after(q + 180000), reason: EndReason.timeout),
      ]);
    });

    test('sujood1 over 180 s (a very long sitting): timeout, no audio', () {
      final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
          'standing 1, prostrating 1 @p, sitting 200');
      final events = s.run();
      expect(
          events.last,
          SessionEnded(s.after(s.t('p', 500) + 180000),
              reason: EndReason.timeout));
      expect(events.whereType<StartRecitation>().map((e) => e.rakah), [1]);
    });

    test('final sitting over 180 s: done (completed)', () {
      final s = prayer(const Variant(finalSit: 200));
      final entered = s.t('fs', 5000);
      final events = s.run();
      expect(events.sublist(events.length - 2), [
        sc(s.after(entered + 180000), fs, dn, 2),
        SessionEnded(s.after(entered + 180000), reason: EndReason.completed),
      ]);
    });
  });

  group('API', () {
    test('no events after SessionEnded until reset', () {
      final m = FajrStateMachine();
      final s = prayer(const Variant());
      final first = s.run(m);
      expect(m.ended, isTrue);
      expect(m.state, dn);
      expect(m.add(const PostureReading.unknown(999999)), isEmpty);
      m.reset();
      expect(m.state, w);
      // Same sequence again, same events.
      expect(s.run(m), first);
    });

    test('run() maps the stream and closes after SessionEnded', () async {
      final s = prayer(const Variant());
      s.hold(st, 5); // extra readings after done
      final events = await FajrStateMachine()
          .run(Stream.fromIterable(s.readings))
          .toList();
      expect(events, s.run());
      expect(events.last, isA<SessionEnded>());
    });

    test('out-of-order timestamps are clamped', () {
      final m = FajrStateMachine();
      m.add(const PostureReading(tMs: 1000, posture: st, confidence: 0.9));
      final e = m.add(const PostureReading(
          tMs: 500, posture: st, confidence: 0.9, takbirRaise: true));
      expect(e, [sc(1000, w, tk, 0)]);
    });

    test('thresholds are constructor parameters', () {
      final m = FajrStateMachine(
          qiyam1HoldMs: 1500, rukuHoldMs: 300, earlyStopHoldMs: 400);
      final s = Script.parse('standing 1, takbir, standing 2, bowing 1 @r');
      // Ruku confirms at 300 ms, before the 400 ms early stop, so leaving
      // qiyam1 closes the recitation.
      expect(s.run(m), [
        sc(s.t('takbir'), w, tk, 0),
        sc(s.t('takbir', 1500), tk, q1, 1),
        StartRecitation(s.t('takbir', 1500), rakah: 1),
        StopRecitation(s.t('r', 300)),
        sc(s.t('r', 300), q1, r1, 1),
      ]);
    });

    test('custom waiting and lost-tracking limits', () {
      final m = FajrStateMachine(trackingLostMs: 500, waitingTimeoutMs: 5000);
      final s = Script.parse('lost 0.7, standing 6');
      expect(s.run(m), [
        TrackingLost(600),
        TrackingRestored(700),
        SessionEnded(s.after(5000), reason: EndReason.timeout),
      ]);
    });

    test('invalid thresholds throw', () {
      expect(() => FajrStateMachine(qiyam2HoldMs: 0), throwsArgumentError);
      expect(() => FajrStateMachine(leaveHipRatio: -1), throwsArgumentError);
      expect(() => FajrStateMachine(stateTimeoutMs: -5), throwsArgumentError);
    });

    test('rakahOf', () {
      expect(PrayerState.values.map(FajrStateMachine.rakahOf).toList(),
          [0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2]);
    });
  });

  group('property', () {
    test(
        'random sequences never start a recitation without 0.8 s of '
        'standing after takbir or after a rak\'ah-1 prostration', () {
      final rng = Random(1234);
      var starts = 0;
      for (var trial = 0; trial < 400; trial++) {
        final s = Script();
        final segs = 10 + rng.nextInt(40);
        for (var k = 0; k < segs; k++) {
          final roll = rng.nextInt(12);
          final secs = 0.1 + rng.nextDouble() * (rng.nextBool() ? 1.2 : 4);
          if (roll == 0) {
            s.takbir();
          } else if (roll == 1) {
            s.lost(secs);
          } else {
            final p = [st, st, st, bo, pr, si, un][rng.nextInt(7)];
            final rawMode = rng.nextInt(4);
            s.hold(p, secs,
                raw: rawMode != 0,
                torso: rawMode == 3 ? rng.nextDouble() * 90 : null,
                hip: rawMode == 3 ? rng.nextDouble() * 1.1 : null);
          }
        }
        starts += checkInvariants(s.readings, s.run(), 'trial $trial');
      }
      expect(starts, greaterThan(20),
          reason: 'the generator must exercise starts');
    });

    test(
        'real prayers with random per-frame posture noise: at most one start '
        'per rak\'ah, never without 0.8 s of standing', () {
      final rng = Random(42);
      final variants = [
        const Variant(),
        const Variant(shafiiQunut: true, rukuRaise: true),
        const Variant(malikiQunut: true, briefSitting: true),
        const Variant(takbir: false, jalsa: 0.3),
        const Variant(missedRuku1: true, sahw: 'after'),
      ];
      var starts = 0;
      for (var trial = 0; trial < 200; trial++) {
        final clean = prayer(variants[trial % variants.length]);
        final noise = 0.02 + rng.nextDouble() * 0.2;
        final noisy = [
          for (final r in clean.readings)
            if (rng.nextDouble() >= noise)
              r
            else if (rng.nextInt(5) == 0)
              PostureReading.unknown(r.tMs)
            else
              PostureReading(
                tMs: r.tMs,
                posture: Posture.values[rng.nextInt(5)],
                confidence: rng.nextDouble(),
                takbirRaise: rng.nextInt(20) == 0,
                torsoAngleDeg: rng.nextBool() ? rng.nextDouble() * 100 : null,
                hipHeightRatio: rng.nextBool() ? rng.nextDouble() * 1.1 : null,
              ),
        ];
        final m = FajrStateMachine();
        final events = [for (final r in noisy) ...m.add(r)];
        starts += checkInvariants(noisy, events, 'trial $trial');
      }
      expect(starts, greaterThan(100));
    });
  });
}

/// Checks the audio invariants on one replay and returns the number of
/// starts: each rak'ah starts at most once, every stop follows a start (and
/// ends it: no resume after it), every pause follows a start or resume
/// while playing, every resume follows a pause of the same rak'ah and
/// happens in that rak'ah's Qiyam, and each start was preceded by 0.8 s of
/// smoothed standing within the standing raw limits, with no lost-tracking
/// gap, after a takbir (rak'ah 1) or a prostration (rak'ah 2).
int checkInvariants(
    List<PostureReading> rs, List<PrayerEvent> events, String label) {
  final started = <int>{};
  var audio = 'none'; // none, playing, paused
  var rakah = 0;
  var state = w;
  var starts = 0;
  for (final e in events) {
    if (e is StateChanged) state = e.to;
    if (e is StopRecitation) {
      expect(audio, isNot('none'), reason: '$label: stop without start');
      audio = 'none';
    }
    if (e is PauseRecitation) {
      expect(audio, 'playing', reason: '$label: pause while not playing');
      expect(e.rakah, rakah, reason: label);
      audio = 'paused';
    }
    if (e is ResumeRecitation) {
      expect(audio, 'paused', reason: '$label: resume without pause');
      expect(e.rakah, rakah, reason: label);
      expect(state, e.rakah == 1 ? q1 : q2,
          reason: '$label: resume outside qiyam at ${e.tMs}');
      audio = 'playing';
    }
    if (e is! StartRecitation) continue;
    starts++;
    expect(started.add(e.rakah), isTrue, reason: '$label: repeated start');
    expect(audio, 'none', reason: label);
    audio = 'playing';
    rakah = e.rakah;
    final from = e.tMs - 800;
    final window = rs.where((r) => r.tMs >= from && r.tMs <= e.tMs);
    expect(rs.first.tMs, lessThanOrEqualTo(from), reason: label);
    for (final r in window) {
      expect(r.posture, st, reason: '$label at ${r.tMs}');
      expect((r.torsoAngleDeg ?? 0) <= 35, isTrue, reason: label);
      expect((r.hipHeightRatio ?? 1) >= 0.8, isTrue, reason: label);
    }
    final before = rs.lastWhere((r) => r.tMs < from, orElse: () => rs.first);
    expect(window.first.tMs - before.tMs, lessThanOrEqualTo(2000),
        reason: label);
    if (e.rakah == 1) {
      final tk = rs.indexWhere((r) => r.takbirRaise);
      expect(tk, isNot(-1), reason: label);
      expect(rs[tk].tMs, lessThanOrEqualTo(from), reason: label);
    } else {
      expect(rs.any((r) => r.posture == pr && r.tMs < from), isTrue,
          reason: label);
    }
  }
  return starts;
}
