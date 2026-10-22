/// The few platform-player calls the recitation player needs, so the
/// player's sequencing (fades, pause, resume, cancellation) is testable with
/// a fake. [JustAudioBackend] is the real, deliberately thin implementation.
library;

import 'dart:async';
import 'dart:io' show Platform;

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

  /// Playback errors the platform player reports on its own (a file that
  /// cannot be opened or decoded), outside any call. Never swallowed: the
  /// recitation player forwards them so they reach the session status.
  Stream<Object> get errors;

  Future<void> dispose();
}

/// Whether bundled audio is played straight from the APK (Android), with
/// no temporary copy (see [bundledAudioSource]).
final bool playsBundledAssetsInPlace = !kIsWeb && Platform.isAndroid;

/// The URI under which Android's media player reads the bundled Flutter
/// asset [assetPath] directly from the APK: Flutter packs assets under
/// `assets/flutter_assets/` in the APK, and ExoPlayer's DefaultDataSource
/// reads `file:///android_asset/...` URIs with its AssetDataSource.
///
/// Not `asset:///...`: just_audio's Dart side treats the `asset` scheme like
/// [AudioSource.asset] and copies the file into a cache directory first
/// (through path_provider). That copy is exactly what this avoids: it is
/// slow, can leave a truncated file behind, and path_provider_android calls
/// through JNI, which is a risk in shrunk release builds.
Uri androidAssetUri(String assetPath) =>
    Uri(scheme: 'file', path: '/android_asset/flutter_assets/$assetPath');

/// The just_audio source for the bundled asset [assetPath]: read in place
/// on Android ([inPlace], see [androidAssetUri]), or through
/// [AudioSource.asset] (a cached copy) elsewhere.
UriAudioSource bundledAudioSource(String assetPath, {bool inPlace = false}) =>
    inPlace
    ? AudioSource.uri(androidAssetUri(assetPath))
    : AudioSource.asset(assetPath);

Future<void> _pendingCacheClear = Future<void>.value();

/// Deletes just_audio's temporary copies of bundled audio assets.
///
/// just_audio plays an asset by first copying it to
/// `<cacheDir>/just_audio_cache/assets/...`, and reuses an existing copy
/// without checking it. The copy is not written atomically, so a copy cut
/// short (app killed mid-write) would be played truncated forever. Clearing
/// the cache at app start and after each session bounds that to one
/// session. The cache only ever holds bundled audio, never user data
/// (PRIVACY.md). Errors (no cache yet, no platform) are logged and
/// otherwise ignored.
///
/// Only needed where assets are copied: on Android the backend plays them
/// in place ([playsBundledAssetsInPlace]) and nothing calls this.
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

  /// Play bundled assets in place (Android) instead of from cached copies.
  final bool assetsInPlace;
  final AudioPlayer _player;
  final _errors = StreamController<Object>.broadcast();
  StreamSubscription<PlaybackEvent>? _eventSub;

  JustAudioBackend({
    this.silenceAsset = defaultSilenceAsset,
    bool? assetsInPlace,
  }) : assetsInPlace = assetsInPlace ?? playsBundledAssetsInPlace,
       _player = AudioPlayer(
         // The recitation player and the session controller own these.
         handleInterruptions: false,
         handleAudioSessionActivation: false,
         // Local assets only; never start just_audio's localhost proxy.
         useProxyForRequestHeaders: false,
       ) {
    // just_audio reports playback failures as errors on this stream; with
    // no listener they would vanish.
    _eventSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace _) => _report(e),
    );
  }

  void _report(Object e) {
    debugPrint('JustAudioBackend: playback error: $e');
    if (!_errors.isClosed) _errors.add(e);
  }

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Future<void> load(List<TimelineSegment> segments) async {
    if (!assetsInPlace) await _pendingCacheClear;
    final sources = [
      for (final s in segments)
        if (s.isSilence)
          ClippingAudioSource(
            child: bundledAudioSource(silenceAsset, inPlace: assetsInPlace),
            end: s.duration,
          )
        else
          bundledAudioSource(s.clip!.assetPath, inPlace: assetsInPlace),
    ];
    await _player.setAudioSources(
      sources,
      initialIndex: 0,
      initialPosition: Duration.zero,
    );
  }

  @override
  Future<void> play() async {
    // just_audio's play() completes only when playback stops; don't await,
    // but never lose its error.
    unawaited(_player.play().catchError(_report));
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
      await _eventSub?.cancel();
      await _player.dispose();
    } finally {
      await _errors.close();
      // The session is over: drop the temporary asset copies (there are
      // none when assets play in place).
      if (!assetsInPlace) await clearAudioAssetCache();
    }
  }
}
