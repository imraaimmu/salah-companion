/// Contracts shared by the session controller (#15), content (#17), audio
/// (#16) and the app UI (#19-#23). See docs/SPEC.md section 5.
library;

import 'pose.dart';
import 'prayer.dart';
import 'recitation.dart';

/// User settings that shape a session. Stored on the phone only.
class SessionSettings {
  /// Surah numbers for rak'ah 1 and 2 when [autoPairs] is false (rak'ahs 3
  /// and 4 recite Al-Fatiha only).
  final int surahRakah1;
  final int surahRakah2;

  /// Use the reviewer-approved Auto pair table (one pair per day).
  final bool autoPairs;

  /// Index into the Auto pair table; advanced once per calendar day (see
  /// [forDay]).
  final int autoIndex;

  /// The calendar day (`YYYY-MM-DD`, phone's local time) on which
  /// [autoIndex] became the day's pair, or null if no prayer was completed
  /// with Auto yet. Settings saved before this field existed read as null.
  final String? autoPairDate;

  /// Pause before Al-Fatiha in rak'ah 1 (opening dua): 0, 6000 or 18000 ms.
  final int openingDuaMs;

  /// Pause before Al-Fatiha in rak'ah 2, and in rak'ahs 3 and 4.
  final int rakah2PreRollMs;

  /// Silence after each ayah, 0-3000 ms.
  final int ayahGapMs;

  /// Extra silence after Al-Fatiha for Ameen.
  final int ameenGapMs;

  /// Optional dim breathing light on the prayer screen (off by default).
  final bool softGlow;

  /// Which camera watches the user: [CameraLens.rear] (default, sees better
  /// in dim rooms) or [CameraLens.front] (the user can see themselves while
  /// placing the phone). Passed to the pose engine as [CameraConfig.lens].
  /// Settings saved before this field existed read as rear.
  final CameraLens camera;

  /// Show small dim tracking details (posture, state, audio events and
  /// problems) at the bottom of the prayer screen, for testing. Off by
  /// default (the screen stays pure black). Settings saved before this
  /// field existed read as false.
  final bool showTrackingDetails;

  const SessionSettings({
    this.surahRakah1 = 93,
    this.surahRakah2 = 94,
    this.autoPairs = true,
    this.autoIndex = 0,
    this.autoPairDate,
    this.openingDuaMs = 6000,
    this.rakah2PreRollMs = 1500,
    this.ayahGapMs = 1500,
    this.ameenGapMs = 1500,
    this.softGlow = false,
    this.camera = CameraLens.rear,
    this.showTrackingDetails = false,
  });

  SessionSettings copyWith({
    int? surahRakah1,
    int? surahRakah2,
    bool? autoPairs,
    int? autoIndex,
    String? autoPairDate,
    int? openingDuaMs,
    int? rakah2PreRollMs,
    int? ayahGapMs,
    int? ameenGapMs,
    bool? softGlow,
    CameraLens? camera,
    bool? showTrackingDetails,
  }) =>
      SessionSettings(
        surahRakah1: surahRakah1 ?? this.surahRakah1,
        surahRakah2: surahRakah2 ?? this.surahRakah2,
        autoPairs: autoPairs ?? this.autoPairs,
        autoIndex: autoIndex ?? this.autoIndex,
        autoPairDate: autoPairDate ?? this.autoPairDate,
        openingDuaMs: openingDuaMs ?? this.openingDuaMs,
        rakah2PreRollMs: rakah2PreRollMs ?? this.rakah2PreRollMs,
        ayahGapMs: ayahGapMs ?? this.ayahGapMs,
        ameenGapMs: ameenGapMs ?? this.ameenGapMs,
        softGlow: softGlow ?? this.softGlow,
        camera: camera ?? this.camera,
        showTrackingDetails: showTrackingDetails ?? this.showTrackingDetails,
      );

