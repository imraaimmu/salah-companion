/// Settings, "Test sound": the recitation player's real path, briefly.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:salah_core/salah_core.dart';

import 'pose_session_runner.dart' show PlayerFactory, PlayerHandle;
import 'seams.dart';

/// Plays Al-Fatiha ayah 1 for up to [length] through a player from
/// [createPlayer]: in production the same factory the prayer session uses
/// (just_audio backend, configured audio session). Any error thrown by the
/// player, any problem it reports, and any interruption during the test is
/// returned in words.
class RecitationSoundTest implements SoundTest {
  final PlayerFactory createPlayer;

  /// The clip to play (Al-Fatiha 1:1 from the catalog), or null if the
  /// catalog lacks it.
  final AyahClip? clip;

  @override
  final bool placeholder;

  /// How long the sample plays at most (it stops earlier if the clip ends).
  final Duration length;

  RecitationSoundTest({
    required this.createPlayer,
    required this.clip,
    required this.placeholder,
    this.length = const Duration(seconds: 4),
  });

  /// The test for [catalog]'s Al-Fatiha 1:1.
  factory RecitationSoundTest.fromCatalog({
    required PlayerFactory createPlayer,
    required AudioCatalog catalog,
    required bool placeholder,
  }) {
    final e = catalog.entry(fatiha, 1);
    return RecitationSoundTest(
      createPlayer: createPlayer,
      placeholder: placeholder,
      clip: e == null
          ? null
          : AyahClip(
              assetPath: e.assetPath,
              surah: fatiha,
              ayah: 1,
              duration: e.duration,
            ),
    );
  }

  bool _running = false;

  @override
  Future<String?> run() async {
    final c = clip;
    if (c == null) return 'Al-Fatiha ayah 1 is missing from the audio files.';
    if (_running) return null;
    _running = true;
    final problems = <String>[];
    void note(Object e) {
      debugPrint('Sound test: $e');
      problems.add(describeAudioProblem(e));
    }

    PlayerHandle? handle;
    final subs = <StreamSubscription<Object?>>[];
    try {
      handle = await createPlayer();
      subs.add(
        handle.interruptions.listen(
          (i) => note('Audio was stopped by the phone (${i.name}).'),
        ),
      );
      final p = handle.problems;
      if (p != null) subs.add(p.listen(note));
      final player = handle.player;
      final played = player.play(
        RecitationPlan(
          clips: [c],
          preRoll: Duration.zero,
          gapAfterAyah: Duration.zero,
          gapAfterFatiha: Duration.zero,
        ),
      );
      var ended = false;
      final done = played.then<void>(
        (_) => ended = true,
        onError: (Object e) {
          ended = true;
          note(e);
        },
      );
      await Future.any([done, Future<void>.delayed(length)]);
      if (!ended) await player.fadeOut();
      await done.timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (e) {
      note(
        handle == null
            ? 'Could not start the audio player: '
                  '${describeAudioProblem(e)}'
            : e,
      );
    } finally {
      // Not awaited: nothing depends on it, and some streams complete
      // their cancel future outside the caller's zone.
      for (final s in subs) {
        unawaited(s.cancel());
      }
      try {
        handle?.player.dispose();
      } catch (e) {
        debugPrint('Sound test: disposing the player: $e');
      }
      _running = false;
    }
    return problems.isEmpty ? null : problems.first;
  }
}
