import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/pose/pose_wire.dart';
import 'package:salah_companion/src/services/pose_session_runner.dart';
import 'package:salah_companion/src/services/settings_stores.dart';
import 'package:salah_core/salah_core.dart';
import 'package:salah_core/testing.dart';

/// An engine the test drives by hand.
class ManualEngine implements PoseEngine {
  StreamController<PoseFrame>? ctrl;
  int starts = 0;
  int stops = 0;
  final configs = <CameraConfig>[];

  @override
  Stream<PoseFrame> start(CameraConfig config) {
    starts++;
    configs.add(config);
    ctrl = StreamController<PoseFrame>();
    return ctrl!.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    final c = ctrl;
    if (c != null && !c.isClosed) await c.close();
  }
}

class Rig {
  final PoseEngine engine;
  final player = FakeRecitationPlayer();
  final planner = FakeRecitationPlanner();
  late final MemorySettingsStore store;
  final playerInterrupts = StreamController<Interruption>.broadcast();
  final lifecycle = StreamController<Interruption>.broadcast();
  late final PoseSessionRunner runner;

  /// Yesterday's Auto pair (index 1); today is 2026-10-20.
  static const settings = SessionSettings(
    autoIndex: 1,
    autoPairDate: '2026-10-19',
  );
  static final today = DateTime(2026, 10, 20, 13, 10);

  Rig(
    this.engine, {
    Prayer prayer = Prayer.fajr,
    SessionSettings settings = Rig.settings,
    Future<void>? playerReady,
    Duration firstFrameTimeout = const Duration(seconds: 5),
    bool Function()? isAppVisible,
  }) {
    store = MemorySettingsStore(initial: settings);
    runner = PoseSessionRunner(
      settings: settings,
      prayer: prayer,
      engine: engine,
      planner: planner,
      store: store,
      createPlayer: () async {
        if (playerReady != null) await playerReady;
        return (player: player, interruptions: playerInterrupts.stream);
      },
      lifecycleInterruptions: () => lifecycle.stream,
      cameraHandoverDelay: Duration.zero,
      firstFrameTimeout: firstFrameTimeout,
      isAppVisible: isAppVisible ?? () => true,
      clock: () => today,
    );
  }
}

Future<SessionStatus> lastStatus(PoseSessionRunner r) =>
    r.status.firstWhere((s) => s.isOver);

