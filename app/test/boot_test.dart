import 'dart:async';

import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/main.dart';
import 'package:salah_companion/src/services/seams.dart';
import 'package:salah_core/salah_core.dart';

class _ThrowingStore implements SettingsStore {
  @override
  Future<bool> isSetupDone() async => throw StateError('storage broken');
  @override
  Future<SessionSettings> load() async => throw StateError('storage broken');
  @override
  Future<void> markSetupDone() async {}
  @override
  Future<void> save(SessionSettings settings) async {}
}

class _HangingStore implements SettingsStore {
  @override
  Future<bool> isSetupDone() => Completer<bool>().future;
  @override
  Future<SessionSettings> load() => Completer<SessionSettings>().future;
  @override
  Future<void> markSetupDone() async {}
  @override
  Future<void> save(SessionSettings settings) async {}
}

void main() {
  test('a throwing settings store falls back to first-run defaults', () async {
    final (done, settings) = await loadBootState(_ThrowingStore());
    expect(done, isFalse);
    expect(settings.toJson(), const SessionSettings().toJson());
  });

  test('a hanging settings store times out to first-run defaults', () {
    fakeAsync((async) {
      (bool, SessionSettings)? result;
      loadBootState(_HangingStore()).then((r) => result = r);
      async.elapse(const Duration(seconds: 2));
      expect(result, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(result, isNotNull);
      expect(result!.$1, isFalse);
    });
  });
}
