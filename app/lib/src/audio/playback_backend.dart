/// The few platform-player calls the recitation player needs, so the
/// player's sequencing (fades, pause, resume, cancellation) is testable with
/// a fake. [JustAudioBackend] is the real, deliberately thin implementation.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'timeline.dart';

abstract interface class PlaybackBackend {
  /// Replaces the playlist with [segments], positioned at the start, paused.
  Future<void> load(List<TimelineSegment> segments);

  /// Starts or continues playback. Returns once playback has been requested
  /// (it does not wait for the end).
  Future<void> play();
  Future<void> pause();

  /// Stops playback and releases the playlist.
  Future<void> stop();
  Future<void> seek(int index, Duration offset);
  Future<void> setVolume(double volume);

  /// Current playlist index, or null when nothing is loaded.
  int? get currentIndex;

  /// Position within the current playlist entry.
  Duration get position;

  /// Fires when the last playlist entry finishes.
  Stream<void> get completed;

  Future<void> dispose();
}

Future<void> _pendingCacheClear = Future<void>.value();

/// Deletes just_audio's temporary copies of bundled audio assets.
///
/// just_audio plays an asset by first copying it to
/// `<cacheDir>/just_audio_cache/assets/...`, and reuses an existing copy
/// without checking it. The copy is not written atomically, so a copy cut
/// short (app killed mid-write) would be played truncated forever. Clearing
/// the cache at app start and after each session bounds that to one
/// session. The cache only ever holds bundled audio, never user data
/// (PRIVACY.md). Errors (no cache yet, no platform) are ignored.
///
/// [JustAudioBackend.load] waits for a clear still in progress, so a new
/// session never reads a file that is being deleted.
Future<void> clearAudioAssetCache({
  Future<void> Function() clear = AudioPlayer.clearAssetCache,
}) {
  final run = _pendingCacheClear.then((_) async {
    try {
      await clear();
    } catch (e) {
      debugPrint('clearAudioAssetCache: $e');
    }
  });
  _pendingCacheClear = run;
  return run;
}

/// [PlaybackBackend] over just_audio. Silences are clips of a bundled
/// silent WAV ([silenceAsset], at least as long as the timeline's
/// `maxSilence`), which works on Android and iOS alike.
class JustAudioBackend implements PlaybackBackend {
  static const defaultSilenceAsset = 'assets/audio/silence_10s.wav';

  final String silenceAsset;
  final AudioPlayer _player;

  JustAudioBackend({this.silenceAsset = defaultSilenceAsset})
    : _player = AudioPlayer(
        // The recitation player and the session controller own these.
        handleInterruptions: false,
        handleAudioSessionActivation: false,
        // Local assets only; never start just_audio's localhost proxy.
        useProxyForRequestHeaders: false,
      );

  @override
  Future<void> load(List<TimelineSegment> segments) async {
    await _pendingCacheClear;
    final sources = [
      for (final s in segments)
        if (s.isSilence)
          ClippingAudioSource(
            child: AudioSource.asset(silenceAsset),
            end: s.duration,
          )
        else
          AudioSource.asset(s.clip!.assetPath),
    ];
    await _player.setAudioSources(
      sources,
      initialIndex: 0,
      initialPosition: Duration.zero,
    );
  }

  @override
  Future<void> play() async {
    // just_audio's play() completes only when playback stops; don't await.
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(int index, Duration offset) =>
      _player.seek(offset, index: index);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  int? get currentIndex => _player.currentIndex;

  @override
  Duration get position => _player.position;

  @override
  Stream<void> get completed => _player.processingStateStream.where(
    (s) => s == ProcessingState.completed,
  );

  @override
  Future<void> dispose() async {
    try {
      await _player.dispose();
    } finally {
      // The session is over: drop the temporary asset copies.
      await clearAudioAssetCache();
    }
  }
}
