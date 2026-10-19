import 'dart:async';

import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import '../services/app_services.dart';
import '../theme.dart';

/// Summary: one line and one Done button; returns home by itself after 30 s.
class SummaryPage extends StatefulWidget {
  final SessionStatus status;
  const SummaryPage({super.key, required this.status});

  /// Title and an optional quiet second line for how the session ended.
  static (String, String?) messageFor(SessionStatus s) {
    if (s.interruption == Interruption.cameraUnavailable) {
      return ('Camera unavailable', 'The session ended.');
    }
    switch (s.ended) {
      case EndReason.completed:
        return ("Fajr completed · 2 rak'ahs", null);
      case EndReason.cameraLost:
        return (
          'Prayer tracking stopped',
          'The phone lost sight of you, so it stayed silent.',
        );
      case EndReason.timeout:
        return ('Session ended', 'Nothing changed for a while.');
      case EndReason.cancelled:
      case null:
        return switch (s.interruption) {
          Interruption.phoneCall => ('Session ended', 'A call came in.'),
          Interruption.appBackgrounded => (
            'Session ended',
            'The app was closed.',
          ),
          Interruption.headphonesUnplugged || Interruption.audioFocusLost => (
            'Session ended',
            'The audio was interrupted.',
          ),
          Interruption.lowFrameRate => (
            'Prayer tracking stopped',
            'The room may be too dark.',
          ),
          _ => ('Session ended', null),
        };
    }
  }

  @override
  State<SummaryPage> createState() => _SummaryPageState();
}

class _SummaryPageState extends State<SummaryPage> {
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer ??= Timer(AppServices.of(context).summaryTimeout, _done);
  }

  void _done() {
    _timer?.cancel();
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (title, detail) = SummaryPage.messageFor(widget.status);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  liveRegion: true,
                  child: Text(
                    title,
                    key: const Key('summary-title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textQuiet,
                      fontSize: 15,
                    ),
                  ),
                ],
                const SizedBox(height: 40),
                FilledButton(
                  key: const Key('summary-done'),
                  onPressed: _done,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                    child: Text('Done', style: TextStyle(fontSize: 17)),
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
