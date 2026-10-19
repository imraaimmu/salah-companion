/// Fake seam implementations, driven by hand. Used by widget tests and as
/// building blocks of the demo mode.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:salah_core/salah_core.dart';

import 'latest_value.dart';
import 'seams.dart';

export 'latest_value.dart';

/// A session whose statuses the test pushes with [emit].
class FakeSessionRunner implements SessionRunner {
  final SessionSettings settings;
  final _status = LatestValue<SessionStatus>();
  int startCalls = 0;
  int cancelCalls = 0;

  FakeSessionRunner([this.settings = const SessionSettings()]) {
    _status.add(const SessionStatus());
  }

  SessionStatus get current => _status.latest!;

  void emit(SessionStatus status) => _status.add(status);

  @override
  Stream<SessionStatus> get status => _status.stream;

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (!current.isOver) {
      emit(
        current.copyWith(
          ended: EndReason.cancelled,
          interruption: Interruption.userCancelled,
          reciting: false,
        ),
      );
    }
  }
}

/// A placement check whose states the test pushes with [emit].
class FakePlacementCheck implements PlacementCheck {
  final _state = LatestValue<PlacementState>();
  int startCalls = 0;
  int stopCalls = 0;

  FakePlacementCheck() {
    _state.add(const PlacementState());
  }

  void emit(PlacementState s) => _state.add(s);

  @override
  Stream<PlacementState> get state => _state.stream;

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Widget? buildPreview(BuildContext context) => null;
}

/// The 15 pilot surahs (docs/SPEC.md section 7). Fallback until the content
/// repository (#17) supplies names from its manifest.
class PilotSurahNames implements SurahNames {
  const PilotSurahNames();

  static const names = <int, String>{
    93: 'Ad-Duha',
    94: 'Ash-Sharh',
    95: 'At-Tin',
    97: 'Al-Qadr',
    102: 'At-Takathur',
    103: "Al-'Asr",
    105: 'Al-Fil',
    106: 'Quraysh',
    107: "Al-Ma'un",
    108: 'Al-Kawthar',
    109: 'Al-Kafirun',
    110: 'An-Nasr',
    112: 'Al-Ikhlas',
    113: 'Al-Falaq',
    114: 'An-Nas',
  };

  @override
  List<int> get available => names.keys.toList();

  @override
  String nameOf(int surah) => names[surah] ?? 'Surah $surah';
}

/// Draft Auto pairs from the spec (pending religious review). Fallback until
/// `RecitationPlanner.surahsFor` is wired in.
(int, int) draftTodaysSurahs(SessionSettings s) {
  const pairs = [
    (93, 94),
    (102, 103),
    (105, 106),
    (107, 108),
    (109, 112),
    (110, 112),
  ];
  if (!s.autoPairs) return (s.surahRakah1, s.surahRakah2);
  return pairs[s.autoIndex % pairs.length];
}

class SilentPrompter implements Prompter {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text) async => spoken.add(text);
}

class FakeAudioCheck implements AudioCheck {
  AudioStatus status;
  FakeAudioCheck([this.status = const AudioStatus()]);

  @override
  Future<AudioStatus> check() async => status;
}

class FakeCameraPermission implements CameraPermission {
  bool granted;
  bool grantOnRequest;
  int requests = 0;
  FakeCameraPermission({this.granted = false, this.grantOnRequest = true});

  @override
  Future<bool> isGranted() async => granted;

  @override
  Future<bool> request() async {
    requests++;
    granted = grantOnRequest;
    return granted;
  }
}

class FakeScreenControl implements ScreenControl {
  bool inPrayerMode = false;

  @override
  Future<void> enterPrayerMode() async => inPrayerMode = true;

  @override
  Future<void> exitPrayerMode() async => inPrayerMode = false;
}

/// A person standing side-on in a 480 x 640 frame, for overlays and demos.
List<Landmark> standingSkeleton({double conf = 0.9}) {
  final pts = List<Landmark>.filled(
    LandmarkIndex.count,
    Landmark(240, 300, 0, conf * 0.5),
  );
  void set(int i, double x, double y) => pts[i] = Landmark(x, y, 0, conf);
  set(LandmarkIndex.nose, 262, 118);
  set(LandmarkIndex.leftEye, 256, 110);
  set(LandmarkIndex.rightEye, 256, 110);
  set(LandmarkIndex.leftEar, 236, 116);
  set(LandmarkIndex.rightEar, 236, 116);
  set(LandmarkIndex.leftShoulder, 238, 182);
  set(LandmarkIndex.rightShoulder, 240, 182);
  set(LandmarkIndex.leftElbow, 244, 262);
  set(LandmarkIndex.rightElbow, 246, 262);
  set(LandmarkIndex.leftWrist, 252, 330);
  set(LandmarkIndex.rightWrist, 254, 330);
  set(LandmarkIndex.leftHip, 236, 344);
  set(LandmarkIndex.rightHip, 238, 344);
  set(LandmarkIndex.leftKnee, 242, 448);
  set(LandmarkIndex.rightKnee, 244, 448);
  set(LandmarkIndex.leftAnkle, 236, 548);
  set(LandmarkIndex.rightAnkle, 238, 548);
  set(LandmarkIndex.leftHeel, 226, 560);
  set(LandmarkIndex.rightHeel, 228, 560);
  set(LandmarkIndex.leftFootIndex, 266, 564);
  set(LandmarkIndex.rightFootIndex, 268, 564);
  return pts;
}
