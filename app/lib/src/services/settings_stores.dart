import 'dart:convert';

import 'package:salah_core/salah_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'seams.dart';

/// Settings as SessionSettings JSON in shared_preferences (on the phone
/// only; Android auto-backup is off for the app).
class SharedPrefsSettingsStore implements SettingsStore {
  static const settingsKey = 'session_settings_v1';
  static const setupDoneKey = 'setup_done_v1';

  final SharedPreferencesAsync _prefs;

  SharedPrefsSettingsStore([SharedPreferencesAsync? prefs])
    : _prefs = prefs ?? SharedPreferencesAsync();

  @override
  Future<SessionSettings> load() async {
    final raw = await _prefs.getString(settingsKey);
    if (raw == null) return const SessionSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return SessionSettings.fromJson(decoded);
      }
    } on FormatException {
      // Corrupt value: fall back to defaults.
    }
    return const SessionSettings();
  }

  @override
  Future<void> save(SessionSettings settings) =>
      _prefs.setString(settingsKey, jsonEncode(settings.toJson()));

  @override
  Future<bool> isSetupDone() async =>
      await _prefs.getBool(setupDoneKey) ?? false;

  @override
  Future<void> markSetupDone() => _prefs.setBool(setupDoneKey, true);
}

/// In-memory store for tests and previews. Round-trips through JSON so it
/// behaves like the real store.
class MemorySettingsStore implements SettingsStore {
  Map<String, Object?>? _json;
  bool setupDone;
  int saveCount = 0;

  MemorySettingsStore({SessionSettings? initial, this.setupDone = false})
    : _json = initial == null
          ? null
          : jsonDecode(jsonEncode(initial.toJson())) as Map<String, Object?>;

  SessionSettings? get saved =>
      _json == null ? null : SessionSettings.fromJson(_json!);

  @override
  Future<SessionSettings> load() async => saved ?? const SessionSettings();

  @override
  Future<void> save(SessionSettings settings) async {
    saveCount++;
    _json = jsonDecode(jsonEncode(settings.toJson())) as Map<String, Object?>;
  }

  @override
  Future<bool> isSetupDone() async => setupDone;

  @override
  Future<void> markSetupDone() async => setupDone = true;
}