void main() {
  test('a synthetic Fajr completes, recites twice and advances Auto', () async {
    final prayer = generateSyntheticPrayer(SyntheticCase.normal, seed: 7);
    final rig = Rig(FakePoseEngine(prayer.recording));
    final statuses = <SessionStatus>[];
    rig.runner.status.listen(statuses.add);
    final over = lastStatus(rig.runner);
    await rig.runner.start();
    final end = await over.timeout(const Duration(seconds: 60));
    await rig.runner.finished;

    expect(end.ended, EndReason.completed);
    expect(rig.player.callsOf(PlayerCallKind.play).length, 2);
    expect(statuses.any((s) => s.reciting), isTrue);
    expect(statuses.map((s) => s.rakah), contains(2));
    // Saved before the final status was published: the first completed
    // prayer of a new day moves the Auto pair on and dates it.
    expect(rig.store.saved!.autoIndex, 2);
    expect(rig.store.saved!.autoPairDate, '2026-10-20');
    expect(rig.player.disposed, isTrue);
    expect(rig.runner.controller!.frameRate, isNotNull);
  });

  for (final lens in [CameraLens.rear, CameraLens.front]) {
    test('opens the camera from the settings (${lens.name})', () async {
      final engine = ManualEngine();
      final rig = Rig(engine, settings: Rig.settings.copyWith(camera: lens));
      expect(rig.runner.cameraConfig.lens, lens);
      unawaited(rig.runner.start());
      await pumpEventQueue();
      expect(engine.configs.single.lens, lens);
      await rig.runner.cancel();
    });
  }

  test('the state machine follows the chosen prayer', () {
    for (final p in Prayer.values) {
      final rig = Rig(ManualEngine(), prayer: p);
      expect(rig.runner.prayer, p);
      expect(rig.runner.machine.prayer, p);
    }
    // Without a prayer: Fajr.
    final plain = PoseSessionRunner(
      settings: const SessionSettings(),
      engine: ManualEngine(),
      planner: FakeRecitationPlanner(),
      store: MemorySettingsStore(),
      createPlayer: () => throw UnimplementedError(),
    );
    expect(plain.machine.prayer, Prayer.fajr);
  });

  for (final prayer in [Prayer.dhuhr, Prayer.maghrib, Prayer.isha]) {
    test('a synthetic ${prayer.displayName} completes with '
        '${prayer.rakahCount} recitations', () async {
      final p = generateSyntheticPrayer(
        SyntheticCase.normal,
        seed: 7,
        prayer: prayer,
      );
      final rig = Rig(
        FakePoseEngine(p.recording),
        prayer: prayer,
        // A later prayer of the same day keeps the day's pair.
        settings: const SessionSettings(
          autoIndex: 2,
          autoPairDate: '2026-10-20',
        ),
      );
      final statuses = <SessionStatus>[];
      rig.runner.status.listen(statuses.add);
      final over = lastStatus(rig.runner);
      await rig.runner.start();
      final end = await over.timeout(const Duration(seconds: 120));
      await rig.runner.finished;
      expect(end.ended, EndReason.completed);
      expect(end.rakah, prayer.rakahCount);
      final plays = rig.player.callsOf(PlayerCallKind.play);
      expect(plays.length, prayer.rakahCount);
      expect(rig.planner.requests.map((r) => r.$1).toList(), [
        for (var r = 1; r <= prayer.rakahCount; r++) r,
      ]);
      expect(rig.store.saved!.autoIndex, 2);
      expect(rig.store.saved!.autoPairDate, '2026-10-20');
    }, timeout: const Timeout(Duration(seconds: 150)));
  }

  test('late listeners get the latest status first', () async {
    final engine = ManualEngine();
    final rig = Rig(engine);
    await rig.runner.start();
    engine.ctrl!.add(const PoseFrame.heartbeat(0, imageW: 480, imageH: 640));
    await pumpEventQueue();
    final first = await rig.runner.status.first;
    expect(first.isOver, isFalse);
    await rig.runner.cancel();
    final again = await rig.runner.status.first;
    expect(again.ended, EndReason.cancelled);
    expect(again.interruption, Interruption.userCancelled);
  });

  test('cancel ends the session, releases the camera, saves nothing', () async {
    final engine = ManualEngine();
    final rig = Rig(engine);
    await rig.runner.start();
    expect(engine.starts, 1);
    await rig.runner.cancel();
    final end = await lastStatus(rig.runner);
    expect(end.ended, EndReason.cancelled);
    expect(engine.stops, greaterThanOrEqualTo(1));
    expect(rig.store.saveCount, 0);
    expect(rig.player.disposed, isTrue);
    await rig.runner.cancel(); // idempotent
  });

  test('cancel before start ends without opening the camera', () async {
    final engine = ManualEngine();
    final rig = Rig(engine);
    await rig.runner.cancel();
    await rig.runner.start();
    final end = await lastStatus(rig.runner);
    expect(end.ended, EndReason.cancelled);
    expect(engine.starts, 0);
  });

  test('engine "paused" error ends as appBackgrounded', () async {
    final engine = ManualEngine();
    final rig = Rig(engine);
    await rig.runner.start();
    engine.ctrl!.addError(
      const PoseEngineError('paused', 'The app was paused'),
    );
    final end = await lastStatus(rig.runner);
    expect(end.ended, EndReason.cancelled);
    expect(end.interruption, Interruption.appBackgrounded);
  });

  test('camera errors end as cameraLost', () async {
    final engine = ManualEngine();
    final rig = Rig(engine);
    await rig.runner.start();
    engine.ctrl!.addError(const PoseEngineError('cameraInUse', 'busy'));
    final end = await lastStatus(rig.runner);
    expect(end.ended, EndReason.cameraLost);
    expect(end.interruption, Interruption.cameraUnavailable);
  });

  test('app lifecycle backgrounding ends the session', () async {
    final rig = Rig(ManualEngine());
    await rig.runner.start();
    rig.lifecycle.add(Interruption.appBackgrounded);
    final end = await lastStatus(rig.runner);
    expect(end.interruption, Interruption.appBackgrounded);
  });

  test('player interruptions reach the controller', () async {
    final rig = Rig(ManualEngine());
    await rig.runner.start();
    rig.playerInterrupts.add(Interruption.headphonesUnplugged);
    await pumpEventQueue();
    expect(rig.runner.controller!.isOver, isFalse);
    rig.playerInterrupts.add(Interruption.audioFocusLost);
    final end = await lastStatus(rig.runner);
    expect(end.interruption, Interruption.audioFocusLost);
  });

  test('frames feed the frame-rate monitor: a stalled camera is lost '
      'tracking', () async {
    final engine = ManualEngine();
    final rig = Rig(engine);
    await rig.runner.start();
    // 1 s of camera frames at 15 fps, then 6 s of heartbeats only.
    var t = 0;
    for (; t <= 1000; t += 67) {
      engine.ctrl!.add(
        PoseFrame(tMs: t, landmarks: null, imageW: 480, imageH: 640),
      );
    }
    final last = t - 67;
    for (var k = 1; k <= 60; k++) {
      engine.ctrl!.add(
        PoseFrame.heartbeat(last + k * 100, imageW: 480, imageH: 640),
      );
    }
    await pumpEventQueue();
    final c = rig.runner.controller!;
    expect(c.frameRate!.low, isTrue);
    expect(c.current.tracking, isFalse);
    await rig.runner.cancel();
  });

  test('no camera frame within the watchdog ends as cameraLost', () async {
    final engine = ManualEngine();
    final rig = Rig(
      engine,
      firstFrameTimeout: const Duration(milliseconds: 50),
    );
    final over = lastStatus(rig.runner);
    await rig.runner.start();
    expect(engine.starts, 1);
    final end = await over.timeout(const Duration(seconds: 5));
    expect(end.ended, EndReason.cameraLost);
    expect(end.interruption, Interruption.cameraUnavailable);
    await rig.runner.finished;
    expect(engine.stops, greaterThanOrEqualTo(1));
    expect(rig.player.disposed, isTrue);
  });

  test('a first frame in time disarms the watchdog', () async {
    final engine = ManualEngine();
    final rig = Rig(
      engine,
      firstFrameTimeout: const Duration(milliseconds: 50),
    );
    await rig.runner.start();
    engine.ctrl!.add(
      const PoseFrame(tMs: 0, landmarks: null, imageW: 480, imageH: 640),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(rig.runner.controller!.isOver, isFalse);
    await rig.runner.cancel();
    final end = await lastStatus(rig.runner);
    expect(end.interruption, Interruption.userCancelled);
  });

  test(
    'backgrounded while the player is being created: ends, no camera',
    () async {
      final engine = ManualEngine();
      final ready = Completer<void>();
      final rig = Rig(engine, playerReady: ready.future);
      final over = lastStatus(rig.runner);
      final starting = rig.runner.start();
      await pumpEventQueue();
      rig.lifecycle.add(Interruption.appBackgrounded); // during the await
      ready.complete();
      await starting;
      final end = await over;
      expect(end.ended, EndReason.cancelled);
      expect(end.interruption, Interruption.appBackgrounded);
      expect(engine.starts, 0);
      await rig.runner.finished;
      expect(rig.player.disposed, isTrue);
    },
  );

  test('already in the background when the camera would open: ends', () async {
    final engine = ManualEngine();
    final rig = Rig(engine, isAppVisible: () => false);
    final over = lastStatus(rig.runner);
    await rig.runner.start();
    final end = await over;
    expect(end.interruption, Interruption.appBackgrounded);
    expect(engine.starts, 0);
  });
}
