/// Prayer states and events. See docs/SPEC.md, section "Prayer logic".
library;

/// The five fard (obligatory) daily prayers.
enum Prayer {
  fajr(2, 'Fajr'),
  dhuhr(4, 'Dhuhr'),
  asr(4, 'Asr'),
  maghrib(3, 'Maghrib'),
  isha(4, 'Isha');

  /// Number of rak'ahs: Fajr 2, Dhuhr 4, Asr 4, Maghrib 3, Isha 4.
  final int rakahCount;

  /// English name for the UI ("Start Dhuhr", "Dhuhr completed").
  final String displayName;

  const Prayer(this.rakahCount, this.displayName);

  /// Whether the prayer has a middle sitting (first tashahhud) after
  /// rak'ah 2: every prayer of more than 2 rak'ahs.
  bool get hasMiddleSitting => rakahCount > 2;

  /// Whether the recitation of [rakah] includes a surah after Al-Fatiha:
  /// rak'ahs 1 and 2 recite Al-Fatiha + a surah, rak'ahs 3 and 4 Al-Fatiha
  /// only. The same in silent prayers (Dhuhr, Asr) as in the others (the
  /// user's choice; open question for the religious reviewer, SPEC section
  /// 8). False for a rak'ah outside 1..[rakahCount].
  bool hasSurah(int rakah) =>
      rakah >= 1 && rakah <= rakahCount && rakahHasSurah(rakah);

  /// [hasSurah] for any prayer: true for rak'ah 1 and 2 only. Used by the
  /// recitation planner, which is told only the rak'ah.
  static bool rakahHasSurah(int rakah) => rakah == 1 || rakah == 2;

  /// The largest rak'ah count of any fard prayer (4).
  static const int maxRakahs = 4;
}

/// Where the user is in the prayer. The states do not depend on the rak'ah:
/// the rak'ah travels with [StateChanged.rakah] (and the label files).
///
/// Sequence for a prayer of N rak'ahs: waiting -> takbir -> per rak'ah k:
/// qiyam -> ruku -> itidal -> sujood (both prostrations and the jalsa);
/// after rak'ah 2 when N > 2: middleSitting (first tashahhud), then qiyam of
/// rak'ah 3; after rak'ah N: finalSitting -> done.
enum PrayerState {
  waiting,
  takbir,
  qiyam,
  ruku,
  itidal,
  sujood,

  /// The first tashahhud after rak'ah 2 of a 3- or 4-rak'ah prayer.
  middleSitting,
  finalSitting,
  done,
}

enum EndReason { completed, timeout, cancelled, cameraLost }

/// Events compare by value, so tests can write `expect(events, [...])`.
sealed class PrayerEvent {
  final int tMs;
  const PrayerEvent(this.tMs);

  List<Object?> get _props;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is PrayerEvent &&
      other.tMs == tMs &&
      _listEquals(other._props, _props);

  @override
  int get hashCode => Object.hash(runtimeType, tMs, Object.hashAll(_props));
}

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class StateChanged extends PrayerEvent {
  final PrayerState from;
  final PrayerState to;
  final int rakah;
  const StateChanged(super.tMs,
      {required this.from, required this.to, required this.rakah});

  @override
  List<Object?> get _props => [from, to, rakah];

  @override
  String toString() => 'StateChanged($tMs ms, $from -> $to, rakah $rakah)';
}

/// Start the recitation for [rakah] (1..N): Al-Fatiha and a surah in
/// rak'ahs 1 and 2, Al-Fatiha only in rak'ahs 3 and 4 ([Prayer.hasSurah]).
/// Fired at most once per rak'ah.
class StartRecitation extends PrayerEvent {
  final int rakah;
  const StartRecitation(super.tMs, {required this.rakah});

  @override
  List<Object?> get _props => [rakah];

  @override
  String toString() => 'StartRecitation($tMs ms, rakah $rakah)';
}

/// Pause the recitation of [rakah] now: the user cannot be seen while it
/// plays (a blind spot). The player fades out and remembers the start of the
/// current ayah. Followed by exactly one [ResumeRecitation] (same rak'ah) or
/// [StopRecitation].
class PauseRecitation extends PrayerEvent {
  final int rakah;
  const PauseRecitation(super.tMs, {required this.rakah});

  @override
  List<Object?> get _props => [rakah];

  @override
  String toString() => 'PauseRecitation($tMs ms, rakah $rakah)';
}

/// Resume the paused recitation of [rakah] from the start of the ayah it was
/// paused in: the user is seen standing again. Continues the same
/// recitation (never a restart); only ever follows a [PauseRecitation].
class ResumeRecitation extends PrayerEvent {
  final int rakah;
  const ResumeRecitation(super.tMs, {required this.rakah});

  @override
  List<Object?> get _props => [rakah];

  @override
  String toString() => 'ResumeRecitation($tMs ms, rakah $rakah)';
}

/// Fade out any recitation now and end it for good (the user left standing,
/// tracking was lost, or the Qiyam ended), also when it is paused. A stopped
/// recitation never resumes.
class StopRecitation extends PrayerEvent {
  const StopRecitation(super.tMs);

  @override
  List<Object?> get _props => const [];

  @override
  String toString() => 'StopRecitation($tMs ms)';
}

class TrackingLost extends PrayerEvent {
  const TrackingLost(super.tMs);

  @override
  List<Object?> get _props => const [];

  @override
  String toString() => 'TrackingLost($tMs ms)';
}

class TrackingRestored extends PrayerEvent {
  const TrackingRestored(super.tMs);

  @override
  List<Object?> get _props => const [];

  @override
  String toString() => 'TrackingRestored($tMs ms)';
}

class SessionEnded extends PrayerEvent {
  final EndReason reason;
  const SessionEnded(super.tMs, {required this.reason});

  @override
  List<Object?> get _props => [reason];

  @override
  String toString() => 'SessionEnded($tMs ms, $reason)';
}
