import 'dart:convert';

import 'package:salah_core/salah_core.dart';

import 'dart:io';

import 'package:flutter/services.dart';

import 'device_services.dart';
import 'seams.dart';

/// Settings as one small JSON file in the app's private files folder (on
/// the phone only; Android auto-backup is off for the app).
///
/// Uses plain `dart:io` and a folder path from the app's own
/// `salah_companion/device` channel: no third-party plugin, so nothing that
/// release-build shrinking can break. Writes go through a temporary file
/// and a rename, so a killed app never leaves a half-written file.
class FileSettingsStore implements SettingsStore {
  static const fileName = 'settings_v1.json';

  final Future<Directory> Function() _directory;
  Map<String, Object?>? _cache;
  Future<void> _writing = Future.value();

  FileSettingsStore(this._directory);

  /// The Android app's private files folder (`Context.getFilesDir()`).
  factory FileSettingsStore.android([MethodChannel? channel]) =>
      FileSettingsStore(() async {
        final path = await (channel ?? DeviceAudioCheck.defaultChannel)
            .invokeMethod<String>('filesDir');
        if (path == null) throw StateError('no files folder');
        return Directory(path);
      });

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  Future<Map<String, Object?>> _read() async {
    final cached = _cache;
    if (cached != null) return cached;
    final file = await _file();
    Map<String, Object?> data = {};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, Object?>) data = decoded;
      } on FormatException {
        // Corrupt file: start from defaults.
      }
    }
    return _cache = data;
  }

  Future<void> _write(Map<String, Object?> data) {
    _cache = data;
    final text = jsonEncode(data);
    return _writing = _writing.catchError((_) {}).then((_) async {
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(file.path);
    });
  }

  @override
  Future<SessionSettings> load() async {
    final raw = (await _read())['settings'];
    if (raw is Map<String, Object?>) {
      try {
        return SessionSettings.fromJson(raw);
      } catch (_) {
        // Unreadable settings: fall back to defaults.
      }
    }
    return const SessionSettings();
  }

  @override
  Future<void> save(SessionSettings settings) async =>
      _write({...await _read(), 'settings': settings.toJson()});

  @override
  Future<bool> isSetupDone() async => (await _read())['setupDone'] == true;

  @override
  Future<void> markSetupDone() async =>
      _write({...await _read(), 'setupDone': true});
}

/// Wraps a store so it can never block or break the app: every call has a
/// time limit, failures fall back to an in-memory copy, and writes never
/// throw. If the phone can't store settings, the app still works; the
/// settings just aren't remembered next time. [problem] keeps the last error
/// for the settings screen (shown on the phone only, never sent anywhere).
class ResilientSettingsStore implements SettingsStore {
  final SettingsStore inner;
  final Duration timeout;
  final MemorySettingsStore _memory = MemorySettingsStore();
  String? problem;

  ResilientSettingsStore(
    this.inner, {
    this.timeout = const Duration(seconds: 2),
  });

  Future<T?> _try<T>(Future<T> Function() call) async {
    try {
      return await call().timeout(timeout);
    } catch (e) {
      problem = '$e';
      return null;
    }
  }

  @override
  Future<SessionSettings> load() async {
    final s = await _try(inner.load);
    if (s != null) {
      await _memory.save(s);
      return s;
    }
    return _memory.load();
  }

  @override
  Future<void> save(SessionSettings settings) async {
    await _memory.save(settings);
    await _try(() => inner.save(settings));
  }

  @override
  Future<bool> isSetupDone() async =>
      await _try(inner.isSetupDone) ?? _memory.setupDone;

  @override
  Future<void> markSetupDone() async {
    await _memory.markSetupDone();
    await _try(inner.markSetupDone);
  }
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
