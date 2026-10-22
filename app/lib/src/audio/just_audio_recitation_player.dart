/// The recitation player (#16): plays a [RecitationPlan] as one gapless
/// playlist, with fades, blind-spot pause/resume and interruption handling.
library;

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:salah_core/salah_core.dart';

import 'playback_backend.dart';
import 'timeline.dart';

/// Speech content over the playback category: on iOS the silent switch does
/// not mute it; on Android it takes full audio focus as media.
///
/// `speech()` sets `androidWillPauseWhenDucked: true`, which makes
/// audio_session report a transient "can duck" focus loss (a notification
/// chime) as a *pause* interruption, which would end the prayer session.
/// With it off, the chime arrives as a duck event, which [mapAudioInterruption]
/// ignores: recitation keeps playing at its own volume and Android ducks it
/// briefly by itself (automatic ducking, API 26+). A duck never ends or
/// pauses recitation.
final AudioSessionConfiguration recitationSessionConfiguration =
    const AudioSessionConfiguration.speech().copyWith(
      androidWillPauseWhenDucked: false,
    );

/// Maps a system audio interruption to an [Interruption], or null when it
/// does not affect recitation. Any interruption that begins (another app
/// taking audio, an incoming call) stops recitation, as the SPEC requires;
/// a brief "duck" request (a notification sound) is ignored. The platform
/// does not tell calls apart from other audio, so both are
/// [Interruption.audioFocusLost].
Interruption? mapAudioInterruption(AudioInterruptionEvent event) {
  if (!event.begin) return null;
  if (event.type == AudioInterruptionType.duck) return null;
  return Interruption.audioFocusLost;
}

/// System events from [session] as [Interruption]s: headphones unplugged or
/// a Bluetooth device dropping ("becoming noisy"), and audio interruptions.
Stream<Interruption> interruptionsFrom(AudioSession session) {
  StreamSubscription<void>? noisy;
  StreamSubscription<AudioInterruptionEvent>? interrupted;
  late final StreamController<Interruption> out;
  out = StreamController<Interruption>.broadcast(
    onListen: () {
      noisy = session.becomingNoisyEventStream.listen(
        (_) => out.add(Interruption.headphonesUnplugged),
      );
      interrupted = session.interruptionEventStream.listen((e) {
        final i = mapAudioInterruption(e);
        if (i != null) out.add(i);
      });
    },
    onCancel: () {
      noisy?.cancel();
      interrupted?.cancel();
    },
  );
  return out.stream;
}

enum _State { idle, playing, pausing, paused, stopping }

/// [RecitationPlayer] over just_audio.
///
/// The plan becomes one playlist (see [RecitationTimeline]): pre-roll
/// silence, the ayahs with their gaps, and the longer Ameen gap after
/// Al-Fatiha. Audio is never sped up or stretched.
///
/// * [fadeOut] ramps the volume to zero, then stops. It is final.
/// * [pause] remembers where to continue (start of the current ayah, or the
///   same point in a silence) before fading out over 300 ms, then pauses.
/// * [resume] seeks there and fades back in over 300 ms. It also works while
///   the pause fade is still running.
/// * On a system interruption (headphones unplugged, Bluetooth dropped,
///   another app or a call taking audio) the player stops at once, never
///   switching to the speaker, and reports it on [interruptions] for the
///   session controller.
class JustAudioRecitationPlayer implements RecitationPlayer {
  static const fadeDuration = Duration(milliseconds: 300);

  final PlaybackBackend _backend;
  final Future<void> Function(Duration) _wait;
  final Future<bool> Function(bool active)? _setSessionActive;
  final Duration maxSilence;
  final Duration fadeStep;

  final _interruptions = StreamController<Interruption>.broadcast();
  final _problems = StreamController<Object>.broadcast();
  StreamSubscription<void>? _completedSub;
  StreamSubscription<Object>? _errorSub;
  StreamSubscription<Interruption>? _systemSub;

  _State _state = _State.idle;
  int _generation = 0;
  bool _disposed = false;
  Completer<void>? _done;
  RecitationTimeline? _timeline;
  ResumePoint? _resumeAt;

  JustAudioRecitationPlayer({
    required PlaybackBackend backend,
    Stream<Interruption>? systemInterruptions,
    this._setSessionActive,
    Future<void> Function(Duration)? wait,
    this.maxSilence = const Duration(seconds: 10),
    this.fadeStep = const Duration(milliseconds: 20),
  }) : _backend = backend,
       _wait = wait ?? ((d) => Future<void>.delayed(d)) {
    _completedSub = backend.completed.listen((_) {
      if (_state == _State.playing || _state == _State.pausing) {
        ++_generation;
        unawaited(_halt());
      }
    });
    _errorSub = backend.errors.listen((e) {
      if (!_problems.isClosed) _problems.add(e);
    });
    _systemSub = systemInterruptions?.listen(_onInterruption);
  }

  /// The production player: just_audio plus a configured audio session.
  static Future<JustAudioRecitationPlayer> create() async {
    final session = await AudioSession.instance;
    await session.configure(recitationSessionConfiguration);
    return JustAudioRecitationPlayer(
      backend: JustAudioBackend(),
      systemInterruptions: interruptionsFrom(session),
      setSessionActive: (active) => session.setActive(active),
    );
  }

