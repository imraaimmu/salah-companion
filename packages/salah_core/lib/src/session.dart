/// Contracts shared by the session controller (#15), content (#17), audio
/// (#16) and the app UI (#19-#23). See docs/SPEC.md section 5.
library;

import 'prayer.dart';
import 'recitation.dart';

/// User settings that shape a session. Stored on the phone only.
class SessionSettings {
  /// Surah numbers for rak'ah 1 and 2 when [autoPairs] is false.
  final int surahRakah1;
  final int surahRakah2;

  /// Use the reviewer-approved Auto pair table (one pair per day).
  final bool autoPairs;

  /// Index into the Auto pair table; advanced once per completed session.
  final int autoIndex;

  /// Pause before Al-Fatiha in rak'ah 1 (opening dua): 0, 6000 or 18000 ms.
  final int openingDuaMs;

  /// Pause before Al-Fatiha in rak'ah 2.
  final int rakah2PreRollMs;

  /// Silence after each ayah, 0-3000 ms.
  final int ayahGapMs;

  /// Extra silence after Al-Fatiha for Ameen.
  final int ameenGapMs;

  /// Optional dim breathing light on the prayer screen (off by default).
  final bool softGlow;

  const SessionSettings({
    this.surahRakah1 = 93,
    this.surahRakah2 = 94,
    this.autoPairs = true,
    this.autoIndex = 0,
    this.openingDuaMs = 6000,
    this.rakah2PreRollMs = 1500,
    this.ayahGapMs = 1500,
    this.ameenGapMs = 1500,
    this.softGlow = false,
  });

  SessionSettings copyWith({
    int? surahRakah1,
    int? surahRakah2,
    bool? autoPairs,
    int? autoIndex,
    int? openingDuaMs,
    int? rakah2PreRollMs,
    int? ayahGapMs,
    int? ameenGapMs,
    bool? softGlow,
  }) =>
      SessionSettings(
        surahRakah1: surahRakah1 ?? this.surahRakah1,
        surahRakah2: surahRakah2 ?? this.surahRakah2,
        autoPairs: autoPairs ?? this.autoPairs,
        autoIndex: autoIndex ?? this.autoIndex,
        openingDuaMs: openingDuaMs ?? this.openingDuaMs,
        rakah2PreRollMs: rakah2PreRollMs ?? this.rakah2PreRollMs,
        ayahGapMs: ayahGapMs ?? this.ayahGapMs,
        ameenGapMs: ameenGapMs ?? this.ameenGapMs,
        softGlow: softGlow ?? this.softGlow,
      );

  Map<String, Object> toJson() => {
        'surahRakah1': surahRakah1,
        'surahRakah2': surahRakah2,
        'autoPairs': autoPairs,
        'autoIndex': autoIndex,
        'openingDuaMs': openingDuaMs,
        'rakah2PreRollMs': rakah2PreRollMs,
        'ayahGapMs': ayahGapMs,
        'ameenGapMs': ameenGapMs,
        'softGlow': softGlow,
      };

  /// Unknown or invalid fields fall back to defaults.
  factory SessionSettings.fromJson(Map<String, Object?> j) {
    const d = SessionSettings();
    int i(String k, int def) => j[k] is int ? j[k]! as int : def;
    bool b(String k, bool def) => j[k] is bool ? j[k]! as bool : def;
    return SessionSettings(
      surahRakah1: i('surahRakah1', d.surahRakah1),
      surahRakah2: i('surahRakah2', d.surahRakah2),
      autoPairs: b('autoPairs', d.autoPairs),
      autoIndex: i('autoIndex', d.autoIndex),
      openingDuaMs: i('openingDuaMs', d.openingDuaMs),
      rakah2PreRollMs: i('rakah2PreRollMs', d.rakah2PreRollMs),
      ayahGapMs: i('ayahGapMs', d.ayahGapMs),
      ameenGapMs: i('ameenGapMs', d.ameenGapMs),
      softGlow: b('softGlow', d.softGlow),
    );
  }
}

/// Builds what to recite. Implemented by the content repository (#17).
abstract interface class RecitationPlanner {
  /// The plan for [rakah] (1 or 2): Al-Fatiha's ayahs, then the surah's.
  RecitationPlan planFor(int rakah, SessionSettings settings);

  /// The two surahs this session will use, for the home screen line.
  (int rakah1, int rakah2) surahsFor(SessionSettings settings);
}

/// Things outside the prayer logic that end or pause a session.
enum Interruption {
  phoneCall,
  appBackgrounded,
  headphonesUnplugged,
  audioFocusLost,
  cameraUnavailable,
  lowFrameRate,
  userCancelled,
}

/// What the UI shows. Emitted by the session controller (#15).
class SessionStatus {
  final PrayerState state;
  final int rakah;
  final bool tracking;
  final bool reciting;
  final bool paused;

  /// Set once the session has ended.
  final EndReason? ended;
  final Interruption? interruption;

  const SessionStatus({
    this.state = PrayerState.waiting,
    this.rakah = 0,
    this.tracking = true,
    this.reciting = false,
    this.paused = false,
    this.ended,
    this.interruption,
  });

  bool get isOver => ended != null;

  SessionStatus copyWith({
    PrayerState? state,
    int? rakah,
    bool? tracking,
    bool? reciting,
    bool? paused,
    EndReason? ended,
    Interruption? interruption,
  }) =>
      SessionStatus(
        state: state ?? this.state,
        rakah: rakah ?? this.rakah,
        tracking: tracking ?? this.tracking,
        reciting: reciting ?? this.reciting,
        paused: paused ?? this.paused,
        ended: ended ?? this.ended,
        interruption: interruption ?? this.interruption,
      );

  @override
  String toString() => 'SessionStatus($state, rakah $rakah, '
      'tracking $tracking, reciting $reciting, paused $paused, '
      'ended $ended, interruption $interruption)';
}
