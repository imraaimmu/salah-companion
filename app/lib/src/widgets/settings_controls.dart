/// Setting controls shared by first-run setup and the settings screen. Each
/// takes the current [SessionSettings] and reports a changed copy.
library;

import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import '../services/seams.dart';
import '../theme.dart';

typedef SettingsChanged = void Function(SessionSettings settings);

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(16, 24, 16, 8),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class QuietNote extends StatelessWidget {
  final String text;
  final IconData? icon;
  const QuietNote(this.text, {super.key, this.icon});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: AppColors.textQuiet),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: AppColors.textQuiet,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Auto, or a surah for rak'ah 1 and rak'ah 2.
class SurahChoice extends StatelessWidget {
  final SessionSettings settings;
  final SurahNames names;
  final SettingsChanged onChanged;

  const SurahChoice({
    super.key,
    required this.settings,
    required this.names,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final avail = names.available;
    int pick(int v) => avail.contains(v) ? v : avail.first;
    final r1 = pick(settings.surahRakah1);
    final r2 = pick(settings.surahRakah2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RadioGroup<bool>(
          groupValue: settings.autoPairs,
          onChanged: (v) => onChanged(settings.copyWith(autoPairs: v)),
          child: const Column(
            children: [
              RadioListTile<bool>(
                key: Key('surah-auto'),
                value: true,
                title: Text('Auto'),
                subtitle: Text(
                  'A different reviewed pair each day, the same for all of '
                  "that day's prayers",
                ),
              ),
              RadioListTile<bool>(
                key: Key('surah-manual'),
                value: false,
                title: Text('Choose my surahs'),
              ),
            ],
          ),
        ),
        if (!settings.autoPairs) ...[
          _SurahDropdown(
            key: const Key('surah-rakah1'),
            label: "Rak'ah 1",
            value: r1,
            names: names,
            onChanged: (v) =>
                onChanged(settings.copyWith(surahRakah1: v, surahRakah2: r2)),
          ),
          _SurahDropdown(
            key: const Key('surah-rakah2'),
            label: "Rak'ah 2",
            value: r2,
            names: names,
            onChanged: (v) =>
                onChanged(settings.copyWith(surahRakah1: r1, surahRakah2: v)),
          ),
          if (r2 < r1)
            const QuietNote(
              "Usually the surah for rak'ah 2 comes later in the mushaf "
              "than the one for rak'ah 1.",
              icon: Icons.info_outline,
            ),
        ],
      ],
    );
  }
}

class _SurahDropdown extends StatelessWidget {
  final String label;
  final int value;
  final SurahNames names;
  final ValueChanged<int> onChanged;

  const _SurahDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.names,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 8),
    child: DropdownButtonFormField<int>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final s in names.available)
          DropdownMenuItem(value: s, child: Text('${names.nameOf(s)} ($s)')),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    ),
  );
}

/// Pause before Al-Fatiha in rak'ah 1.
class OpeningDuaChoice extends StatelessWidget {
  final SessionSettings settings;
  final SettingsChanged onChanged;

