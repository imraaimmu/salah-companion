import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import '../services/app_services.dart';
import '../theme.dart';
import '../widgets/settings_controls.dart';

/// Settings (#23). Every change is saved at once.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  SessionSettings? _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settings == null) {
      AppServices.of(context).settingsStore.load().then((s) {
        if (mounted) setState(() => _settings = s);
      });
    }
  }

  void _change(SessionSettings s) {
    setState(() => _settings = s);
    AppServices.of(context).settingsStore.save(s);
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final s = _settings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: AppColors.background,
      ),
      body: s == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsetsDirectional.only(bottom: 32),
              children: [
                const QuietNote(privacyLine, icon: Icons.lock_outline),
                const SectionTitle('Surahs'),
                SurahChoice(
                  settings: s,
                  names: services.surahNames,
                  onChanged: _change,
                ),
                const SectionTitle('Opening dua'),
                OpeningDuaChoice(settings: s, onChanged: _change),
                const SectionTitle('Pace'),
                AyahGapSlider(settings: s, onChanged: _change),
                const SectionTitle('Prayer screen'),
                SoftGlowToggle(settings: s, onChanged: _change),
                const SectionTitle('Audio'),
                AudioCheckPanel(audioCheck: services.audioCheck),
                const QuietNote(
                  doNotDisturbNote,
                  icon: Icons.do_not_disturb_on_outlined,
                ),
              ],
            ),
    );
  }
}
