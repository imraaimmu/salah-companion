import 'dart:async';

import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import '../prayer_time.dart';
import '../services/app_services.dart';
import '../theme.dart';
import 'placement_page.dart';
import 'settings_page.dart';

/// Home (#19): one large round "Start Dhuhr" (etc.) button, a row of the five
/// prayer names under it (the selected one highlighted; one tap switches),
/// a small settings icon, a small practice icon and one quiet line with
/// today's surahs.
///
/// The selected prayer is guessed from the phone's clock ([guessPrayer]); a
/// manual pick is kept in memory until the clock enters another prayer's
/// window ([PrayerSelection]).
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  SessionSettings? _settings;
  bool _starting = false;
  PrayerSelection _selection = const PrayerSelection();
  late Prayer _prayer;

  /// The calendar day the surah line was built for ([SessionSettings.dayKey]).
  late String _day;
  Timer? _tick;
  AppLifecycleListener? _lifecycle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settings == null) {
      _prayer = _selection.resolve(_now());
      _day = SessionSettings.dayKey(_now());
      _reload();
      // Follow the clock while Home stays open or comes back to the front.
      _tick ??= Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
      _lifecycle ??= AppLifecycleListener(onResume: _refresh);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  DateTime _now() => AppServices.of(context).clock();

  /// Follows the clock: the prayer guess, and today's surah line (the Auto
  /// pair moves on after midnight).
  void _refresh() {
    if (!mounted) return;
    final now = _now();
    final p = _selection.resolve(now);
    final day = SessionSettings.dayKey(now);
    if (p != _prayer || day != _day) {
      setState(() {
        _prayer = p;
        _day = day;
      });
    }
  }

  void _pick(Prayer p) {
    setState(() {
      _selection = PrayerSelection.pick(p, _now());
      _prayer = p;
    });
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
      final prayer = _prayer; // What the button says is what starts.
      // Today's Auto pair; saved only after a completed prayer.
      final settings = (await services.settingsStore.load()).forDay(
        services.clock(),
      );
      final audio = await services.audioCheck.check();
      if (!mounted) return;
      if (!audio.volumeAboveZero) {
        _say('Turn the media volume up to start.');
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlacementPage(settings: settings, prayer: prayer),
        ),
      );
      if (mounted) {
        _refresh();
        await _reload();
      }
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
    final (a, b) = services.todaysSurahs(s.forDay(services.clock()));
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
                      label:
                          'Start ${_prayer.displayName} prayer, '
                          "${_prayer.rakahCount} rak'ahs",
                      excludeSemantics: true,
                      onTap: _start,
                      child: SizedBox.square(
                        dimension: 200,
                        child: ElevatedButton(
                          key: const Key('start-prayer'),
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
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Start ${_prayer.displayName}',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _PrayerRow(selected: _prayer, onPick: _pick),
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

/// The five prayer names in a quiet row; the selected one is highlighted.
class _PrayerRow extends StatelessWidget {
  final Prayer selected;
  final ValueChanged<Prayer> onPick;
  const _PrayerRow({required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        children: [
          for (final p in Prayer.values)
            Semantics(
              button: true,
              selected: p == selected,
              label: p.displayName,
              excludeSemantics: true,
              onTap: () => onPick(p),
              child: TextButton(
                key: Key('prayer-${p.name}'),
                onPressed: () => onPick(p),
                style: TextButton.styleFrom(
                  foregroundColor: p == selected
                      ? AppColors.accent
                      : AppColors.textQuiet,
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(
                  p.displayName,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: p == selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                    decoration: p == selected
                        ? TextDecoration.underline
                        : TextDecoration.none,
                    decorationColor: AppColors.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
