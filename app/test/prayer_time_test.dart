import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/prayer_time.dart';
import 'package:salah_core/salah_core.dart';

DateTime at(int h, int m) => DateTime(2026, 10, 20, h, m);

void main() {
  group('guessPrayer', () {
    test('window edges', () {
      final cases = <(int, int, Prayer)>[
        (0, 0, Prayer.isha),
        (2, 59, Prayer.isha),
        (3, 0, Prayer.fajr),
        (3, 29, Prayer.fajr),
        (6, 59, Prayer.fajr),
        (8, 0, Prayer.fajr),
        (9, 59, Prayer.fajr),
        (10, 0, Prayer.dhuhr),
        (12, 0, Prayer.dhuhr),
        (15, 29, Prayer.dhuhr),
        (15, 30, Prayer.asr),
        (17, 59, Prayer.asr),
        (18, 0, Prayer.maghrib),
        (19, 29, Prayer.maghrib),
        (19, 30, Prayer.isha),
        (23, 59, Prayer.isha),
      ];
      for (final (h, m, p) in cases) {
        expect(guessPrayer(at(h, m)), p, reason: '$h:$m');
      }
    });

    test('seconds do not matter', () {
      expect(guessPrayer(DateTime(2026, 1, 1, 9, 59, 59, 999)), Prayer.fajr);
      expect(guessPrayer(DateTime(2026, 1, 1, 2, 59, 59)), Prayer.isha);
    });

    test('every minute of the day maps to a prayer, in order', () {
      final seen = <Prayer>[];
      for (var m = 0; m < 24 * 60; m++) {
        final p = guessPrayer(at(m ~/ 60, m % 60));
        if (seen.isEmpty || seen.last != p) seen.add(p);
      }
      expect(seen, [
        Prayer.isha,
        Prayer.fajr,
        Prayer.dhuhr,
        Prayer.asr,
        Prayer.maghrib,
        Prayer.isha,
      ]);
    });
  });

  group('PrayerSelection', () {
    test('without a pick it follows the clock', () {
      const s = PrayerSelection();
      expect(s.resolve(at(5, 0)), Prayer.fajr);
      expect(s.resolve(at(16, 0)), Prayer.asr);
    });

    test('a pick lasts until the clock enters a different window', () {
      final s = PrayerSelection.pick(Prayer.isha, at(11, 0)); // Dhuhr window
      expect(s.resolve(at(11, 0)), Prayer.isha);
      expect(s.resolve(at(15, 29)), Prayer.isha);
      expect(s.resolve(at(15, 30)), Prayer.asr);
      // The next day's Dhuhr window is a different window.
      expect(s.resolve(DateTime(2026, 10, 21, 11, 0)), Prayer.dhuhr);
    });

    test('a pick in the Isha window survives midnight', () {
      final s = PrayerSelection.pick(Prayer.maghrib, at(23, 0));
      expect(s.resolve(at(1, 0)), Prayer.isha); // the night before
      expect(s.resolve(DateTime(2026, 10, 21, 1, 0)), Prayer.maghrib);
      expect(s.resolve(DateTime(2026, 10, 21, 2, 59)), Prayer.maghrib);
      expect(s.resolve(DateTime(2026, 10, 21, 3, 0)), Prayer.fajr);
      expect(s.resolve(DateTime(2026, 10, 21, 23, 0)), Prayer.isha);
    });
  });

  group('prayerWindowStart', () {
    test('starts of each window, Isha across midnight and months', () {
      expect(prayerWindowStart(at(5, 0)), at(3, 0));
      expect(prayerWindowStart(at(9, 59)), at(3, 0));
      expect(prayerWindowStart(at(10, 0)), at(10, 0));
      expect(prayerWindowStart(at(15, 29)), at(10, 0));
      expect(prayerWindowStart(at(17, 0)), at(15, 30));
      expect(prayerWindowStart(at(19, 0)), at(18, 0));
      expect(prayerWindowStart(at(19, 30)), at(19, 30));
      expect(prayerWindowStart(at(2, 59)), DateTime(2026, 10, 19, 19, 30));
      expect(prayerWindowStart(at(3, 0)), at(3, 0));
      expect(
        prayerWindowStart(DateTime(2026, 11, 1, 2, 0)),
        DateTime(2026, 10, 31, 19, 30),
      );
    });
  });
}
