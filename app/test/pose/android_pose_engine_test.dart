import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/pose/android_pose_engine.dart';
import 'package:salah_core/salah_core.dart';

import 'wire_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = AndroidPoseEngine.defaultMethodChannel;
  const events = AndroidPoseEngine.defaultEventChannel;

  late List<MethodCall> calls;
  late MockStreamHandlerEventSink? sink;
  late bool listening;

  setUp(() {
    calls = [];
    sink = null;
    listening = false;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (args, s) {
          sink = s;
          listening = true;
        },
        onCancel: (args) => listening = false,
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  AndroidPoseEngine engine({bool granted = true}) =>
      AndroidPoseEngine(requestPermission: () async => granted);

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('start sends the config and decodes frames and heartbeats', () async {
    final e = engine();
    final got = <PoseFrame>[];
    final sub = e.start(const CameraConfig()).listen(got.add);
    await pump();
    expect(calls.single.method, 'start');
    final args = calls.single.arguments as Map;
    expect(args['width'], 480);
    expect(args['height'], 640);
    expect(args['fps'], 15);
    expect(args['lens'], 'rear');
    expect(args['preferGpu'], true);
    final token = args['token'] as int;

    sink!.success(frameBuffer(token: token, tMs: 0, people: [person(1)]));
    sink!.success(frameBuffer(token: token, tMs: 67));
    sink!.success(frameBuffer(kind: 1, token: token, tMs: 167));
    sink!.success({'event': 'engine', 'token': token, 'delegate': 'GPU'});
    await pump();

    expect(got.map((f) => f.tMs), [0, 67, 167]);
    expect(got[0].landmarks, isNotNull);
    expect(got[1].hasPerson, isFalse);
    expect(got[2].people, isEmpty);
    expect(e.info['delegate'], 'GPU');
    await sub.cancel();
  });

  test('reports the lens the native side opened (fallback included)', () async {
    final e = engine();
    final got = <PoseFrame>[];
    final sub = e
        .start(const CameraConfig(lens: CameraLens.front))
        .listen(got.add);
    await pump();
    final args = calls.single.arguments as Map;
    expect(args['lens'], 'front');
    final token = args['token'] as int;
    expect(e.activeLens.value, isNull);
    sink!.success({
      'event': 'started',
      'token': token,
      'lens': 'front',
      'requestedLens': 'front',
      'lensFallback': false,
    });
    await pump();
    expect(e.activeLens.value, CameraLens.front);

    // Front-camera landmarks pass through unchanged: they arrive upright and
    // unmirrored, and Dart never mirrors them.
    sink!.success(frameBuffer(token: token, tMs: 0, people: [person(1)]));
    await pump();
    final rear = engine();
    final rearGot = <PoseFrame>[];
    await sub.cancel();
    calls.clear();
    final sub2 = rear.start(const CameraConfig()).listen(rearGot.add);
    await pump();
    final token2 = (calls.last.arguments as Map)['token'] as int;
    sink!.success(frameBuffer(token: token2, tMs: 0, people: [person(1)]));
    await pump();
    final a = got.single.landmarks!;
    final b = rearGot.single.landmarks!;
    for (var i = 0; i < a.length; i++) {
      expect(a[i].x, b[i].x);
      expect(a[i].y, b[i].y);
    }

    // No front camera: the native side opened the rear one and says so.
    sink!.success({
      'event': 'started',
      'token': token2,
      'lens': 'rear',
      'requestedLens': 'front',
      'lensFallback': true,
    });
    await pump();
    expect(rear.activeLens.value, CameraLens.rear);
    expect(rear.info['lensFallback'], true);
    await sub2.cancel();
  });

  test('lens labels map to CameraLens', () {
    expect(AndroidPoseEngine.lensFromWire('front'), CameraLens.front);
    expect(AndroidPoseEngine.lensFromWire('rear'), CameraLens.rear);
    expect(
      AndroidPoseEngine.lensFromWire('rearUltraWide'),
      CameraLens.rearUltraWide,
    );
    expect(AndroidPoseEngine.lensFromWire(null), CameraLens.rear);
  });

  test('events from another session token are ignored', () async {
    final e = engine();
    final got = <PoseFrame>[];
    final sub = e.start(const CameraConfig()).listen(got.add);
    await pump();
    final token = (calls.single.arguments as Map)['token'] as int;
    sink!.success(frameBuffer(token: token + 100, tMs: 5));
    sink!.success(frameBuffer(token: token, tMs: 6));
    await pump();
    expect(got.map((f) => f.tMs), [6]);
    await sub.cancel();
  });

  test('a malformed event is skipped, not fatal', () async {
    final e = engine();
    final got = <PoseFrame>[];
    final sub = e.start(const CameraConfig()).listen(got.add);
    await pump();
    final token = (calls.single.arguments as Map)['token'] as int;
    sink!.success(Float32List(3));
    sink!.success(frameBuffer(token: token, tMs: 9));
    await pump();
    expect(got.single.tMs, 9);
    await sub.cancel();
  });

  test(
    'native error becomes a PoseEngineError and closes the stream',
    () async {
      final e = engine();
      final errors = <Object>[];
      final done = Completer<void>();
      e
          .start(const CameraConfig())
          .listen((_) {}, onError: errors.add, onDone: done.complete);
      await pump();
      final token = (calls.single.arguments as Map)['token'] as int;
      sink!.success({
        'event': 'error',
        'token': token,
        'code': 'cameraInUse',
        'message': 'taken',
      });
      await done.future;
      final err = errors.single as PoseEngineError;
      expect(err.code, 'cameraInUse');
      expect(err.interruption, Interruption.cameraUnavailable);
      expect(calls.last.method, 'stop');
      expect(listening, isFalse);
    },
  );

  test('permission denied fails without starting the camera', () async {
    final e = engine(granted: false);
    final errors = <Object>[];
    final done = Completer<void>();
    e
        .start(const CameraConfig())
        .listen((_) {}, onError: errors.add, onDone: done.complete);
    await done.future;
    expect((errors.single as PoseEngineError).code, 'permissionDenied');
    expect(
      (errors.single as PoseEngineError).interruption,
      Interruption.cameraUnavailable,
    );
    expect(calls.where((c) => c.method == 'start'), isEmpty);
  });

  test('stop releases the native side and closes the stream', () async {
    final e = engine();
    final done = Completer<void>();
    e.start(const CameraConfig()).listen((_) {}, onDone: done.complete);
    await pump();
    expect(listening, isTrue);
    await e.stop();
    await done.future;
    expect(calls.map((c) => c.method), ['start', 'stop']);
    expect(listening, isFalse);
  });

  test('cancelling the subscription stops the engine', () async {
    final e = engine();
    final sub = e.start(const CameraConfig()).listen((_) {});
    await pump();
    await sub.cancel();
    expect(calls.map((c) => c.method), ['start', 'stop']);
  });

  test('a second start replaces the first session', () async {
    final e = engine();
    final first = <PoseFrame>[];
    final firstDone = Completer<void>();
    e.start(const CameraConfig()).listen(first.add, onDone: firstDone.complete);
    await pump();
    final t1 = (calls.last.arguments as Map)['token'] as int;
    final second = <PoseFrame>[];
    final sub2 = e
        .start(const CameraConfig(lens: CameraLens.rearUltraWide))
        .listen(second.add);
    await firstDone.future;
    await pump();
    final startCall = calls.lastWhere((c) => c.method == 'start');
    final t2 = (startCall.arguments as Map)['token'] as int;
    expect(t2, isNot(t1));
    expect((startCall.arguments as Map)['lens'], 'rearUltraWide');
    sink!.success(frameBuffer(token: t1, tMs: 1));
    sink!.success(frameBuffer(token: t2, tMs: 2));
    await pump();
    expect(first, isEmpty);
    expect(second.single.tMs, 2);
    await sub2.cancel();
  });

  test(
    'without an override, permission goes through the method channel',
    () async {
      var grant = false;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return call.method == 'cameraPermission' ? grant : null;
      });
      final e = AndroidPoseEngine();
      expect(await e.cameraPermission(request: false), isFalse);
      expect((calls.single.arguments as Map)['request'], false);

      final errors = <Object>[];
      final done = Completer<void>();
      e
          .start(const CameraConfig())
          .listen((_) {}, onError: errors.add, onDone: done.complete);
      await done.future;
      expect((errors.single as PoseEngineError).code, 'permissionDenied');

      calls.clear();
      grant = true;
      final sub = e.start(const CameraConfig()).listen((_) {});
      await pump();
      await pump();
      expect(calls.map((c) => c.method), ['cameraPermission', 'start']);
      expect((calls.first.arguments as Map)['request'], true);
      await sub.cancel();
    },
  );

  test('a PlatformException from start becomes a stream error', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'start') {
        throw PlatformException(code: 'badArgs', message: 'nope');
      }
      return null;
    });
    final errors = <Object>[];
    final done = Completer<void>();
    engine()
        .start(const CameraConfig())
        .listen((_) {}, onError: errors.add, onDone: done.complete);
    await done.future;
    expect((errors.single as PoseEngineError).code, 'badArgs');
  });
}
