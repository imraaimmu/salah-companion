import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/audio/just_audio_recitation_player.dart';
import 'package:salah_companion/src/audio/playback_backend.dart';
import 'package:salah_companion/src/audio/timeline.dart';
import 'package:salah_core/salah_core.dart';

/// Records every call; the test moves the playhead by hand.
class FakeBackend implements PlaybackBackend {
  final log = <String>[];
  final volumes = <double>[];
  final _completed = StreamController<void>.broadcast();
  final errorCtrl = StreamController<Object>.broadcast();
  List<TimelineSegment> loaded = const [];

  /// When set, load() throws it.
  Object? loadError;
  bool disposed = false;

  /// When set, stop() waits for it.
  Completer<void>? stopGate;

  @override
  int? currentIndex;
  @override
  Duration position = Duration.zero;

  void finish() => _completed.add(null);

  @override
  Future<void> load(List<TimelineSegment> segments) async {
    final e = loadError;
    if (e != null) throw e;
    loaded = segments;
    currentIndex = 0;
    position = Duration.zero;
    log.add('load ${segments.length}');
  }

  @override
  Future<void> play() async => log.add('play');
  @override
  Future<void> pause() async => log.add('pause');
  @override
  Future<void> stop() async {
    final gate = stopGate;
    if (gate != null) await gate.future;
    currentIndex = null;
    log.add('stop');
  }

  @override
  Future<void> seek(int index, Duration offset) async {
    currentIndex = index;
    position = offset;
    log.add('seek $index ${offset.inMilliseconds}');
  }

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<Object> get errors => errorCtrl.stream;

  @override
  Future<void> dispose() async => disposed = true;
}

AyahClip clip(int surah, int ayah) => AyahClip(
  assetPath: 'a/$surah-$ayah',
  surah: surah,
  ayah: ayah,
  duration: const Duration(seconds: 2),
);

final plan = RecitationPlan(
  clips: [clip(1, 7), clip(108, 1), clip(108, 2)],
  preRoll: const Duration(milliseconds: 1500),
  gapAfterAyah: const Duration(milliseconds: 500),
);

