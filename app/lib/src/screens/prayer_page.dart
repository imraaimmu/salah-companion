import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import '../services/app_services.dart';
import '../services/seams.dart';
import '../theme.dart';
import 'summary_page.dart';

/// Prayer (#21): pure black, one tiny dim dot (steady when tracking, amber
/// when lost), no text, no animation except the optional soft glow. Long-
/// press anywhere for 1.5 s to end, after a small confirmation.
///
/// For testing only, [SessionSettings.showTrackingDetails] adds small dim
/// text at the bottom ([SessionDiagnostics.lines] of a runner that is a
/// [SessionDiagnosticsSource]), refreshed at most every
/// [trackingDetailsInterval]. Off (the default), the screen is unchanged.
class PrayerPage extends StatefulWidget {
  final SessionRunner runner;
  final SessionSettings settings;

  /// The prayer being followed (named on the summary only; this screen
  /// shows no text).
  final Prayer prayer;

  const PrayerPage({
    super.key,
    required this.runner,
    this.settings = const SessionSettings(),
    this.prayer = Prayer.fajr,
  });

  static const longPressDuration = Duration(milliseconds: 1500);
  static const dotTracking = Color(0xFF2A2A2A);
  static const dotLost = Color(0xFF5C3F00);
  static const trackingDetailsInterval = Duration(milliseconds: 250);
  static const trackingDetailsColor = Color(0xFF4A4A4A);

  @override
  State<PrayerPage> createState() => _PrayerPageState();
}

class _PrayerPageState extends State<PrayerPage> {
  late final AppServices _services;
  StreamSubscription<SessionStatus>? _sub;
  SessionStatus _status = const SessionStatus();
  bool _finished = false;
  bool _confirming = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sub != null) return;
    _services = AppServices.of(context);
    _services.screenControl.enterPrayerMode();
    _sub = widget.runner.status.listen(_onStatus);
    widget.runner.start();
  }

  void _onStatus(SessionStatus s) {
    if (_finished) return;
    if (s.isOver) {
      _finish(s);
    } else if (s.tracking != _status.tracking) {
      setState(() => _status = s);
    } else {
      _status = s;
    }
  }

  void _finish(SessionStatus s) {
    if (_finished) return;
    _finished = true;
    _sub?.cancel();
    _services.screenControl.exitPrayerMode();
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (_confirming) nav.pop(); // Close the confirmation dialog first.
    nav.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SummaryPage(status: s, prayer: widget.prayer),
      ),
    );
  }

  Future<void> _end() async {
    if (_finished) return;
    await widget.runner.cancel();
    // The runner should have emitted an ended status; make sure we leave.
    if (!_finished && mounted) {
      _finish(
        _status.copyWith(
          ended: EndReason.cancelled,
          interruption: Interruption.userCancelled,
          reciting: false,
        ),
      );
    }
  }

  Future<void> _confirmEnd() async {
    if (_finished || _confirming) return;
    _confirming = true;
    // Dismiss by itself if unanswered, so the screen goes back to black.
    final autoClose = Timer(const Duration(seconds: 10), () {
      if (_confirming && mounted) Navigator.of(context).pop(false);
    });
    final end = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0xCC000000),
      builder: (context) => AlertDialog(
        key: const Key('end-dialog'),
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text(
          'End prayer tracking?',
          style: TextStyle(color: AppColors.textQuiet, fontSize: 18),
        ),
        actions: [
          TextButton(
            key: const Key('end-keep'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep going'),
          ),
          TextButton(
            key: const Key('end-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('End'),
          ),
        ],
      ),
    );
    autoClose.cancel();
    _confirming = false;
    if (end == true) await _end();
  }

  @override
  void dispose() {
    if (!_finished) {
      _finished = true;
      _sub?.cancel();
      widget.runner.cancel();
      _services.screenControl.exitPrayerMode();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tracking = _status.tracking;
    final runner = widget.runner;
    final details =
        widget.settings.showTrackingDetails &&
            runner is SessionDiagnosticsSource
        ? runner as SessionDiagnosticsSource
        : null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // Back ends the session (docs/SPEC.md edge cases).
        if (!didPop) _end();
      },
      child: Semantics(
        label:
            'Prayer in progress. '
            '${tracking ? 'Tracking.' : 'Tracking lost.'} '
            'Long-press anywhere to end.',
        onLongPress: _confirmEnd,
        excludeSemantics: true,
        child: RawGestureDetector(
          key: const Key('prayer-surface'),
          behavior: HitTestBehavior.opaque,
          gestures: {
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    duration: PrayerPage.longPressDuration,
                  ),
                  (r) => r.onLongPress = _confirmEnd,
                ),
          },
          child: ColoredBox(
            color: AppColors.prayerBlack,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.settings.softGlow) const _SoftGlow(),
                if (details != null) _TrackingDetails(source: details),
                Align(
                  alignment: const Alignment(0, 0.85),
                  child: Container(
                    key: const Key('tracking-dot'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: tracking
                          ? PrayerPage.dotTracking
                          : PrayerPage.dotLost,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small dim lines at the bottom of the prayer screen, polled from [source]
/// every [PrayerPage.trackingDetailsInterval] (rebuilt only on change).
class _TrackingDetails extends StatefulWidget {
  final SessionDiagnosticsSource source;
  const _TrackingDetails({required this.source});

  @override
  State<_TrackingDetails> createState() => _TrackingDetailsState();
}

class _TrackingDetailsState extends State<_TrackingDetails> {
  late List<String> _lines = widget.source.diagnostics.lines;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(PrayerPage.trackingDetailsInterval, (_) {
      final next = widget.source.diagnostics.lines;
      if (mounted && !listEquals(next, _lines)) setState(() => _lines = next);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Align(
      alignment: Alignment.bottomLeft,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            _lines.join('\n'),
            key: const Key('tracking-details'),
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              color: PrayerPage.trackingDetailsColor,
              fontSize: 11,
              height: 1.35,
            ),
          ),
        ),
      ),
    ),
  );
}

/// A slow, very dim breathing circle (optional; off by default).
class _SoftGlow extends StatefulWidget {
  const _SoftGlow();

  @override
  State<_SoftGlow> createState() => _SoftGlowState();
}

class _SoftGlowState extends State<_SoftGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: AnimatedBuilder(
        key: const Key('soft-glow-circle'),
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_c.value);
          return Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.accent.withValues(alpha: 0.015 + 0.035 * t),
                  AppColors.accent.withValues(alpha: 0),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}
