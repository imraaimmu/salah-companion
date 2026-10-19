import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import '../services/app_services.dart';
import '../theme.dart';
import 'placement_page.dart';
import 'settings_page.dart';

/// Home (#19): one large round Start Fajr button, a small settings icon, a
/// small practice icon and one quiet line with today's surahs.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  SessionSettings? _settings;
  bool _starting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settings == null) _reload();
  }

  Future<void> _reload() async {
    final s = await AppServices.of(context).settingsStore.load();
    if (mounted) setState(() => _settings = s);
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _start() async {
    if (_starting) return; // Only one session runs.
    _starting = true;
    try {
      final services = AppServices.of(context);
      final settings = await services.settingsStore.load();
      final audio = await services.audioCheck.check();
      if (!mounted) return;
      if (!audio.volumeAboveZero) {
        _say('Turn the media volume up to start.');
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlacementPage(settings: settings),
        ),
      );
      if (mounted) await _reload();
    } finally {
      _starting = false;
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
    if (mounted) await _reload();
  }

  String? _todayLine() {
    final s = _settings;
    if (s == null) return null;
    final services = AppServices.of(context);
    final (a, b) = services.todaysSurahs(s);
    return '${services.surahNames.nameOf(a)} · ${services.surahNames.nameOf(b)}';
  }

  @override
  Widget build(BuildContext context) {
    final today = _todayLine();
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Align(
              alignment: AlignmentDirectional.topEnd,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Practice',
                      icon: const Icon(Icons.menu_book_outlined),
                      color: AppColors.textQuiet,
                      onPressed: () => _say('Practice mode is coming soon.'),
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.settings_outlined),
                      color: AppColors.textQuiet,
                      onPressed: _openSettings,
                    ),
                  ],
                ),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      button: true,
                      label: 'Start Fajr prayer',
                      excludeSemantics: true,
                      onTap: _start,
                      child: SizedBox.square(
                        dimension: 200,
                        child: ElevatedButton(
                          key: const Key('start-fajr'),
                          style: ElevatedButton.styleFrom(
                            shape: const CircleBorder(),
                            backgroundColor: AppColors.surface,
                            foregroundColor: AppColors.accent,
                            side: const BorderSide(
                              color: AppColors.accent,
                              width: 1.5,
                            ),
                            padding: const EdgeInsets.all(24),
                          ),
                          onPressed: _start,
                          child: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Start Fajr',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsetsDirectional.symmetric(
                        horizontal: 24,
                      ),
                      child: Semantics(
                        label: today == null ? null : "Today's surahs: $today",
                        excludeSemantics: true,
                        child: Text(
                          today ?? '',
                          key: const Key('todays-surahs'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textQuiet,
                            fontSize: 15,
                          ),
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
    );
  }
}