  /// System interruptions, reported after audio has been stopped.
  Stream<Interruption> get interruptions => _interruptions.stream;

  /// Playback errors the platform player reported outside any call (a file
  /// that cannot be opened or decoded). Errors from a call are thrown by
  /// that call instead. The session runner shows both as
  /// `SessionStatus.audioProblem`.
  Stream<Object> get problems => _problems.stream;

  bool get isPlaying => _state == _State.playing;
  bool get isPaused => _state == _State.paused || _state == _State.pausing;

  /// Where [resume] would continue, while paused.
  ResumePoint? get resumePoint => isPaused ? _resumeAt : null;

  @override
  Future<void> play(RecitationPlan plan) async {
    _checkNotDisposed();
    if (_state != _State.idle) await stopNow();
    final timeline = RecitationTimeline.fromPlan(plan, maxSilence: maxSilence);
    if (timeline.isEmpty) return;
    final gen = ++_generation;
    final done = _done = Completer<void>();
    _timeline = timeline;
    _resumeAt = null;
    _state = _State.playing;
    final granted = await _setSessionActive?.call(true) ?? true;
    if (gen != _generation) return done.future;
    if (!granted) {
      // Audio focus was refused (for example during a phone call): never
      // play over it. Stop and report it like a focus loss.
      ++_generation;
      await _halt();
      if (!_interruptions.isClosed) {
        _interruptions.add(Interruption.audioFocusLost);
      }
      return done.future;
    }
    try {
      await _backend.load(timeline.segments);
    } catch (_) {
      // The playlist could not be loaded (a missing or unreadable file):
      // release the audio session and end this play, then report it.
      if (gen == _generation) {
        ++_generation;
        await _halt();
      }
      rethrow;
    }
    if (gen != _generation) return done.future;
    // Through the tracked setter, so a later fade starts from the real
    // volume (after a fadeOut or pause the tracked volume is 0).
    await _setVolumeNow(1);
    if (gen != _generation) return done.future;
    await _backend.play();
    return done.future;
  }

  @override
  Future<void> fadeOut({Duration duration = fadeDuration}) async {
    if (_state == _State.idle || _state == _State.stopping) return;
    final wasAudible = _state == _State.playing || _state == _State.pausing;
    final gen = ++_generation;
    _state = _State.stopping;
    if (wasAudible) {
      await _ramp(_volume, 0, duration, gen);
      if (gen != _generation) return;
    }
    await _halt();
  }

  @override
  Future<void> pause() async {
    if (_state != _State.playing) return;
    _resumeAt = _timeline!.resumePointFor(
      _backend.currentIndex ?? 0,
      _backend.position,
    );
    final gen = ++_generation;
    _state = _State.pausing;
    await _ramp(_volume, 0, fadeDuration, gen);
    if (gen != _generation) return;
    await _backend.pause();
    if (gen != _generation) return;
    _state = _State.paused;
  }

  @override
  Future<void> resume() async {
    if (!isPaused) return;
    final at = _resumeAt!;
    final gen = ++_generation;
    _state = _State.playing;
    await _setVolumeNow(0);
    await _backend.seek(at.index, at.offset);
    if (gen != _generation) return;
    await _backend.play();
    if (gen != _generation) return;
    await _ramp(0, 1, fadeDuration, gen);
  }

  @override
  Future<void> stopNow() async {
    if (_state == _State.idle) return;
    ++_generation;
    await _halt();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _state = _State.idle;
    _complete();
    _completedSub?.cancel();
    _systemSub?.cancel();
    _errorSub?.cancel();
    _interruptions.close();
    _problems.close();
    unawaited(_backend.stop().whenComplete(_backend.dispose));
  }

  double _volume = 1;

  Future<void> _setVolumeNow(double v) async {
    _volume = v;
    await _backend.setVolume(v);
  }

  /// Steps the volume; abandons the ramp as soon as another call takes over.
  Future<void> _ramp(double from, double to, Duration d, int gen) async {
    for (final v in volumeRamp(from, to, d, step: fadeStep)) {
      await _wait(fadeStep);
      if (gen != _generation) return;
      await _setVolumeNow(v);
    }
  }

  /// Stops and completes the current play. Callers bump [_generation]
  /// first. Everything belonging to this play is captured before the first
  /// await: a halt that runs unawaited (natural completion) must not complete
  /// a newer play's future, nor release the audio session after a newer play
  /// has activated it.
  Future<void> _halt() async {
    final gen = _generation;
    final done = _done;
    _done = null;
    _state = _State.idle;
    _timeline = null;
    _resumeAt = null;
    await _backend.stop();
    if (gen == _generation) await _setSessionActive?.call(false);
    if (done != null && !done.isCompleted) done.complete();
  }

  void _complete() {
    final done = _done;
    _done = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> _onInterruption(Interruption i) async {
    await stopNow();
    if (!_interruptions.isClosed) _interruptions.add(i);
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('JustAudioRecitationPlayer was disposed');
  }
}
