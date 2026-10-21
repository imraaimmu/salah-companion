import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salah_companion/src/pose/pose_wire.dart';
import 'package:salah_core/salah_core.dart';

import 'wire_fixtures.dart';

void main() {
  group('golden vectors shared with PoseWireTest.kt', () {
    test('golden heartbeat', () {
      final e = PoseWireDecoder.decode(
        Float32List.fromList([1, 7, 1, 3000, 480, 640, 0, 0]),
      ) as PoseWireFrame;
      expect(e.token, 7);
      expect(e.isHeartbeat, isTrue);
      expect(e.frame.tMs, 68536);
      expect(e.frame.imageW, 480);
      expect(e.frame.imageH, 640);
      expect(e.frame.landmarks, isNull);
      expect(e.frame.people, isEmpty);
      expect(e.frame.hasPerson, isFalse);
    });

    test('golden frame', () {
      // person[i] = i ~/ 4 + (i % 4) * 0.25, as in the Kotlin test.
      final p = [
        for (var i = 0; i < PoseWire.personFloats; i++)
          (i ~/ 4) + (i % 4) * 0.25,
      ];
      final d = Float32List.fromList([0, 3, 0, 1234, 480, 640, -1.5, 1, ...p]);
      final e = PoseWireDecoder.decode(d) as PoseWireFrame;
      expect(e.token, 3);
      expect(e.isHeartbeat, isFalse);
      expect(e.frame.tMs, 1234);
      expect(e.frame.tiltDeg, -1.5);
      final s = e.frame.landmarks![LandmarkIndex.leftShoulder];
      expect([s.x, s.y, s.z, s.conf], [11, 11.25, 11.5, 11.75]);
    });
  });

  test('one person fills landmarks and people', () {
    final e = PoseWireDecoder.decodeFloats(
      frameBuffer(tMs: 66, tilt: 2.5, people: [person(10)]),
    );
    final f = e.frame;
    expect(f.tMs, 66);
    expect(f.tiltDeg, 2.5);
    expect(f.people, hasLength(1));
    expect(f.landmarks, same(f.people.first));
    expect(f.landmarks, hasLength(33));
    final ankle = f.landmarks![LandmarkIndex.rightAnkle];
    expect(ankle.x, 38);
    expect(ankle.y, 66);
    expect(ankle.z, closeTo(-0.28, 1e-6));
    expect(ankle.conf, closeTo(0.9, 1e-6));
  });

  test('several people: all in people, landmarks null', () {
    final e = PoseWireDecoder.decodeFloats(
      frameBuffer(people: [person(0), person(100), person(200, conf: 0.3)]),
    );
    expect(e.frame.people, hasLength(3));
    expect(e.frame.landmarks, isNull);
    expect(e.frame.hasPerson, isTrue);
    expect(e.frame.people[1][0].x, 100);
    expect(e.frame.people[2][5].conf, closeTo(0.3, 1e-6));
  });

  test('camera frame with nobody is a frame, not a heartbeat', () {
    final e = PoseWireDecoder.decodeFloats(frameBuffer(tMs: 500));
    expect(e.isHeartbeat, isFalse);
    expect(e.frame.people, isEmpty);
    expect(e.frame.landmarks, isNull);
    expect(e.frame.hasPerson, isFalse);
  });

  test('long sessions keep exact milliseconds', () {
    const t = 4 * 3600 * 1000 + 123; // beyond float32 exact range as one value
    expect(PoseWireDecoder.decodeFloats(frameBuffer(tMs: t)).frame.tMs, t);
  });

  group('malformed buffers', () {
    test('too short', () {
      expect(
        () => PoseWireDecoder.decode(Float32List(5)),
        throwsFormatException,
      );
    });
    test('length does not match person count', () {
      final d = frameBuffer(people: [person(0)]);
      expect(
        () =>
            PoseWireDecoder.decode(Float32List.sublistView(d, 0, d.length - 1)),
        throwsFormatException,
      );
      d[7] = 2;
      expect(() => PoseWireDecoder.decode(d), throwsFormatException);
    });
    test('too many people', () {
      final d = frameBuffer();
      d[7] = 4;
      expect(() => PoseWireDecoder.decode(d), throwsFormatException);
    });
    test('unknown kind', () {
      expect(
        () => PoseWireDecoder.decode(frameBuffer(kind: 5)),
        throwsFormatException,
      );
    });
    test('heartbeat with people', () {
      expect(
        () => PoseWireDecoder.decode(frameBuffer(kind: 1, people: [person(0)])),
        throwsFormatException,
      );
    });
    test('non-integer header field', () {
      final d = frameBuffer();
      d[3] = 1.5;
      expect(() => PoseWireDecoder.decode(d), throwsFormatException);
    });
    test('wrong type', () {
      expect(() => PoseWireDecoder.decode('frame'), throwsFormatException);
      expect(
        () => PoseWireDecoder.decode({'event': 'error'}),
        throwsFormatException,
      );
    });
  });

  group('map events', () {
    test('errors map to interruptions', () {
      for (final code in [
        'permissionDenied',
        'cameraInUse',
        'cameraDisabled',
        'cameraFatal',
        'noCamera',
        'engineInit',
        'engineError',
      ]) {
        final e = PoseWireDecoder.decode({
          'event': 'error',
          'token': 2,
          'code': code,
          'message': 'm',
        }) as PoseWireError;
        expect(e.token, 2);
        expect(e.error.code, code);
        expect(e.error.interruption, Interruption.cameraUnavailable);
      }
      final paused = PoseWireDecoder.decode({
        'event': 'error',
        'token': 2,
        'code': 'paused',
      }) as PoseWireError;
      expect(paused.error.interruption, Interruption.appBackgrounded);
    });

    test('info events keep their data', () {
      final e = PoseWireDecoder.decode({
        'event': 'started',
        'token': 4,
        'lens': 'rear',
        'fpsRange': '15-15',
      }) as PoseWireInfo;
      expect(e.event, 'started');
      expect(e.data['fpsRange'], '15-15');
    });
  });
}
