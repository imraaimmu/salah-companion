/// Which prayer Home offers by default, guessed from the phone's clock only
/// (no location, no prayer-time tables).
library;

import 'package:salah_core/salah_core.dart';

/// The prayer whose window contains [now] (local wall-clock time):
///
/// | Window        | Prayer  |
/// |---------------|---------|
/// | 03:00 - 09:59 | Fajr    |
/// | 10:00 - 15:29 | Dhuhr   |
/// | 15:30 - 17:59 | Asr     |
/// | 18:00 - 19:29 | Maghrib |
/// | 19:30 - 02:59 | Isha    |
///
/// Fajr's window is wide on purpose: offering a 4-rak'ah prayer to someone
/// praying Fajr is the harmful mistake (getting up after the salam of a
/// 2-rak'ah prayer would be taken for rak'ah 3), and Fajr starts before
/// 03:30 in summer and is prayed until about 08:00 in winter at high
/// latitudes. Offering Fajr to someone praying Dhuhr early only misses
/// recitations.
///
/// Only a default: the user can always pick another prayer on Home.
Prayer guessPrayer(DateTime now) => _window(now).$1;

/// When the window that contains [now] began (Isha's window began the
/// evening before when [now] is after midnight). Two times are in the same
/// window exactly when their starts are equal.
DateTime prayerWindowStart(DateTime now) {
  final (_, startMin, daysBack) = _window(now);
  return DateTime(
    now.year,
    now.month,
    now.day - daysBack,
    startMin ~/ 60,
    startMin % 60,
  );
}

/// Window starts in minutes after midnight, in order.
const List<(int, Prayer)> _starts = [
  (3 * 60, Prayer.fajr),
  (10 * 60, Prayer.dhuhr),
  (15 * 60 + 30, Prayer.asr),
  (18 * 60, Prayer.maghrib),
  (19 * 60 + 30, Prayer.isha),
];

(Prayer, int startMin, int daysBack) _window(DateTime now) {
  final m = now.hour * 60 + now.minute;
  for (var i = _starts.length - 1; i >= 0; i--) {
    final (start, prayer) = _starts[i];
    if (m >= start) return (prayer, start, 0);
  }
  // Before 03:00: still the Isha window of the evening before.
  final (start, prayer) = _starts.last;
  return (prayer, start, 1);
}

/// The prayer Home shows: a manual pick, kept until the clock enters a
/// different window, otherwise the clock's guess. Kept in memory only.
class PrayerSelection {
  /// The prayer the user tapped, or null.
  final Prayer? picked;

  /// Start of the window the pick was made in ([prayerWindowStart]).
  final DateTime? pickedInWindow;

  const PrayerSelection({this.picked, this.pickedInWindow});

  /// A manual pick of [prayer] at [now].
  factory PrayerSelection.pick(Prayer prayer, DateTime now) =>
      PrayerSelection(picked: prayer, pickedInWindow: prayerWindowStart(now));

  /// The prayer to offer at [now]: the pick while [now] is in the same
  /// window as the pick, otherwise the clock's guess.
  Prayer resolve(DateTime now) {
    final p = picked;
    if (p != null && pickedInWindow == prayerWindowStart(now)) return p;
    return guessPrayer(now);
  }
}