void main() {
  late FakeBackend backend;
  late StreamController<Interruption> system;
  late List<bool> sessionActive;
  late JustAudioRecitationPlayer player;
  late List<Duration> waits;

  setUp(() {
    backend = FakeBackend();
    system = StreamController<Interruption>.broadcast();
    sessionActive = [];
    waits = [];
    player = JustAudioRecitationPlayer(
      backend: backend,
      systemInterruptions: system.stream,
      setSessionActive: (a) async {
        sessionActive.add(a);
        return true;
      },
      // Fades run instantly in tests, but still yield between steps.
      wait: (d) async {
        waits.add(d);
        await Future<void>.delayed(Duration.zero);
      },
    );
  });

  tearDown(() => player.dispose());

  test(
    'play loads the timeline at full volume and completes at the end',
    () async {
      var done = false;
      final f = player.play(plan).then((_) => done = true);
      await pumpEventQueue();
      expect(backend.loaded.map((s) => s.toString()), [
        'Silence(1500 ms @ 0)',
        'Clip(1:7 @ 1500)',
        'Silence(2000 ms @ 3500)', // 500 ms gap + 1500 ms Ameen gap
        'Clip(108:1 @ 5500)',
        'Silence(500 ms @ 7500)',
        'Clip(108:2 @ 8000)',
      ]);
      expect(backend.log, ['load 6', 'play']);
      expect(backend.volumes, [1]);
      expect(sessionActive, [true]);
      expect(player.isPlaying, isTrue);
      expect(done, isFalse);

      backend.finish();
      await f;
      expect(done, isTrue);
      expect(player.isPlaying, isFalse);
      expect(sessionActive, [true, false]);
    },
  );

  test('an empty plan completes at once and plays nothing', () async {
    await player.play(
      RecitationPlan(
        clips: const [],
        preRoll: Duration.zero,
        gapAfterAyah: Duration.zero,
      ),
    );
    expect(backend.log, isEmpty);
  });

  test('fadeOut ramps to zero over 300 ms, stops and completes play', () async {
    final f = player.play(plan);
    await pumpEventQueue();
    backend.volumes.clear();
    await player.fadeOut();
    await f;
    expect(backend.volumes, hasLength(15));
    expect(backend.volumes.last, 0);
    expect(waits.fold<int>(0, (n, d) => n + d.inMilliseconds), 300);
    expect(backend.log.last, 'stop');
    // fadeOut is final.
    await player.resume();
    expect(backend.log.last, 'stop');
  });

  test('fadeOut during the pre-roll cancels it', () async {
    final f = player.play(plan);
    await pumpEventQueue();
    backend.position = const Duration(milliseconds: 700); // still in pre-roll
    await player.fadeOut(duration: const Duration(milliseconds: 100));
    await f;
    expect(backend.log, ['load 6', 'play', 'stop']);
  });

  test('pause mid-ayah resumes from the start of that ayah', () async {
    final f = player.play(plan);
    await pumpEventQueue();
    backend.currentIndex = 3; // 108:1
    backend.position = const Duration(milliseconds: 1300);
    backend.volumes.clear();
    await player.pause();
    expect(backend.volumes.last, 0);
    expect(backend.log.last, 'pause');
    expect(player.isPaused, isTrue);
    expect(player.resumePoint, const ResumePoint(3, Duration.zero));

    backend.volumes.clear();
    await player.resume();
    expect(backend.log.sublist(backend.log.length - 2), ['seek 3 0', 'play']);
    expect(backend.volumes.first, 0);
    expect(backend.volumes.last, 1);
    expect(backend.volumes, hasLength(16)); // jump to 0, then 15 steps up
    expect(player.isPlaying, isTrue);

    backend.finish();
    await f; // the same recitation finishes; play() completes once
  });

  test('pause in a gap keeps only the remaining silence', () async {
    unawaited(player.play(plan));
    await pumpEventQueue();
    backend.currentIndex = 2;
    backend.position = const Duration(milliseconds: 1200);
    await player.pause();
    await player.resume();
    expect(backend.log, contains('seek 2 1200'));
  });

  test('resume during the pause fade cancels the fade', () async {
    unawaited(player.play(plan));
    await pumpEventQueue();
    backend.currentIndex = 1;
    backend.position = const Duration(milliseconds: 900);
    final pausing = player.pause();
    await Future<void>.delayed(Duration.zero);
    expect(player.isPaused, isTrue);
    await player.resume();
    await pausing;
    expect(backend.log, isNot(contains('pause')));
    expect(backend.log.last, 'play');
    expect(backend.volumes.last, 1);
    expect(player.isPlaying, isTrue);
  });

  test('pause and resume do nothing when they do not apply', () async {
    await player.pause();
    await player.resume();
    expect(backend.log, isEmpty);

    unawaited(player.play(plan));
    await pumpEventQueue();
    await player.resume(); // not paused
    expect(backend.log, ['load 6', 'play']);
    await player.pause();
    await player.pause(); // already paused
    expect(backend.log.where((e) => e == 'pause'), hasLength(1));
  });

  test('stopNow stops at once, also while paused', () async {
    final f = player.play(plan);
    await pumpEventQueue();
    await player.pause();
    await player.stopNow();
    await f;
    expect(backend.log.last, 'stop');
    await player.resume();
    expect(backend.log.last, 'stop');
  });

  test('stopNow during a pause fade wins over it', () async {
    final f = player.play(plan);
    await pumpEventQueue();
    final pausing = player.pause();
    await player.stopNow();
    await pausing;
    await f;
    expect(backend.log, ['load 6', 'play', 'stop']);
  });

  test('a new play replaces the current one', () async {
    var firstDone = false;
    final first = player.play(plan).then((_) => firstDone = true);
    await pumpEventQueue();
    final second = player.play(plan);
    await first;
    expect(firstDone, isTrue);
    await pumpEventQueue();
    expect(backend.log, ['load 6', 'play', 'stop', 'load 6', 'play']);
    backend.finish();
    await second;
  });

  test('headphones unplugged: stops, then reports the interruption', () async {
    final events = <Interruption>[];
    player.interruptions.listen(events.add);
    final f = player.play(plan);
    await pumpEventQueue();
    system.add(Interruption.headphonesUnplugged);
    await f;
    await pumpEventQueue();
    expect(backend.log.last, 'stop');
    expect(events, [Interruption.headphonesUnplugged]);
  });

  test(
    'dispose completes play, releases the player and blocks reuse',
    () async {
      final f = player.play(plan);
      await pumpEventQueue();
      player.dispose();
      await f;
      await pumpEventQueue();
      expect(backend.disposed, isTrue);
      expect(() => player.play(plan), throwsStateError);
    },
  );

  test('two play/pause cycles ramp from the real volume each time', () async {
    for (var cycle = 0; cycle < 2; cycle++) {
      final f = player.play(plan);
      await pumpEventQueue();
      expect(backend.volumes.last, 1, reason: 'cycle $cycle starts audible');
      backend.volumes.clear();
      await player.pause();
      // A proper ramp: 15 strictly decreasing steps from below 1 to 0.
      expect(backend.volumes, hasLength(15), reason: 'cycle $cycle');
      expect(backend.volumes.first, closeTo(14 / 15, 1e-9));
      expect(backend.volumes.last, 0);
      for (var k = 1; k < backend.volumes.length; k++) {
        expect(backend.volumes[k], lessThan(backend.volumes[k - 1]));
      }
      await player.stopNow();
      await f;
    }
  });

  test('a play after a fadeOut fades out again from full volume', () async {
    var f = player.play(plan);
    await pumpEventQueue();
    await player.fadeOut();
    await f;
    f = player.play(plan);
    await pumpEventQueue();
    backend.volumes.clear();
    await player.fadeOut();
    await f;
    expect(backend.volumes.first, closeTo(14 / 15, 1e-9));
    expect(backend.volumes.toSet(), hasLength(15));
  });

  test('a natural end halting late leaves a newer play alone', () async {
    var firstDone = false;
    final first = player.play(plan).then((_) => firstDone = true);
    await pumpEventQueue();
    backend.stopGate = Completer<void>();
    backend.finish(); // the halt now waits in backend.stop()
    await pumpEventQueue();
    var secondDone = false;
    final second = player.play(plan).then((_) => secondDone = true);
    await pumpEventQueue();
    expect(player.isPlaying, isTrue);
    backend.stopGate!.complete();
    backend.stopGate = null;
    await first;
    await pumpEventQueue();
    expect(firstDone, isTrue);
    expect(secondDone, isFalse, reason: 'the newer play is still running');
    expect(player.isPlaying, isTrue);
    // The late halt did not release the session the newer play activated.
    expect(sessionActive, [true, true]);
    backend.finish();
    await second;
    expect(sessionActive, [true, true, false]);
  });

  test('refused audio focus: plays nothing, reports audioFocusLost', () async {
    final refused = JustAudioRecitationPlayer(
      backend: backend,
      setSessionActive: (a) async {
        sessionActive.add(a);
        return !a ? true : false;
      },
      wait: (_) async {},
    );
    final events = <Interruption>[];
    refused.interruptions.listen(events.add);
    await refused.play(plan);
    await pumpEventQueue();
    expect(backend.log, isNot(contains('play')));
    expect(backend.log, isNot(contains('load 6')));
    expect(events, [Interruption.audioFocusLost]);
    expect(refused.isPlaying, isFalse);
    refused.dispose();
  });

  test('a load error is thrown by play and releases the session', () async {
    backend.loadError = Exception('Unable to open asset');
    await expectLater(player.play(plan), throwsA(isA<Exception>()));
    expect(player.isPlaying, isFalse);
    expect(sessionActive, [true, false]);
    expect(backend.log, ['stop']);
  });

  test('asynchronous backend errors are forwarded as problems', () async {
    final problems = <Object>[];
    player.problems.listen(problems.add);
    backend.errorCtrl.add(Exception('decoder failed'));
    await pumpEventQueue();
    expect(problems.single.toString(), contains('decoder failed'));
  });

  group('bundled audio sources', () {
    const path = 'assets/audio/placeholder/001001.wav';

    test('Android reads assets in place from the APK', () {
      expect(
        androidAssetUri(path).toString(),
        'file:///android_asset/flutter_assets/assets/audio/placeholder/'
        '001001.wav',
      );
      final src = bundledAudioSource(path, inPlace: true);
      final uri = src.uri;
      // Not the asset scheme, which just_audio would copy to a cache dir.
      expect(uri.scheme, 'file');
      expect(uri.path, '/android_asset/flutter_assets/$path');
    });

    test('other platforms keep AudioSource.asset', () {
      final src = bundledAudioSource(path);
      expect(src.uri.scheme, 'asset');
      expect(src.uri.path, '/$path');
    });

    test('special characters are percent-encoded, segments decode back', () {
      final uri = androidAssetUri('assets/audio/a b.wav');
      expect(uri.toString(), endsWith('/a%20b.wav'));
      expect(uri.pathSegments, [
        'android_asset',
        'flutter_assets',
        'assets',
        'audio',
        'a b.wav',
      ]);
    });
  });

  group('clearAudioAssetCache', () {
    test('runs clears one after another and swallows errors', () async {
      final log = <String>[];
      final gate = Completer<void>();
      final first = clearAudioAssetCache(
        clear: () async {
          log.add('first start');
          await gate.future;
          log.add('first end');
          throw const FileSystemException('no cache dir');
        },
      );
      final second = clearAudioAssetCache(clear: () async => log.add('second'));
      await pumpEventQueue();
      expect(log, ['first start']);
      gate.complete();
      await first; // the error is swallowed
      await second;
      expect(log, ['first start', 'first end', 'second']);
    });
  });

  group('mapAudioInterruption', () {
    test('a beginning interruption stops recitation', () {
      expect(
        mapAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        ),
        Interruption.audioFocusLost,
      );
      expect(
        mapAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.unknown),
        ),
        Interruption.audioFocusLost,
      );
    });

    test('ducking and interruption ends are ignored', () {
      expect(
        mapAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.duck),
        ),
        isNull,
      );
      expect(
        mapAudioInterruption(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        ),
        isNull,
      );
    });

    test('a duck (notification chime) never pauses or ends recitation', () {
      // With willPauseWhenDucked on, audio_session would turn a duck into
      // a pause interruption, which ends the session.
      expect(recitationSessionConfiguration.androidWillPauseWhenDucked, false);
      expect(
        mapAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.duck),
        ),
        isNull,
      );
    });

    test('session configuration is speech over the playback category', () {
      expect(
        recitationSessionConfiguration.avAudioSessionCategory,
        AVAudioSessionCategory.playback,
      );
      expect(
        recitationSessionConfiguration.androidAudioAttributes?.contentType,
        AndroidAudioContentType.speech,
      );
    });
  });
}