  /// The calendar day of [t] as `YYYY-MM-DD` (in [t]'s own time zone).
  static String dayKey(DateTime t) => '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// The settings for a prayer on [day]: in Auto mode the pair moves on once
  /// per calendar day. On the first day ever the current pair is kept; on a
  /// later day than [autoPairDate] the next pair is used; on the same or an
  /// earlier day (the clock was set back) the settings are returned
  /// unchanged. Either way the
  /// result carries [day] as its [autoPairDate], so saving it after a
  /// completed prayer fixes that pair for the rest of the day, and calling
  /// [forDay] again for the same day changes nothing (idempotent).
  ///
  /// Nothing advances by itself: only saving the result does that (the app
  /// saves it after a completed prayer). A day without a completed prayer
  /// therefore never skips a pair. Manual surah choices are returned
  /// unchanged.
  SessionSettings forDay(DateTime day) {
    if (!autoPairs) return this;
    final key = dayKey(day);
    final last = autoPairDate;
    if (last == null) return copyWith(autoPairDate: key);
    // Only a later day moves on: a clock set back (or a time-zone change
    // across midnight) keeps the pair, so it never advances twice.
    // `YYYY-MM-DD` strings compare in calendar order.
    if (key.compareTo(last) <= 0) return this;
    return copyWith(autoIndex: autoIndex + 1, autoPairDate: key);
  }

  Map<String, Object> toJson() => {
        'surahRakah1': surahRakah1,
        'surahRakah2': surahRakah2,
        'autoPairs': autoPairs,
        'autoIndex': autoIndex,
        if (autoPairDate != null) 'autoPairDate': autoPairDate!,
        'openingDuaMs': openingDuaMs,
        'rakah2PreRollMs': rakah2PreRollMs,
        'ayahGapMs': ayahGapMs,
        'ameenGapMs': ameenGapMs,
        'softGlow': softGlow,
        'camera': camera.name,
        'showTrackingDetails': showTrackingDetails,
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
      autoPairDate: _validDay(j['autoPairDate']),
      openingDuaMs: i('openingDuaMs', d.openingDuaMs),
      rakah2PreRollMs: i('rakah2PreRollMs', d.rakah2PreRollMs),
      ayahGapMs: i('ayahGapMs', d.ayahGapMs),
      ameenGapMs: i('ameenGapMs', d.ameenGapMs),
      softGlow: b('softGlow', d.softGlow),
      camera: _lens(j['camera']),
      showTrackingDetails: b('showTrackingDetails', d.showTrackingDetails),
    );
  }

  /// The [CameraConfig] for a session with these settings.
  CameraConfig get cameraConfig => CameraConfig(lens: camera);
}

final RegExp _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

CameraLens _lens(Object? v) => CameraLens.values
    .firstWhere((l) => l.name == v, orElse: () => CameraLens.rear);

String? _validDay(Object? v) =>
    v is String && _dayPattern.hasMatch(v) ? v : null;

/// Builds what to recite. Implemented by the content repository (#17).
abstract interface class RecitationPlanner {
  /// The plan for [rakah] (1..4): Al-Fatiha's ayahs, then the surah's in
  /// rak'ahs 1 and 2; Al-Fatiha only (no Ameen gap) in rak'ahs 3 and 4
  /// ([Prayer.hasSurah]). The same for every prayer.
  RecitationPlan planFor(int rakah, SessionSettings settings);

  /// The two surahs this session will use (rak'ahs 1 and 2; rak'ahs 3 and
  /// 4 recite no surah), for the home screen line.
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

  /// The latest audio playback problem (a player or planner error), in
  /// words, or null if none happened. The session goes on without audio;
  /// this only makes the failure visible. Once set it stays set.
  final String? audioProblem;

  const SessionStatus({
    this.state = PrayerState.waiting,
    this.rakah = 0,
    this.tracking = true,
    this.reciting = false,
    this.paused = false,
    this.ended,
    this.interruption,
    this.audioProblem,
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
    String? audioProblem,
  }) =>
      SessionStatus(
        state: state ?? this.state,
        rakah: rakah ?? this.rakah,
        tracking: tracking ?? this.tracking,
        reciting: reciting ?? this.reciting,
        paused: paused ?? this.paused,
        ended: ended ?? this.ended,
        interruption: interruption ?? this.interruption,
        audioProblem: audioProblem ?? this.audioProblem,
      );

  @override
  String toString() => 'SessionStatus($state, rakah $rakah, '
      'tracking $tracking, reciting $reciting, paused $paused, '
      'ended $ended, interruption $interruption'
      '${audioProblem == null ? '' : ', audioProblem $audioProblem'})';
}
