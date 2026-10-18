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

/// Start Al-Fatiha and the surah for [rakah] (1 or 2). Fired once per rak'ah.
class StartRecitation extends PrayerEvent {
  final int rakah;
  const StartRecitation(super.tMs, {required this.rakah});

  @override
  List<Object?> get _props => [rakah];

  @override
  String toString() => 'StartRecitation($tMs ms, rakah $rakah)';
}

/// Fade out any recitation now (the user left standing, or tracking was lost).
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
