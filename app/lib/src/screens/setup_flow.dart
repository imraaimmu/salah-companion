import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import '../services/app_services.dart';
import '../theme.dart';
import '../widgets/settings_controls.dart';
import 'home_page.dart';

/// First-run setup (#23), shown once. Settings are saved after every step,
/// and setup is marked done on the last one.
class SetupFlow extends StatefulWidget {
  final SessionSettings initial;
  const SetupFlow({super.key, this.initial = const SessionSettings()});

  @override
  State<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends State<SetupFlow> {
  static const _stepCount = 7;
  late SessionSettings _settings = widget.initial;
  int _step = 0;
  bool? _cameraGranted;
  bool _volumeOk = true;

  void _change(SessionSettings s) => setState(() => _settings = s);

  Future<void> _next() async {
    final services = AppServices.of(context);
    // Saving must never stop the user moving on.
    try {
      await services.settingsStore.save(_settings);
    } catch (_) {}
    if (!mounted) return;
    if (_step < _stepCount - 1) {
      setState(() => _step++);
      return;
    }
    try {
      await services.settingsStore.markSetupDone();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const HomePage()),
    );
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  Future<void> _requestCamera() async {
    final granted = await AppServices.of(context).cameraPermission.request();
    if (mounted) setState(() => _cameraGranted = granted);
  }

  Widget _page(String title, List<Widget> children) => ListView(
    key: ValueKey('setup-step-$_step'),
    padding: const EdgeInsetsDirectional.only(top: 24, bottom: 24),
    children: [
      Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
        child: Semantics(
          header: true,
          child: Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      ...children,
    ],
  );

  Widget _body(BuildContext context) {
    final services = AppServices.of(context);
    switch (_step) {
      case 0:
        return _page('Assalamu alaikum', const [
          QuietNote(
            'Salah Companion is a companion while you learn your surahs. '
            'It works for all five daily prayers: Fajr, Dhuhr, Asr, Maghrib '
            "and Isha. In each rak'ah it recites Al-Fatiha, followed by a "
            "short surah in the first two rak'ahs, and you recite along "
            'with it.',
          ),
          QuietNote(
            'Before you start, Home shows which prayer it will follow, '
            'guessed from the time of day. Tap another prayer name to '
            'change it.',
          ),
          QuietNote(
            'It watches your posture to know when to recite and when to '
            'stay silent. You never need to touch the phone while you '
            'pray.',
          ),
          QuietNote(
            'Practise your surahs outside prayer too, so that one day you '
            'no longer need it.',
          ),
        ]);
      case 1:
        return _page('Camera', [
          const QuietNote(
            'The camera lets the app see when you stand, bow and '
            'prostrate.',
            icon: Icons.photo_camera_outlined,
          ),
          const QuietNote(
            'Every frame is processed on this phone and dropped at once. '
            'No video is recorded. Nothing leaves your phone.',
            icon: Icons.lock_outline,
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonal(
                key: const Key('allow-camera'),
                onPressed: _cameraGranted == true ? null : _requestCamera,
                child: Text(
                  _cameraGranted == true ? 'Camera allowed' : 'Allow camera',
                ),
              ),
            ),
          ),
          if (_cameraGranted == false)
            const QuietNote(
              'Camera not allowed. You can allow it later in your phone '
              'settings; the app needs it to follow your prayer.',
            ),
          const QuietNote(
            doNotDisturbNote,
            icon: Icons.do_not_disturb_on_outlined,
          ),
        ]);
      case 2:
        return _page('Surahs', [
          const QuietNote(
            'Al-Fatiha is always recited first. Choose the surah that '
            "follows it in the first two rak'ahs; in rak'ahs 3 and 4 only "
            'Al-Fatiha is recited.',
          ),
          SurahChoice(
            settings: _settings,
            names: services.surahNames,
            onChanged: _change,
          ),
        ]);
      case 3:
        return _page('Opening dua', [
          const QuietNote(
            "A pause before Al-Fatiha in the first rak'ah, for your "
            'opening dua.',
          ),
          OpeningDuaChoice(settings: _settings, onChanged: _change),
        ]);
      case 4:
        return _page('Pace', [
          AyahGapSlider(settings: _settings, onChanged: _change),
          const SizedBox(height: 8),
          SoftGlowToggle(settings: _settings, onChanged: _change),
        ]);
      case 5:
        return _page('Audio check', [
          AudioCheckPanel(
            audioCheck: services.audioCheck,
            onResult: (ok) => setState(() => _volumeOk = ok),
          ),
        ]);
      default:
        return _page('Placing the phone', const [
          QuietNote(
            'Stand the phone in portrait, level, at about hip height.',
            icon: Icons.stay_current_portrait,
          ),
          QuietNote(
            'Put it 2 to 3 metres away at your left or right, not in front '
            'of you: you face the qibla and the phone sees you from the side, '
            'with space ahead of you for sujood.',
            icon: Icons.straighten,
          ),
          QuietNote(
            'The back camera works best, especially in a dim room. On the '
            'placement screen you can switch to the front camera to see '
            'yourself; either way the phone must see your whole body, head '
            'to feet.',
            icon: Icons.flip_camera_android_outlined,
          ),
          QuietNote(
            'When you tap Start, the app checks the view and tells '
            'you out loud if the phone needs to move. Once it passes, a '
            '5-second countdown gives you time to step onto your mat.',
            icon: Icons.record_voice_over_outlined,
          ),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _step == _stepCount - 1;
    final canContinue = _step != 5 || _volumeOk;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Semantics(
              label: 'Step ${_step + 1} of $_stepCount',
              child: LinearProgressIndicator(
                value: (_step + 1) / _stepCount,
                minHeight: 2,
                backgroundColor: AppColors.surface,
              ),
            ),
            Expanded(child: _body(context)),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 16),
              child: Row(
                children: [
                  if (_step > 0)
                    TextButton(
                      key: const Key('setup-back'),
                      onPressed: _back,
                      child: const Text('Back'),
                    ),
                  const Spacer(),
                  FilledButton(
                    key: const Key('setup-next'),
                    onPressed: canContinue ? _next : null,
                    child: Text(last ? 'Done' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
