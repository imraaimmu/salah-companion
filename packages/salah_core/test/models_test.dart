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
      PauseRecitation(:final rakah) => 'pause $rakah',
      ResumeRecitation(:final rakah) => 'resume $rakah',
      StateChanged() => 'state',
      TrackingLost() => 'lost',
      TrackingRestored() => 'restored',
      SessionEnded() => 'ended',
    };
    expect(description, 'start 1');
  });

  test('events compare by value', () {
    expect(const StartRecitation(10, rakah: 1),
        const StartRecitation(10, rakah: 1));
    expect(
        const StartRecitation(10, rakah: 1) ==
            const StartRecitation(10, rakah: 2),
        isFalse);
    expect(const StopRecitation(5) == const TrackingLost(5), isFalse);
    expect(
        const PauseRecitation(7, rakah: 2), const PauseRecitation(7, rakah: 2));
    expect(const ResumeRecitation(7, rakah: 2),
        const ResumeRecitation(7, rakah: 2));
    expect(
        const PauseRecitation(7, rakah: 2) ==
            const ResumeRecitation(7, rakah: 2),
        isFalse);
    expect(
        const ResumeRecitation(7, rakah: 1) ==
            const ResumeRecitation(7, rakah: 2),
        isFalse);
    expect(
      [
        const StateChanged(1,
            from: PrayerState.waiting, to: PrayerState.takbir, rakah: 1)
      ],
      [
        const StateChanged(1,
            from: PrayerState.waiting, to: PrayerState.takbir, rakah: 1)
      ],
    );
  });

  test('readings compare by value and copy confidence', () {
    const a = PostureReading(tMs: 1, posture: Posture.sitting, confidence: 0.8);
    expect(
        a,
        const PostureReading(
            tMs: 1, posture: Posture.sitting, confidence: 0.8));
    expect(a.copyWith(confidence: 0.5).confidence, 0.5);
    expect(a.copyWith(tMs: 9).tMs, 9);
  });

  test('a frame with several people has a person but no single landmark list',
      () {
    final person = List.filled(LandmarkIndex.count, const Landmark(0, 0, 0, 1));
    final frame = PoseFrame(
        tMs: 0,
        landmarks: null,
        people: [person, person],
        imageW: 480,
        imageH: 640);
    expect(frame.hasPerson, isTrue);
    expect(frame.landmarks, isNull);
  });

  group('SessionSettings', () {
    test('JSON round trip keeps every field, including autoPairDate', () {
      const s = SessionSettings(
        surahRakah1: 109,
        surahRakah2: 112,
        autoPairs: false,
        autoIndex: 5,
        autoPairDate: '2026-10-20',
        openingDuaMs: 18000,
        rakah2PreRollMs: 1000,
        ayahGapMs: 2500,
        ameenGapMs: 800,
        softGlow: true,
        camera: CameraLens.front,
        showTrackingDetails: true,
      );
      final again = SessionSettings.fromJson(s.toJson());
      expect(again.showTrackingDetails, isTrue);
      expect(again.toJson(), s.toJson());
      expect(again.autoPairDate, '2026-10-20');
      expect(again.camera, CameraLens.front);
      expect(s.toJson()['camera'], 'front');
    });

    test('camera defaults to rear; old or unknown values read as rear', () {
      expect(const SessionSettings().camera, CameraLens.rear);
      expect(const SessionSettings().toJson()['camera'], 'rear');
      expect(SessionSettings.fromJson(const {}).camera, CameraLens.rear);
      for (final v in [null, 'back', 'FRONT', 3, true]) {
        expect(SessionSettings.fromJson({'camera': v}).camera, CameraLens.rear,
            reason: '$v');
      }
      expect(SessionSettings.fromJson(const {'camera': 'rear'}).camera,
          CameraLens.rear);
      expect(SessionSettings.fromJson(const {'camera': 'front'}).camera,
          CameraLens.front);
    });

    test('copyWith keeps or changes the camera; cameraConfig carries it', () {
      const s = SessionSettings(camera: CameraLens.front, ayahGapMs: 500);
      expect(s.copyWith(ayahGapMs: 1000).camera, CameraLens.front);
      expect(s.copyWith(camera: CameraLens.rear).camera, CameraLens.rear);
      expect(s.cameraConfig.lens, CameraLens.front);
      expect(const SessionSettings().cameraConfig.lens, CameraLens.rear);
      // forDay keeps the camera choice.
      expect(s.forDay(DateTime(2026, 10, 21)).camera, CameraLens.front);
    });

    test('old JSON without autoPairDate still reads', () {
      final s = SessionSettings.fromJson({
        'surahRakah1': 93,
        'surahRakah2': 94,
        'autoPairs': true,
        'autoIndex': 7,
        'openingDuaMs': 6000,
        'rakah2PreRollMs': 1500,
        'ayahGapMs': 2000,
        'ameenGapMs': 1500,
        'softGlow': false,
      });
      expect(s.autoIndex, 7);
      expect(s.ayahGapMs, 2000);
      expect(s.autoPairDate, isNull);
      expect(s.toJson().containsKey('autoPairDate'), isFalse);
      expect(s.camera, CameraLens.rear);
      expect(s.showTrackingDetails, isFalse);
    });

    test('showTrackingDetails defaults to off; copyWith changes it', () {
      expect(const SessionSettings().showTrackingDetails, isFalse);
      expect(const SessionSettings().toJson()['showTrackingDetails'], false);
      expect(
          SessionSettings.fromJson(const {'showTrackingDetails': 'yes'})
              .showTrackingDetails,
          isFalse);
      final on = const SessionSettings().copyWith(showTrackingDetails: true);
      expect(on.showTrackingDetails, isTrue);
      expect(on.copyWith(ayahGapMs: 0).showTrackingDetails, isTrue);
      expect(on.forDay(DateTime(2026, 10, 21)).showTrackingDetails, isTrue);
    });

    test('an invalid autoPairDate reads as null', () {
      for (final v in [5, '20-10-2026', '', 'yesterday', null]) {
        expect(
            SessionSettings.fromJson({'autoPairDate': v}).autoPairDate, isNull,
            reason: '$v');
      }
    });

    test('dayKey pads month and day', () {
      expect(
          SessionSettings.dayKey(DateTime(2026, 3, 7, 23, 59)), '2026-03-07');
    });

    test('forDay: Auto pair moves on once per calendar day', () {
      final mon = DateTime(2026, 10, 19, 5, 10);
      final monNight = DateTime(2026, 10, 19, 23, 59);
      final tue = DateTime(2026, 10, 20, 0, 1);
      const fresh = SessionSettings(autoIndex: 2);
      final first = fresh.forDay(mon);
      expect((first.autoIndex, first.autoPairDate), (2, '2026-10-19'));
      expect(identical(first.forDay(monNight), first), isTrue);
      final next = first.forDay(tue);
      expect((next.autoIndex, next.autoPairDate), (3, '2026-10-20'));
      expect(next.forDay(tue).autoIndex, 3);
      // Days without a completed prayer never skip a pair.
      final later = first.forDay(DateTime(2026, 10, 25));
      expect(later.autoIndex, 3);
    });

    test('forDay: a clock set back never advances the pair', () {
      const saved = SessionSettings(autoIndex: 5, autoPairDate: '2026-10-20');
      // An earlier day (clock set back, or a time-zone change): unchanged.
      for (final day in [
        DateTime(2026, 10, 19, 23, 0),
        DateTime(2025, 12, 31),
        DateTime(2026, 9, 30),
      ]) {
        expect(identical(saved.forDay(day), saved), isTrue, reason: '$day');
      }
      // Back on the saved day, still the same; the next day moves on once.
      expect(identical(saved.forDay(DateTime(2026, 10, 20, 9)), saved), isTrue);
      final next = saved.forDay(DateTime(2026, 10, 21, 0, 5));
      expect((next.autoIndex, next.autoPairDate), (6, '2026-10-21'));
      // Across a year and a month boundary, string order is calendar order.
      const dec = SessionSettings(autoIndex: 1, autoPairDate: '2026-12-31');
      expect(dec.forDay(DateTime(2027, 1, 1)).autoIndex, 2);
      const sep = SessionSettings(autoIndex: 1, autoPairDate: '2026-09-30');
      expect(sep.forDay(DateTime(2026, 10, 1)).autoIndex, 2);
    });

    test('forDay leaves manual choices alone', () {
      const manual = SessionSettings(autoPairs: false, autoIndex: 2);
      expect(identical(manual.forDay(DateTime(2026, 10, 20)), manual), isTrue);
    });
  });
}
