import 'package:flutter/widgets.dart';

import 'seams.dart';

/// Bundles one implementation of every seam and provides it to the tree.
class AppServices extends InheritedWidget {
  final SettingsStore settingsStore;
  final SurahNames surahNames;
  final TodaysSurahs todaysSurahs;
  final SessionRunnerFactory sessionRunnerFactory;
  final PlacementCheckFactory placementCheckFactory;
  final Prompter prompter;
  final AudioCheck audioCheck;
  final CameraPermission cameraPermission;
  final ScreenControl screenControl;

  /// Settings, "Test sound".
  final SoundTest soundTest;

  /// Placement countdown length (spec: 5 s).
  final Duration countdown;

  /// Summary screen returns home by itself after this long (spec: 30 s).
  final Duration summaryTimeout;

  /// The phone's clock (for the prayer guess and the daily Auto pair).
  final DateTime Function() clock;

  const AppServices({
    super.key,
    required this.settingsStore,
    required this.surahNames,
    required this.todaysSurahs,
    required this.sessionRunnerFactory,
    required this.placementCheckFactory,
    required this.prompter,
    required this.audioCheck,
    required this.cameraPermission,
    required this.screenControl,
    this.soundTest = const UnavailableSoundTest(),
    this.countdown = const Duration(seconds: 5),
    this.summaryTimeout = const Duration(seconds: 30),
    this.clock = DateTime.now,
    required super.child,
  });

  static AppServices of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<AppServices>();
    assert(s != null, 'No AppServices above this widget');
    return s!;
  }

  @override
  bool updateShouldNotify(AppServices old) => false;
}
