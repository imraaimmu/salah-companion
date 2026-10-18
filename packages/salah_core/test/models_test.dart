import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

void main() {
  test('heartbeat frames carry no person', () {
    const frame = PoseFrame.heartbeat(1200);
    expect(frame.hasPerson, isFalse);
    expect(frame.tMs, 1200);
  });

  test('unknown reading has zero confidence and no takbir', () {
    const reading = PostureReading.unknown(500);
    expect(reading.posture, Posture.unknown);
    expect(reading.confidence, 0);
    expect(reading.takbirRaise, isFalse);
  });

  test('copyWith keeps measurements', () {
    const reading = PostureReading(
      tMs: 10,
      posture: Posture.standing,
      confidence: 0.9,
      hipHeightRatio: 1.0,
      torsoAngleDeg: 5,
    );
    final changed = reading.copyWith(posture: Posture.bowing);
    expect(changed.posture, Posture.bowing);
    expect(changed.hipHeightRatio, 1.0);
    expect(changed.torsoAngleDeg, 5);
  });

  test('landmark index covers 33 points', () {
    expect(LandmarkIndex.count, 33);
    expect(LandmarkIndex.rightFootIndex, 32);
  });

  test('default camera config matches the spec', () {
    const config = CameraConfig();
    expect(config.fps, 15);
    expect(config.lens, CameraLens.rear);
  });

  test('events carry their timestamps', () {
    const PrayerEvent event = StartRecitation(3000, rakah: 1);
    expect(event.tMs, 3000);
    final description = switch (event) {
      StartRecitation(:final rakah) => 'start $rakah',
      StopRecitation() => 'stop',
      StateChanged() => 'state',
      TrackingLost() => 'lost',
      TrackingRestored() => 'restored',
      SessionEnded() => 'ended',
    };
    expect(description, 'start 1');
  });
}
