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

  List<PrayerEvent> run([SalahStateMachine? m]) {
    final sm = m ?? SalahStateMachine();
    return [for (final r in readings) ...sm.add(r)];
  }
}

StateChanged sc(int t, PrayerState from, PrayerState to, int rakah) =>
    StateChanged(t, from: from, to: to, rakah: rakah);

const w = PrayerState.waiting;
const tk = PrayerState.takbir;
const q = PrayerState.qiyam;
const r = PrayerState.ruku;
const i = PrayerState.itidal;
const sj = PrayerState.sujood;
const ms = PrayerState.middleSitting;
const fs = PrayerState.finalSitting;
const dn = PrayerState.done;

// The states are rak'ah independent (the rak'ah is on StateChanged); these
// aliases keep the Fajr tests readable.
const q1 = q, q2 = q, r1 = r, r2 = r, i1 = i, i2 = i, s1 = sj, s2 = sj;

// ---------------------------------------------------------------------------
// A parametrised prayer (any of the five) and its expected events.
// ---------------------------------------------------------------------------

class Variant {
  final Prayer prayer;
  final double preStand;
  final bool takbir;
  final bool rukuRaise;
  final bool shafiiQunut;
  final bool malikiQunut;
  final bool briefSitting;
  final double jalsa;
  final bool missedRuku1;
  final bool missedRuku2;

  /// A missed ruku in this later rak'ah (3 or 4), 0 for none.
  final int missedRukuLater;

  /// Length of the middle sitting (3- and 4-rak'ah prayers).
  final double middleSit;

  /// A hand raise on standing up from the middle sitting.
  final bool riseRaise;
  final double finalSit;
  final String sahw; // '', 'before', 'after'

  const Variant({
    this.prayer = Prayer.fajr,
    this.preStand = 3,
    this.takbir = true,
    this.rukuRaise = false,
    this.shafiiQunut = false,
    this.malikiQunut = false,
    this.briefSitting = false,
    this.jalsa = 1,
    this.missedRuku1 = false,
    this.missedRuku2 = false,
    this.missedRukuLater = 0,
    this.middleSit = 8,
    this.riseRaise = false,
    this.finalSit = 8,
    this.sahw = '',
  });

  bool missedRuku(int k) => switch (k) {
        1 => missedRuku1,
        2 => missedRuku2,
        _ => k == missedRukuLater,
      };

  /// Whether the machine can confirm the middle sitting (3 s hold).
  bool get middleConfirmed => middleSit >= 3.1;

  @override
  String toString() => '${prayer.name} variant';
}

