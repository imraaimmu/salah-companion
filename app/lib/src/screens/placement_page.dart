import 'dart:async';

import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import '../services/app_services.dart';
import '../services/seams.dart';
import '../theme.dart';
import '../widgets/skeleton_painter.dart';
import 'prayer_page.dart';

/// Placement (#20): full-screen camera preview with the skeleton, the
/// chosen prayer at the top ("Dhuhr · 4 rak'ahs"), one status line and the
/// four checks. When all pass, a 5-second countdown starts by
/// itself; if any check fails during it, the countdown is cancelled.
///
/// A small flip button switches between the back and front camera live:
/// the camera and preview restart, the checks start over, and the choice is
/// saved as [SessionSettings.camera] (the session then opens the same
/// camera). The skeleton is mirrored for display only while the front camera
/// is active, to line up with its mirrored preview.
class PlacementPage extends StatefulWidget {
  final SessionSettings settings;

  /// The prayer chosen on Home. Shown at the top and named in the spoken
  /// countdown, because the session follows it blindly.
  final Prayer prayer;

  const PlacementPage({
    super.key,
    this.settings = const SessionSettings(),
    this.prayer = Prayer.fajr,
  });

  /// The title, e.g. "Dhuhr · 4 rak'ahs".
  static String titleFor(Prayer p) =>
      "${p.displayName} · ${p.rakahCount} rak'ahs";

  /// Shown once all checks pass: rak'ah 1 recites only after a detected
  /// takbir hand raise.
  static const takbirHint =
      'Raise your hands clearly for the takbir so the recitation can start';

  /// The spoken countdown prompt, naming the prayer.
  static String countdownPrompt(Prayer p, int secs) =>
      'Good. Step onto your mat for ${p.displayName}, '
      "${p.rakahCount} rak'ahs. Starting in $secs seconds.";

  /// Prompt for the first failing check, used when the check gives none.
  static String messageFor(PlacementState s) {
    if (!s.bodyVisible) return 'Stand side-on where the phone can see you';
    if (!s.confidenceOk) return s.message ?? 'Move the phone back';
    if (!s.fpsOk) return s.message ?? 'Turn on a light';
    if (!s.floorSpaceOk) {
      return s.message ?? 'Step back a little so sujood fits in view';
    }
    return 'Looks good';
  }

  @override
  State<PlacementPage> createState() => _PlacementPageState();
}

class _PlacementPageState extends State<PlacementPage> {
  late final AppServices _services;
  late final PlacementCheck _check;
  StreamSubscription<PlacementState>? _sub;
  PlacementState _state = const PlacementState();
  Timer? _timer;
  int? _remaining;
  String? _lastSpoken;
  bool _stopped = false;
  bool _leaving = false;
  bool _switching = false;

