/// Prayer states and events. See docs/SPEC.md, section "Prayer logic".
library;

enum PrayerState {
  waiting,
  takbir,
  qiyam1,
  ruku1,
  itidal1,
  sujood1,
  qiyam2,
  ruku2,
  itidal2,
  sujood2,
  finalSitting,
  done,
}

enum EndReason { completed, timeout, cancelled, cameraLost }

sealed class PrayerEvent {
  final int tMs;
  const PrayerEvent(this.tMs);
}

class StateChanged extends PrayerEvent {
  final PrayerState from;
  final PrayerState to;
  final int rakah;
  const StateChanged(super.tMs, {required this.from, required this.to, required this.rakah});

  @override
  String toString() => 'StateChanged($tMs ms, $from -> $to, rakah $rakah)';
}

/// Start Al-Fatiha and the surah for [rakah] (1 or 2). Fired once per rak'ah.
class StartRecitation extends PrayerEvent {
  final int rakah;
  const StartRecitation(super.tMs, {required this.rakah});

  @override
  String toString() => 'StartRecitation($tMs ms, rakah $rakah)';
}

/// Fade out any recitation now (the user left standing, or tracking was lost).
class StopRecitation extends PrayerEvent {
  const StopRecitation(super.tMs);

  @override
  String toString() => 'StopRecitation($tMs ms)';
}

class TrackingLost extends PrayerEvent {
  const TrackingLost(super.tMs);

  @override
  String toString() => 'TrackingLost($tMs ms)';
}

class TrackingRestored extends PrayerEvent {
  const TrackingRestored(super.tMs);

  @override
  String toString() => 'TrackingRestored($tMs ms)';
}

class SessionEnded extends PrayerEvent {
  final EndReason reason;
  const SessionEnded(super.tMs, {required this.reason});

  @override
  String toString() => 'SessionEnded($tMs ms, $reason)';
}