Script prayer(Variant v) {
  final n = v.prayer.rakahCount;
  final s = Script()..hold(st, v.preStand, mark: 'pre');
  if (v.takbir) s.takbir(mark: 'takbir');
  for (var k = 1; k <= n; k++) {
    if (k == 3 && v.riseRaise) {
      // Standing up from the middle sitting, raising the hands once up.
      s
        ..hold(st, 0.4, mark: 'q$k')
        ..takbir()
        ..hold(st, 4.5);
    } else {
      s.hold(st, 5, mark: 'q$k');
    }
    if (k == 2 && v.malikiQunut) {
      s.then('raise, standing 1, raise, standing 2');
    }
    if (v.rukuRaise) s.takbir();
    if (v.missedRuku(k)) {
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
    s.hold(si, v.jalsa, mark: 'j$k');
    s.hold(pr, 2);
    if (k.isOdd && k < n && v.briefSitting) s.hold(si, 2);
    if (k == 2 && n > 2) s.hold(si, v.middleSit, mark: 'm');
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
  final n = v.prayer.rakahCount;
  final e = <PrayerEvent>[];
  var state = w;
  void go(int t, PrayerState to, int rakah) {
    e.add(sc(t, state, to, rakah));
    state = to;
  }

  void qiyam(int k, {bool audio = true}) {
    final t = k == 1 ? s.t('takbir', 800) : s.t('q$k', 800);
    go(t, q, k);
    if (audio) {
      e.add(StartRecitation(t, rakah: k));
      e.add(StopRecitation(s.t('r$k', 200)));
    }
  }

  if (v.takbir) {
    go(s.t('takbir'), tk, 0);
    qiyam(1);
  }
  for (var k = 1; k <= n; k++) {
    if (!v.missedRuku(k)) {
      go(s.t('r$k', 500), r, k);
      go(s.t('i$k'), i, k);
    } else {
      // Filled in at the moment the prostration is confirmed.
      go(s.t('s$k', 500), r, k);
      go(s.t('s$k', 500), i, k);
    }
    go(s.t('s$k', 500), sj, k);
    if (k == 2 && n > 2) {
      // A jalsa of 3 s or more already counts as the middle sitting.
      if (v.jalsa >= 3.1) {
        go(s.t('j2', 3000), ms, 2);
      } else if (v.middleConfirmed) {
        go(s.t('m', 3000), ms, 2);
      }
      // Unconfirmed middle sitting: rak'ah 3 counted, but silent.
      qiyam(3, audio: v.middleConfirmed || v.jalsa >= 3.1);
    } else if (k < n) {
      qiyam(k + 1);
    }
  }
  go(s.t('fs', 5000), fs, n);
  go(s.t('up', 800), dn, n);
  e.add(SessionEnded(s.t('up', 800), reason: EndReason.completed));
  return e;
}

/// [v]'s script run through a machine for its prayer.
List<PrayerEvent> runVariant(Script s, Variant v) =>
    s.run(SalahStateMachine(prayer: v.prayer));

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
      expect(
          events
              .whereType<StateChanged>()
              .where((e) => e.to == q2 && e.rakah == 2),
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
      expect(
          events
              .whereType<StateChanged>()
              .where((e) => e.to == r2 && e.rakah == 2),
          isEmpty);
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
      final m = SalahStateMachine();
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

    test(
        'last body data tilting past 12 degrees: the pause comes after 0.3 s '
        '(a bow may be starting unseen)', () {
      final s = reciting()
        ..hold(st, 0.2, torso: 15)
        ..lost(0.5, mark: 'blind')
        ..hold(st, 2, mark: 'back');
      final lastSeen = s.before(s.marks['blind']!);
      expect(audio(s.run()), [
        StartRecitation(s.t('takbir', 800), rakah: 1),
        PauseRecitation(s.after(lastSeen + 300), rakah: 1),
        ResumeRecitation(s.t('back', 200), rakah: 1),
      ]);
      // Upright (5 degrees) before the same blind spot: nothing.
      final u = reciting()
        ..hold(st, 0.2, torso: 5)
        ..lost(0.5)
        ..hold(st, 2);
      expect(audio(u.run()), [StartRecitation(u.t('takbir', 800), rakah: 1)]);
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
        final m = SalahStateMachine();
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
          s.run(SalahStateMachine(stateTimeoutMs: resumeAt - qiyamAt - 1));
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

  group('all five prayers', () {
    test('Prayer: rak\'ah counts, middle sitting and surah rak\'ahs', () {
      expect({
        for (final p in Prayer.values) p: p.rakahCount
      }, {
        Prayer.fajr: 2,
        Prayer.dhuhr: 4,
        Prayer.asr: 4,
        Prayer.maghrib: 3,
        Prayer.isha: 4,
      });
      expect(Prayer.values.where((p) => p.hasMiddleSitting),
          [Prayer.dhuhr, Prayer.asr, Prayer.maghrib, Prayer.isha]);
      expect([for (var k = 0; k <= 5; k++) Prayer.isha.hasSurah(k)],
          [false, true, true, false, false, false]);
      expect([for (var k = 1; k <= 4; k++) Prayer.maghrib.hasSurah(k)],
          [true, true, false, false]);
      expect([for (var k = 1; k <= 3; k++) Prayer.fajr.hasSurah(k)],
          [true, true, false]);
    });

    for (final p in Prayer.values) {
      final n = p.rakahCount;
      test('${p.name}: every transition, one start per rak\'ah, summary', () {
        final v = Variant(prayer: p);
        final s = prayer(v);
        final events = runVariant(s, v);
        expect(events, expected(s, v));
        final changes = events.whereType<StateChanged>().toList();
        expect(changes.map((e) => e.to).toList(), [
          tk,
          for (var k = 1; k <= n; k++) ...[
            q,
            r,
            i,
            sj,
            if (k == 2 && n > 2) ms,
          ],
          fs,
          dn,
        ]);
        expect(changes.map((e) => e.rakah).toList(), [
          0,
          for (var k = 1; k <= n; k++) ...[
            k,
            k,
            k,
            k,
            if (k == 2 && n > 2) 2,
          ],
          n,
          n,
        ]);
        expect(events.whereType<StartRecitation>().map((e) => e.rakah),
            [for (var k = 1; k <= n; k++) k]);
      });
    }

    for (final p in [Prayer.maghrib, Prayer.dhuhr, Prayer.asr, Prayer.isha]) {
      final n = p.rakahCount;
      final cases = <String, Variant>{
        'iqamah wait': Variant(prayer: p, preStand: 30),
        'raised hands at ruku and i\'tidal':
            Variant(prayer: p, rukuRaise: true),
        'hand raise when standing up from the middle sitting is no takbir':
            Variant(prayer: p, riseRaise: true),
        'brief sitting before standing (rak\'ah 2 and 4)':
            Variant(prayer: p, briefSitting: true),
        'hurried jalsa': Variant(prayer: p, jalsa: 0.3),
        'long jalsa (3.5 s) everywhere: rak\'ah 2\'s already enters the '
            'middle sitting, harmlessly': Variant(prayer: p, jalsa: 3.5),
        'short middle tashahhud (3.5 s) still confirmed':
            Variant(prayer: p, middleSit: 3.5),
        'long middle tashahhud (170 s)': Variant(prayer: p, middleSit: 170),
        'long final tashahhud (170 s)': Variant(prayer: p, finalSit: 170),
        'missed ruku in rak\'ah 2': Variant(prayer: p, missedRuku2: true),
        'missed ruku in rak\'ah $n': Variant(prayer: p, missedRukuLater: n),
        'missed ruku in rak\'ah 3': Variant(prayer: p, missedRukuLater: 3),
        'sujood al-sahw before salam': Variant(prayer: p, sahw: 'before'),
        'sujood al-sahw after salam': Variant(prayer: p, sahw: 'after'),
        'middle sitting too short to confirm (2.5 s): rak\'ah 3 silent':
            Variant(prayer: p, middleSit: 2.5),
        'no middle sitting seen at all: rak\'ah 3 silent':
            Variant(prayer: p, middleSit: 0),
      };
      cases.forEach((name, v) {
        test('${p.name}: $name', () {
          final s = prayer(v);
          expect(runVariant(s, v), expected(s, v));
        });
      });

      test('${p.name}: missed takbir: rak\'ah 1 silent, the rest recite', () {
        final v = Variant(prayer: p, takbir: false, preStand: 10);
        final s = prayer(v);
        final events = runVariant(s, v);
        expect(events, expected(s, v));
        expect(events.first, sc(s.t('r1', 500), w, r, 1));
        expect(events.whereType<StartRecitation>().map((e) => e.rakah),
            [for (var k = 2; k <= n; k++) k]);
      });

      test(
          '${p.name}: a long jalsa in rak\'ah 2 enters the middle sitting; '
          'the second prostration is ignored', () {
        final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
            'standing 1, prostrating 1, sitting 0.5, prostrating 1, '
            'standing 2, bowing 1, standing 1, prostrating 1, '
            'sitting 3.5 @jalsa, prostrating 1, sitting 6, standing 2 @q3');
        final events = s.run(SalahStateMachine(prayer: p));
        expect(events.sublist(events.length - 3), [
          sc(s.t('jalsa', 3000), sj, ms, 2),
          sc(s.t('q3', 800), ms, q, 3),
          StartRecitation(s.t('q3', 800), rakah: 3),
        ]);
      });

      test(
          '${p.name}: sitting after rak\'ah 2 is the middle, never the final '
          'sitting; getting up is qiyam 3', () {
        final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
            'standing 1, prostrating 1, sitting 0.5, prostrating 1, '
            'standing 2, bowing 1, standing 1, prostrating 1, sitting 0.5, '
            'prostrating 1, sitting 60 @m, standing 2 @q3');
        final events = s.run(SalahStateMachine(prayer: p));
        expect(events.whereType<StateChanged>().map((e) => e.to),
            isNot(contains(fs)));
        expect(events.sublist(events.length - 3), [
          sc(s.t('m', 3000), sj, ms, 2),
          sc(s.t('q3', 800), ms, q, 3),
          StartRecitation(s.t('q3', 800), rakah: 3),
        ]);
      });

      test(
          '${p.name}: bowing straight from the middle sitting enters ruku 3 '
          'without audio', () {
        final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
            'standing 1, prostrating 1, sitting 0.5, prostrating 1, '
            'standing 2, bowing 1, standing 1, prostrating 1, sitting 0.5, '
            'prostrating 1, sitting 5, standing 0.5, bowing 1 @r');
        final events = s.run(SalahStateMachine(prayer: p));
        expect(events.last, sc(s.t('r', 500), ms, r, 3));
        expect(events.whereType<StartRecitation>().map((e) => e.rakah), [1, 2]);
      });

      test(
          '${p.name}: standing in the last sujood (an extra rak\'ah) plays '
          'nothing', () {
        final v = Variant(prayer: p, finalSit: 0);
        final s = prayer(v)
          ..then('standing 20, bowing 1, standing 1, prostrating 1');
        final events = runVariant(s, v);
        expect(events.whereType<StartRecitation>().map((e) => e.rakah),
            [for (var k = 1; k <= n; k++) k]);
        expect(events.whereType<StateChanged>().last.to, sj);
        expect(events.whereType<StateChanged>().last.rakah, n);
      });
    }

    group('count in doubt: silence', () {
      const toSujood1 = 'standing 1, takbir, standing 2, bowing 1, '
          'standing 1, prostrating 1, sitting 0.5, prostrating 1';

      test(
          'an 8 s sitting after rak\'ah 1 (a tashahhud where none belongs): '
          'no further recitation, counting goes on', () {
        for (final p in Prayer.values) {
          final s = Script.parse('$toSujood1, sitting 8.5, standing 3 @q2, '
              'bowing 1 @r2');
          final m = SalahStateMachine(prayer: p);
          final events = s.run(m);
          expect(m.countUncertain, isTrue, reason: p.name);
          expect(events.whereType<StartRecitation>().map((e) => e.rakah), [1],
              reason: p.name);
          expect(events.sublist(events.length - 2),
              [sc(s.t('q2', 800), sj, q, 2), sc(s.t('r2', 500), q, r, 2)],
              reason: p.name);
        }
        // 7.5 s is still a (long) jalsa or brief sitting.
        final s = Script.parse('$toSujood1, sitting 7.5, standing 3 @q2');
        final m = SalahStateMachine(prayer: Prayer.isha);
        expect(s.run(m).last, StartRecitation(s.t('q2', 800), rakah: 2));
        expect(m.countUncertain, isFalse);
      });

      test('an 8 s sitting after rak\'ah 3 of a 4-rak\'ah prayer', () {
        const v = Variant(prayer: Prayer.dhuhr, finalSit: 0);
        final s = prayer(v);
        // Cut after rak'ah 3's prostrations: insert a long sitting, stand.
        final cut = s.readings.indexWhere((r) => r.tMs >= s.marks['q4']!);
        s.readings.removeRange(cut, s.readings.length);
        s
          ..hold(si, 9)
          ..hold(st, 3, mark: 'up4');
        final m = SalahStateMachine(prayer: Prayer.dhuhr);
        final events = s.run(m);
        expect(m.countUncertain, isTrue);
        expect(
            events.whereType<StartRecitation>().map((e) => e.rakah), [1, 2, 3]);
        expect(events.last, sc(s.t('up4', 800), sj, q, 4));
      });

      test('a second ruku in i\'tidal (prostrations unseen): silence', () {
        final s = Script.parse('standing 1, takbir, standing 2, bowing 1, '
            'standing 1 @i, lost 1.5, standing 3, bowing 2 @r, standing 1, '
            'prostrating 1 @p, sitting 0.5, prostrating 1, standing 2 @q');
        final m = SalahStateMachine(prayer: Prayer.isha);
        final events = s.run(m);
        expect(m.countUncertain, isTrue);
        expect(events.whereType<StartRecitation>().map((e) => e.rakah), [1]);
        // The machine is now a rak'ah behind (it cannot know better), but
        // silent.
        expect(
            events.whereType<StateChanged>().last, sc(s.t('q', 800), sj, q, 2));
      });

      test('tracking back after more than 8 s mid-prayer: silence', () {
        for (final (secs, uncertain) in [(6.0, false), (9.0, true)]) {
          final s = Script.parse('$toSujood1, standing 3 @q2, bowing 1, '
              'standing 1, prostrating 1, lost $secs, sitting 0.5, '
              'prostrating 1, standing 3 @q3');
          final m = SalahStateMachine(prayer: Prayer.isha);
          final events = s.run(m);
          expect(m.countUncertain, uncertain, reason: '$secs s');
          // Rak'ah 3 after an unconfirmed middle sitting is silent anyway;
          // check rak'ah 2 was fine and nothing else started.
          expect(
              events.whereType<StartRecitation>().map((e) => e.rakah), [1, 2],
              reason: '$secs s');
        }
        // Fajr: lost 9 s in sujood 1, back standing: no rak'ah 2 audio.
        final s = Script.parse('$toSujood1, lost 9, standing 3 @q2');
        final m = SalahStateMachine();
        final events = s.run(m);
        expect(m.countUncertain, isTrue);
        expect(events.last, sc(s.t('q2', 800), sj, q, 2));
        // 7 s lost (a short absence): rak'ah 2 recites.
        final s2 = Script.parse('$toSujood1, lost 7, standing 3 @q2');
        expect(s2.run().last, StartRecitation(s2.t('q2', 800), rakah: 2));
      });

      test(
          'takbir guard: standing up from a sitting with a hand raise is not '
          'the opening takbir', () {
        // A session started mid-prayer, during a middle tashahhud.
        final s = Script.parse('sitting 6, standing 1.5, takbir, '
            'standing 6, bowing 1 @r');
        final events = s.run(SalahStateMachine(prayer: Prayer.dhuhr));
        expect(events, [sc(s.t('r', 500), w, r, 1)]);
        // More than 5 s after the sitting: a takbir as usual.
        final s2 = Script.parse('sitting 6, standing 5.2, takbir, standing 2');
        expect(s2.run(SalahStateMachine(prayer: Prayer.dhuhr)),
            contains(sc(s2.t('takbir'), w, tk, 0)));
      });

      // One unknown frame every [every] s while sitting [secs] s in all.
      void jitterySit(Script s, double secs, double every, {String? mark}) {
        if (mark != null) s.marks[mark] = s.now;
        var left = secs;
        while (left > 0) {
          final chunk = left < every ? left : every;
          s.hold(si, chunk);
          left -= chunk;
          if (left > 0) {
            s.hold(un, 1 / 15, raw: false);
            left -= 1 / 15;
          }
        }
      }

      const rakah = 'standing 6, bowing 2, standing 1.5, prostrating 2, '
          'sitting 1.5, prostrating 2';

      test(
          'late start in the user\'s rak\'ah-2 sujood, tashahhuds with a '
          'dropout frame every 2 s: never a recitation (reviewer case)', () {
        final s = Script.parse('standing 3, prostrating 2, sitting 1, '
            'prostrating 2');
        jitterySit(s, 12, 2);
        s.then('$rakah, $rakah');
        jitterySit(s, 25, 2);
        s.hold(st, 4, mark: 'up');
        final m = SalahStateMachine(prayer: Prayer.dhuhr);
        final events = s.run(m);
        expect(events.whereType<StartRecitation>(), isEmpty);
        expect(m.countUncertain, isTrue);
      });

      test(
          'a long sitting where none belongs tolerates dropout frames, as '
          'the middle and final sitting holds do', () {
        final s = Script.parse(toSujood1);
        jitterySit(s, 10, 2);
        s.hold(st, 3, mark: 'q2');
        final m = SalahStateMachine(prayer: Prayer.dhuhr);
        final events = s.run(m);
        expect(m.countUncertain, isTrue);
        expect(events.whereType<StartRecitation>().map((e) => e.rakah), [1]);
        expect(events.last, sc(s.t('q2', 800), sj, q, 2));
      });

      test(
          'a 6 s jalsa in rak\'ah 1 of Dhuhr is no tashahhud: all four '
          'rak\'ahs recite', () {
        final s = Script.parse('standing 1, takbir, standing 2, bowing 2, '
            'standing 1.5, prostrating 2, sitting 6, prostrating 2, '
            '$rakah, sitting 10, $rakah, $rakah, sitting 8, standing 2');
        final m = SalahStateMachine(prayer: Prayer.dhuhr);
        final events = s.run(m);
        expect(m.countUncertain, isFalse);
        expect(events.whereType<StartRecitation>().map((e) => e.rakah),
            [1, 2, 3, 4]);
        expect(events.last, isA<SessionEnded>());
      });

      group('untrusted entry from waiting (N > 2)', () {
        test(
            'a prostration in waiting (late start) silences the prayer even '
            'with a short middle sitting', () {
          for (final p in [Prayer.dhuhr, Prayer.maghrib]) {
            // The user's rak'ah-2 sujood, a 5 s middle tashahhud, the rest.
            final s = Script.parse('prostrating 2 @p, sitting 1, '
                'prostrating 2, sitting 5, $rakah, '
                '${p == Prayer.dhuhr ? '$rakah, ' : ''}'
                'sitting 20, standing 3');
            final m = SalahStateMachine(prayer: p);
            final events = s.run(m);
            expect(events.whereType<StartRecitation>(), isEmpty,
                reason: p.name);
            expect(m.countUncertain, isTrue, reason: p.name);
            expect(events.whereType<StateChanged>().first,
                sc(s.t('p', 500), w, r, 1),
                reason: p.name);
          }
        });

        test('a bow in waiting after a sitting silences the prayer', () {
          // Started during the middle tashahhud: up for rak'ah 3, no raise.
          final s = Script.parse('sitting 6, standing 20, bowing 2, '
              'standing 1.5, prostrating 2, sitting 1, prostrating 2, '
              'standing 3');
          final m = SalahStateMachine(prayer: Prayer.dhuhr);
          expect(s.run(m).whereType<StartRecitation>(), isEmpty);
          expect(m.countUncertain, isTrue);
        });

        test('first seen standing (missed takbir): counting is trusted', () {
          final s = Script.parse('standing 10, bowing 2, standing 1.5, '
              'prostrating 2, sitting 1, prostrating 2, standing 3 @q2');
          final m = SalahStateMachine(prayer: Prayer.dhuhr);
          expect(s.run(m).last, StartRecitation(s.t('q2', 800), rakah: 2));
          expect(m.countUncertain, isFalse);
        });

        test('Fajr keeps its prostration-from-waiting rule', () {
          final s = Script.parse('prostrating 2, sitting 1, prostrating 2, '
              'standing 3 @q2');
          final m = SalahStateMachine();
          expect(s.run(m).last, StartRecitation(s.t('q2', 800), rakah: 2));
          expect(m.countUncertain, isFalse);
        });
      });

      group('second ruku needs a whole ruku cycle', () {
        test(
            'hands-first descent (a bow of up to 1 s with the hips high on '
            'the way down) in every rak\'ah: all rak\'ahs recite', () {
          for (final secs in [0.4, 0.7, 1.0]) {
            final desc = 'standing 6, bowing 2, standing 1.5, '
                'bowing $secs, prostrating 2, sitting 1.5, prostrating 2';
            final s = Script.parse('standing 1, takbir, $desc, $desc, '
                'sitting 10, $desc, $desc, sitting 8, standing 2');
            final m = SalahStateMachine(prayer: Prayer.dhuhr);
            final events = s.run(m);
            expect(m.countUncertain, isFalse, reason: '$secs s');
            expect(events.whereType<StartRecitation>().map((e) => e.rakah),
                [1, 2, 3, 4],
                reason: '$secs s');
          }
          // The same in Fajr, with the hips at 0.85.
          final s = Script.parse('standing 1, takbir, standing 6, bowing 2, '
              'standing 1.5')
            ..hold(bo, 0.7, torso: 70, hip: 0.85)
            ..then('prostrating 2, sitting 1.5, prostrating 2, '
                'standing 3 @q2');
          final m = SalahStateMachine();
          expect(s.run(m).last, StartRecitation(s.t('q2', 800), rakah: 2));
          expect(m.countUncertain, isFalse);
        });

        test('a standing flicker in ruku, then more bowing: no doubt', () {
          final s = Script.parse('standing 1, takbir, standing 6, bowing 1, '
              'standing 0.07, bowing 1.5, standing 1.5, prostrating 2, '
              'sitting 1.5, prostrating 2, standing 3 @q2');
          final m = SalahStateMachine(prayer: Prayer.isha);
          expect(s.run(m).last, StartRecitation(s.t('q2', 800), rakah: 2));
          expect(m.countUncertain, isFalse);
        });

        test(
            'a bow under 1.2 s, or one not followed by standing, is no '
            'second ruku', () {
          for (final tail in [
            'bowing 1, standing 2, prostrating 1',
            'bowing 3, prostrating 1',
            'bowing 2, unknown 1, prostrating 1',
          ]) {
            final s = Script.parse('standing 1, takbir, standing 6, '
                'bowing 2, standing 1.5, $tail, sitting 1, prostrating 2, '
                'standing 3 @q2');
            final m = SalahStateMachine(prayer: Prayer.isha);
            expect(s.run(m).last, StartRecitation(s.t('q2', 800), rakah: 2),
                reason: tail);
            expect(m.countUncertain, isFalse, reason: tail);
          }
        });

        test('stand, bow 1.2 s, stand again in i\'tidal: count in doubt', () {
          final s = Script.parse('standing 1, takbir, standing 6, bowing 2, '
              'standing 1.5, bowing 1.3, standing 0.6');
          final m = SalahStateMachine(prayer: Prayer.isha);
          s.run(m);
          expect(m.countUncertain, isTrue);
          // A flicker of standing in ruku is no i'tidal to start the cycle.
          final s2 = Script.parse('standing 1, takbir, standing 6, '
              'bowing 1, standing 0.07, bowing 1.3, standing 0.6');
          final m2 = SalahStateMachine(prayer: Prayer.isha);
          s2.run(m2);
          expect(m2.countUncertain, isFalse);
        });
      });

      group('getting up from an unconfirmed final sitting', () {
        // Rak'ah N's prostrations, then a gappy tashahhud.
        Script gappy(Prayer p, {double sit = 11}) {
          final s = Script.parse('standing 1, takbir');
          for (var k = 1; k <= p.rakahCount; k++) {
            s.then(rakah);
            if (k == 2 && p.rakahCount > 2) s.hold(si, 8);
          }
          // 1.5 s sitting, 0.6 s unseen: the 5 s hold never confirms.
          var left = sit;
          while (left > 0) {
            s.hold(si, 1.5);
            s.hold(un, 0.6, raw: false);
            left -= 2.1;
          }
          s.hold(st, 3, mark: 'up');
          return s;
        }

        test('standing 0.8 s after 3 s or more of sitting: done', () {
          for (final p in Prayer.values) {
            final s = gappy(p);
            final m = SalahStateMachine(prayer: p);
            final events = s.run(m);
            // The final sitting never confirmed: filled in on getting up.
            expect(
                events.sublist(events.length - 3),
                [
                  sc(s.t('up', 800), sj, fs, p.rakahCount),
                  sc(s.t('up', 800), fs, dn, p.rakahCount),
                  SessionEnded(s.t('up', 800), reason: EndReason.completed),
                ],
                reason: p.name);
            expect(events.whereType<StartRecitation>().map((e) => e.rakah),
                [for (var k = 1; k <= p.rakahCount; k++) k],
                reason: p.name);
          }
        });

        test('a brief sitting (under 3 s) then standing: still sujood', () {
          final s = gappy(Prayer.dhuhr, sit: 1.5);
          final m = SalahStateMachine(prayer: Prayer.dhuhr);
          final events = s.run(m);
          expect(m.ended, isFalse);
          expect(events.whereType<StateChanged>().last.to, sj);
        });
      });
    });
  });

  group('API', () {
    test('no events after SessionEnded until reset', () {
      final m = SalahStateMachine();
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
      final events = await SalahStateMachine()
          .run(Stream.fromIterable(s.readings))
          .toList();
      expect(events, s.run());
      expect(events.last, isA<SessionEnded>());
    });

    test('out-of-order timestamps are clamped', () {
      final m = SalahStateMachine();
      m.add(const PostureReading(tMs: 1000, posture: st, confidence: 0.9));
      final e = m.add(const PostureReading(
          tMs: 500, posture: st, confidence: 0.9, takbirRaise: true));
      expect(e, [sc(1000, w, tk, 0)]);
    });

    test('thresholds are constructor parameters', () {
      final m = SalahStateMachine(
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
      final m = SalahStateMachine(trackingLostMs: 500, waitingTimeoutMs: 5000);
      final s = Script.parse('lost 0.7, standing 6');
      expect(s.run(m), [
        TrackingLost(600),
        TrackingRestored(700),
        SessionEnded(s.after(5000), reason: EndReason.timeout),
      ]);
    });

    test('invalid thresholds throw', () {
      expect(() => SalahStateMachine(qiyamHoldMs: 0), throwsArgumentError);
      expect(
          () => SalahStateMachine(middleSittingHoldMs: 0), throwsArgumentError);
      expect(() => SalahStateMachine(leaveHipRatio: -1), throwsArgumentError);
      expect(() => SalahStateMachine(stateTimeoutMs: -5), throwsArgumentError);
      expect(() => SalahStateMachine(secondRukuMs: 0), throwsArgumentError);
      expect(() => SalahStateMachine(itidalStandMs: 0), throwsArgumentError);
      expect(() => SalahStateMachine(finalStandAfterSitMs: 0),
          throwsArgumentError);
    });

    test('FajrStateMachine is the Fajr machine (compatibility alias)', () {
      final m = FajrStateMachine();
      expect(m, isA<SalahStateMachine>());
      expect(m.prayer, Prayer.fajr);
      expect(m.rakah, 0);
    });
  });

  group('property', () {
    test(
        'random sequences, every prayer: never a recitation without 0.8 s '
        'of standing after the takbir, a prostration or the middle sitting',
        () {
      final rng = Random(1234);
      var starts = 0;
      final perRakah = <int, int>{};
      for (var trial = 0; trial < 1000; trial++) {
        final p = Prayer.values[trial % Prayer.values.length];
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
            final posture = [st, st, st, bo, pr, si, si, un][rng.nextInt(8)];
            final rawMode = rng.nextInt(4);
            s.hold(
                posture, posture == si && rng.nextInt(3) == 0 ? secs * 2 : secs,
                raw: rawMode != 0,
                torso: rawMode == 3 ? rng.nextDouble() * 90 : null,
                hip: rawMode == 3 ? rng.nextDouble() * 1.1 : null);
          }
        }
        final events = s.run(SalahStateMachine(prayer: p));
        starts +=
            checkInvariants(s.readings, events, 'trial $trial', prayer: p);
        for (final e in events.whereType<StartRecitation>()) {
          perRakah[e.rakah] = (perRakah[e.rakah] ?? 0) + 1;
        }
      }
      expect(starts, greaterThan(50),
          reason: 'the generator must exercise starts');
      expect(perRakah.keys, containsAll([1, 2]),
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
        for (final p in [
          Prayer.dhuhr,
          Prayer.asr,
          Prayer.maghrib,
          Prayer.isha
        ]) ...[
          Variant(prayer: p),
          Variant(prayer: p, rukuRaise: true, riseRaise: true),
          Variant(prayer: p, briefSitting: true, middleSit: 4),
          Variant(prayer: p, takbir: false, jalsa: 0.3, middleSit: 20),
          Variant(prayer: p, missedRukuLater: 3, sahw: 'before'),
          Variant(prayer: p, middleSit: 2, jalsa: 2.5),
        ],
      ];
      var starts = 0;
      for (var trial = 0; trial < 600; trial++) {
        final v = variants[trial % variants.length];
        final clean = prayer(v);
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
        final m = SalahStateMachine(prayer: v.prayer);
        final events = [for (final r in noisy) ...m.add(r)];
        starts += checkInvariants(noisy, events, 'trial $trial ($v)',
            prayer: v.prayer);
      }
      expect(starts, greaterThan(800));
    });
  });
}