  /// The camera requested for this placement and the session after it.
  late CameraLens _lens = widget.settings.camera;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sub != null) return;
    _services = AppServices.of(context);
    _check = _services.placementCheckFactory();
    _sub = _check.state.listen(_onState);
    _check.start(lens: _lens);
  }

  /// Back <-> front, from the camera actually active (a phone without the
  /// requested camera falls back to the other one).
  Future<void> _switchCamera() async {
    if (_switching || _leaving) return;
    _switching = true;
    final next = _state.lens == CameraLens.front
        ? CameraLens.rear
        : CameraLens.front;
    setState(() => _lens = next);
    _cancelCountdown();
    try {
      final store = _services.settingsStore;
      // Save only the camera on top of what is stored, so nothing else in
      // the settings this screen was given (e.g. the day's Auto pair) is
      // written early.
      unawaited(
        store
            .load()
            .then((s) => store.save(s.copyWith(camera: next)))
            .catchError((Object e) => debugPrint('Camera not saved: $e')),
      );
      await _check.switchLens(next);
    } finally {
      _switching = false;
    }
  }

  String get _message {
    if (_remaining != null) return 'Step onto your mat · $_remaining';
    return _state.message ?? PlacementPage.messageFor(_state);
  }

  void _speak(String text) {
    if (text == _lastSpoken) return;
    _lastSpoken = text;
    _services.prompter.speak(text);
  }

  void _onState(PlacementState s) {
    if (_leaving) return;
    setState(() => _state = s);
    if (s.allPass) {
      if (_timer == null) _startCountdown();
    } else {
      _cancelCountdown();
      _speak(s.message ?? PlacementPage.messageFor(s));
    }
  }

  void _startCountdown() {
    final secs = _services.countdown.inSeconds;
    setState(() => _remaining = secs);
    _speak(PlacementPage.countdownPrompt(widget.prayer, secs));
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = (_remaining ?? 1) - 1;
      if (left <= 0) {
        t.cancel();
        _go();
      } else {
        setState(() => _remaining = left);
      }
    });
  }

  void _cancelCountdown() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    setState(() => _remaining = null);
  }

  Future<void> _stopCheck() async {
    if (_stopped) return;
    _stopped = true;
    unawaited(_sub?.cancel());
    await _check.stop();
  }

  Future<void> _go() async {
    if (_leaving) return;
    _leaving = true;
    await _stopCheck();
    if (!mounted) return;
    final settings = widget.settings.copyWith(camera: _lens);
    final runner = _services.sessionRunnerFactory(settings, widget.prayer);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => PrayerPage(
          runner: runner,
          settings: settings,
          prayer: widget.prayer,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopCheck();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _check.buildPreview(context);
    return Scaffold(
      backgroundColor: AppColors.prayerBlack,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(child: preview ?? const _PreviewPlaceholder()),
          ExcludeSemantics(
            child: CustomPaint(
              key: const Key('skeleton-overlay'),
              painter: SkeletonPainter(
                points: _state.skeleton,
                imageW: _state.imageW,
                imageH: _state.imageH,
                mirror: _state.lens == CameraLens.front,
              ),
            ),
          ),
          if (_remaining != null)
            Center(
              child: ExcludeSemantics(
                child: Text(
                  '$_remaining',
                  key: const Key('countdown'),
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 96,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
            ),
          Align(
            alignment: Alignment.topCenter,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0x00000000), Color(0xCC000000)],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Cancel',
                        icon: const Icon(Icons.close),
                        color: AppColors.textPrimary,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            PlacementPage.titleFor(widget.prayer),
                            key: const Key('placement-title'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.accent,
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      // Same width as Cancel, so the title stays centred.
                      IconButton(
                        key: const Key('switch-camera'),
                        tooltip: 'Switch camera',
                        icon: const Icon(Icons.flip_camera_android_outlined),
                        color: AppColors.textQuiet,
                        onPressed: _switchCamera,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _StatusPanel(message: _message, state: _state),
          ),
        ],
      ),
    );
  }
}

class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    key: Key('preview-placeholder'),
    color: Color(0xFF05070C),
    child: Center(
      child: Icon(Icons.videocam_outlined, size: 48, color: Color(0xFF1E2636)),
    ),
  );
}

class _StatusPanel extends StatelessWidget {
  final String message;
  final PlacementState state;
  const _StatusPanel({required this.message, required this.state});

  @override
  Widget build(BuildContext context) {
    final checks = <(bool, String, Key)>[
      (state.bodyVisible, 'Whole body in view', const Key('check-body')),
      (
        state.confidenceOk,
        'Shoulder, hip, knee and ankle clear',
        const Key('check-confidence'),
      ),
      (state.fpsOk, 'Enough light', const Key('check-fps')),
      (state.floorSpaceOk, 'Space for sujood', const Key('check-floor')),
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xE6000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(24, 48, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  key: const Key('placement-status'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (state.allPass) ...[
                const SizedBox(height: 8),
                const Text(
                  PlacementPage.takbirHint,
                  key: Key('takbir-hint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textQuiet, fontSize: 14),
                ),
              ],
              const SizedBox(height: 16),
              for (final (ok, label, key) in checks)
                Semantics(
                  key: key,
                  label: '$label: ${ok ? 'passed' : 'not yet'}',
                  checked: ok,
                  excludeSemantics: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(
                          ok
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 18,
                          color: ok ? AppColors.accent : AppColors.textQuiet,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            label,
                            style: TextStyle(
                              color: ok
                                  ? AppColors.textPrimary
                                  : AppColors.textQuiet,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