  const OpeningDuaChoice({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  static const options = <(int, String, String)>[
    (0, 'None', 'No pause'),
    (6000, 'Short', 'For Subhanaka, 6 seconds'),
    (18000, 'Long', 'For Wajjahtu, 18 seconds'),
  ];

  @override
  Widget build(BuildContext context) {
    final known = options.any((o) => o.$1 == settings.openingDuaMs);
    return RadioGroup<int>(
      groupValue: known ? settings.openingDuaMs : null,
      onChanged: (v) {
        if (v != null) onChanged(settings.copyWith(openingDuaMs: v));
      },
      child: Column(
        children: [
          for (final (ms, title, sub) in options)
            RadioListTile<int>(
              key: Key('dua-$ms'),
              value: ms,
              title: Text(title),
              subtitle: Text(sub),
            ),
        ],
      ),
    );
  }
}

/// Silence after each ayah, 0 to 3 s in half-second steps.
class AyahGapSlider extends StatelessWidget {
  final SessionSettings settings;
  final SettingsChanged onChanged;

  const AyahGapSlider({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  static String format(int ms) {
    final s = ms / 1000;
    return '${s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toStringAsFixed(1)} s';
  }

  @override
  Widget build(BuildContext context) {
    final ms = settings.ayahGapMs.clamp(0, 3000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Expanded(child: Text('Gap after each ayah')),
              Text(
                format(ms),
                key: const Key('gap-value'),
                style: const TextStyle(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
        Slider(
          key: const Key('gap-slider'),
          value: ms.toDouble(),
          min: 0,
          max: 3000,
          divisions: 6,
          label: format(ms),
          semanticFormatterCallback: (v) =>
              'Gap after each ayah, ${format(v.round())}',
          onChanged: (v) => onChanged(settings.copyWith(ayahGapMs: v.round())),
        ),
        const QuietNote(
          'Time for you to recite along. The recitation itself is never '
          'sped up or slowed down.',
        ),
      ],
    );
  }
}

class SoftGlowToggle extends StatelessWidget {
  final SessionSettings settings;
  final SettingsChanged onChanged;

  const SoftGlowToggle({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const Key('soft-glow'),
    value: settings.softGlow,
    title: const Text('Soft glow'),
    subtitle: const Text(
      'A slow, very dim breathing light during prayer. Off keeps the '
      'screen fully black.',
    ),
    onChanged: (v) => onChanged(settings.copyWith(softGlow: v)),
  );
}

/// Back (default) or front camera. Rear-ultra-wide (not offered here)
/// shows as Back.
class CameraChoice extends StatelessWidget {
  final SessionSettings settings;
  final SettingsChanged onChanged;

  const CameraChoice({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  static const note =
      'The back camera sees better in dim rooms. The front camera lets you '
      'see yourself while placing the phone.';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RadioGroup<CameraLens>(
        groupValue: settings.camera == CameraLens.front
            ? CameraLens.front
            : CameraLens.rear,
        onChanged: (v) {
          if (v != null) onChanged(settings.copyWith(camera: v));
        },
        child: const Column(
          children: [
            RadioListTile<CameraLens>(
              key: Key('camera-rear'),
              value: CameraLens.rear,
              title: Text('Back camera (recommended)'),
            ),
            RadioListTile<CameraLens>(
              key: Key('camera-front'),
              value: CameraLens.front,
              title: Text('Front camera'),
            ),
          ],
        ),
      ),
      const QuietNote(note),
    ],
  );
}

/// Media volume and Bluetooth notes, with a live check.
class AudioCheckPanel extends StatefulWidget {
  final AudioCheck audioCheck;

  /// Reports whether the volume is above zero after each check.
  final ValueChanged<bool>? onResult;

  const AudioCheckPanel({super.key, required this.audioCheck, this.onResult});

  @override
  State<AudioCheckPanel> createState() => _AudioCheckPanelState();
}

class _AudioCheckPanelState extends State<AudioCheckPanel> {
  AudioStatus? _status;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final s = await widget.audioCheck.check();
    if (!mounted) return;
    setState(() => _status = s);
    widget.onResult?.call(s.volumeAboveZero);
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s == null)
          const QuietNote('Checking audio...')
        else ...[
          Semantics(
            liveRegion: true,
            child: QuietNote(
              s.volumeAboveZero
                  ? 'Media volume is on.'
                  : 'Media volume is at zero. Turn it up to continue.',
              icon: s.volumeAboveZero
                  ? Icons.volume_up_outlined
                  : Icons.volume_off_outlined,
            ),
          ),
          if (s.bluetooth)
            const QuietNote(
              'Bluetooth audio is connected. Its delay can push the '
              'recitation past the moment you bow. The phone speaker is '
              'better.',
              icon: Icons.bluetooth_audio,
            ),
        ],
        const QuietNote(
          'Set the media volume now. The app never changes it during '
          'prayer.',
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: TextButton.icon(
              key: const Key('audio-recheck'),
              onPressed: _run,
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
          ),
        ),
      ],
    );
  }
}

/// Settings, "Show tracking details during prayer (for testing)".
class TrackingDetailsToggle extends StatelessWidget {
  final SessionSettings settings;
  final SettingsChanged onChanged;

  const TrackingDetailsToggle({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const Key('tracking-details'),
    value: settings.showTrackingDetails,
    title: const Text('Show tracking details during prayer (for testing)'),
    subtitle: const Text(
      'Small dim text at the bottom of the prayer screen: posture, prayer '
      'state, whether the takbir was seen and the last audio event. Off '
      'keeps the screen fully black.',
    ),
    onChanged: (v) => onChanged(settings.copyWith(showTrackingDetails: v)),
  );
}

/// Settings, "Test sound": plays Al-Fatiha ayah 1 through the recitation
/// player for a few seconds, and checks the media volume.
class SoundTestPanel extends StatefulWidget {
  final SoundTest soundTest;
  final AudioCheck audioCheck;

  const SoundTestPanel({
    super.key,
    required this.soundTest,
    required this.audioCheck,
  });

  static const playing = 'Playing…';
  static const heardTone = 'You should hear a tone (placeholder audio).';
  static const heardRecitation = 'You should hear the start of Al-Fatiha.';
  static const volumeZero =
      'Media volume is at zero, so nothing can be heard. Turn it up.';

  @override
  State<SoundTestPanel> createState() => _SoundTestPanelState();
}

class _SoundTestPanelState extends State<SoundTestPanel> {
  bool _playing = false;
  String? _result;
  bool _failed = false;
  bool _volumeZero = false;

  Future<void> _run() async {
    if (_playing) return;
    setState(() {
      _playing = true;
      _result = null;
      _failed = false;
    });
    var volumeZero = false;
    try {
      volumeZero = !(await widget.audioCheck.check()).volumeAboveZero;
    } catch (_) {
      // The volume check is a hint only.
    }
    if (mounted) setState(() => _volumeZero = volumeZero);
    String? problem;
    try {
      problem = await widget.soundTest.run();
    } catch (e) {
      problem = '$e';
    }
    if (!mounted) return;
    setState(() {
      _playing = false;
      _failed = problem != null;
      _result =
          problem ??
          (widget.soundTest.placeholder
              ? SoundTestPanel.heardTone
              : SoundTestPanel.heardRecitation);
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: TextButton.icon(
              key: const Key('test-sound'),
              onPressed: _playing ? null : _run,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Test sound'),
            ),
          ),
        ),
        Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_playing)
                const QuietNote(
                  SoundTestPanel.playing,
                  key: Key('test-sound-status'),
                )
              else if (result != null)
                QuietNote(
                  _failed ? 'No sound: $result' : result,
                  key: const Key('test-sound-status'),
                  icon: _failed
                      ? Icons.error_outline
                      : Icons.volume_up_outlined,
                ),
              if (_volumeZero)
                const QuietNote(
                  SoundTestPanel.volumeZero,
                  key: Key('test-sound-volume'),
                  icon: Icons.volume_off_outlined,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

const doNotDisturbNote =
    'Tip: turn on Do Not Disturb before you pray. On Android choose '
    '"Priority only" and allow media, so the recitation still plays.';

const privacyLine = 'No video is recorded. Nothing leaves your phone.';