/// Checks the audio invariants on one replay and returns the number of
/// starts: each rak'ah starts at most once, every stop follows a start (and
/// ends it: no resume after it), every pause follows a start or resume
/// while playing, every resume follows a pause of the same rak'ah and
/// happens in that rak'ah's Qiyam, and each start was preceded by 0.8 s of
/// smoothed standing within the standing raw limits, with no lost-tracking
/// gap, after a takbir (rak'ah 1), a prostration (every later rak'ah) and,
/// for rak'ah 3 of a 3- or 4-rak'ah prayer, the middle sitting. Starts come
/// in increasing rak'ah order up to [prayer]'s count, each on entering that
/// rak'ah's qiyam, and rak'ah 1 only straight from takbir.
int checkInvariants(
    List<PostureReading> rs, List<PrayerEvent> events, String label,
    {Prayer prayer = Prayer.fajr}) {
  final started = <int>{};
  var audio = 'none'; // none, playing, paused
  var rakah = 0;
  var state = w;
  var stateRakah = 0;
  PrayerState? prevState;
  var middleSeen = false;
  var starts = 0;
  for (final e in events) {
    if (e is StateChanged) {
      prevState = e.from;
      state = e.to;
      stateRakah = e.rakah;
      if (e.to == ms) middleSeen = true;
    }
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
      expect((state, stateRakah), (q, e.rakah),
          reason: '$label: resume outside qiyam at ${e.tMs}');
      audio = 'playing';
    }
    if (e is! StartRecitation) continue;
    starts++;
    expect(started.every((k) => k < e.rakah), isTrue,
        reason: '$label: start out of order');
    expect(started.add(e.rakah), isTrue, reason: '$label: repeated start');
    expect(e.rakah, inInclusiveRange(1, prayer.rakahCount), reason: label);
    expect((state, stateRakah), (q, e.rakah),
        reason: '$label: start outside its qiyam');
    if (e.rakah == 1) expect(prevState, tk, reason: label);
    if (e.rakah == 3 && prayer.hasMiddleSitting) {
      expect(middleSeen, isTrue, reason: '$label: rak\'ah 3 before middle');
    }
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
