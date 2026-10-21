import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'seams.dart';

/// Keeps the screen on (wakelock_plus) and dims this app's window
/// (screen_brightness; app-level only, never the system setting).
class DeviceScreenControl implements ScreenControl {
  /// Application brightness during prayer (0..1).
  final double prayerBrightness;

  const DeviceScreenControl({this.prayerBrightness = 0.01});

  @override
  Future<void> enterPrayerMode() async {
    await _guard(WakelockPlus.enable);
    await _guard(
      () => ScreenBrightness.instance.setApplicationScreenBrightness(
        prayerBrightness,
      ),
    );
  }

  @override
  Future<void> exitPrayerMode() async {
    await _guard(WakelockPlus.disable);
    await _guard(ScreenBrightness.instance.resetApplicationScreenBrightness);
  }

  /// A missing plugin (desktop demo, tests) must never break the prayer.
  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('ScreenControl: $e');
    }
  }
}
