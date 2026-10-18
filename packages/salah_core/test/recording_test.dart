import 'dart:convert';
import 'dart:io';

import 'package:salah_core/salah_core.dart';
import 'package:test/test.dart';

const header = RecordingHeader(
  engine: 'mediapipe-pose-landmarker',
  model: 'lite',
  fps: 15,
  orientation: 'portrait',
  side: 'left',
  device: 'Pixel 6a',
  imageW: 480,
  imageH: 640,
);

List<Landmark> person([double dx = 0]) => [
      for (var i = 0; i < 33; i++)
        Landmark(100.25 + i + dx, 200.5 + i * 3, -0.125 * i, 0.9),
    ];

Recording sampleRecording() => Recording(header: header, frames: [
      PoseFrame(
          tMs: 0,
          landmarks: person(),
          people: [person()],
          imageW: 480,
          imageH: 640),
      PoseFrame(
          tMs: 67,
          landmarks: person(1),
          people: [person(1)],
          imageW: 480,
          imageH: 640,
          tiltDeg: -1.5),
      const PoseFrame(tMs: 100, landmarks: null, imageW: 480, imageH: 640),
      PoseFrame(
          tMs: 133,
          landmarks: null,
          people: [person(), person(50)],
          imageW: 480,
          imageH: 640),
    ]);

const labels = LabelSet(
  recording: 'fajr-001.recording.ndjson',
  intervals: [
    LabelInterval(
        startMs: 0,
        endMs: 1000,
        posture: Posture.standing,
        state: PrayerState.waiting,
        rakah: 0),
    LabelInterval(
        startMs: 1000,
        endMs: 2000,
        posture: Posture.standing,
        state: PrayerState.takbir,
        rakah: 0),
    LabelInterval(
        startMs: 2000,
        endMs: 9000,
        posture: Posture.standing,
        state: PrayerState.qiyam1,
        rakah: 1),
    LabelInterval(
        startMs: 9500,
        endMs: 12000,
        posture: Posture.bowing,
        state: PrayerState.ruku1,
        rakah: 1),
  ],
  takbirTimesMs: [1000, 9200, 20000],
);

String headerLine([Map<String, Object?> overrides = const {}]) =>
    jsonEncode({...header.toJson(), ...overrides});

String landmarksJson(int n, {String value = '[1.0,2.0,0.0,0.5]'}) =>
    '[${List.filled(n, value).join(',')}]';

String frameLine(int t, {String? people, String extra = ''}) =>
    '{"t":$t,"people":${people ?? '[${landmarksJson(33)}]'}$extra}';

String rec(List<String> frames, {String? head}) =>
    '${[head ?? headerLine(), ...frames].join('\n')}\n';

const labelsHeader =
    '{"format":"salah-labels","version":1,"recording":"x.recording.ndjson"}';

String lab(List<String> lines, {String head = labelsHeader}) =>
    '${[head, ...lines].join('\n')}\n';

String interval(int start, int end,
        {String posture = 'standing',
        String state = 'qiyam1',
        int rakah = 1}) =>
    '{"type":"interval","startMs":$start,"endMs":$end,'
    '"posture":"$posture","state":"$state","rakah":$rakah}';

Matcher hasError(int line, String fragment) => contains(isA<FormatError>()
    .having((e) => e.line, 'line', line)
    .having((e) => e.message, 'message', contains(fragment)));

void main() {
  group('recording round trip', () {
    test('encode -> decode -> encode is exact', () {
      final text = encodeRecording(sampleRecording());
      expect(validateRecording(text), isEmpty);
      expect(encodeRecording(decodeRecording(text)), text);
    });

    test('decoded frames carry header, tilt and people', () {
      final r = decodeRecording(encodeRecording(sampleRecording()));
      expect(r.header.toJson(), header.toJson());
      expect(r.frames.map((f) => f.tMs), [0, 67, 100, 133]);

      final f0 = r.frames[0];
      expect(f0.people, hasLength(1));
      expect(f0.landmarks, same(f0.people.single));
      expect(f0.landmarks![5].x, 105.25);
      expect(f0.landmarks![5].conf, 0.9);
      expect(f0.imageW, 480);
      expect(f0.imageH, 640);
      expect(f0.tiltDeg, 0);

      expect(r.frames[1].tiltDeg, -1.5);
      expect(r.frames[2].people, isEmpty);
      expect(r.frames[2].landmarks, isNull);
      expect(r.frames[2].hasPerson, isFalse);
      expect(r.frames[3].people, hasLength(2));
      expect(r.frames[3].landmarks, isNull);
    });

    test('tilt omitted when 0 and defaults to 0', () {
      final text = encodeRecording(sampleRecording());
      final lines = const LineSplitter().convert(text);
      expect(lines[1], isNot(contains('tilt')));
      expect(lines[2], contains('"tilt":-1.5'));
    });

    test('landmarks without people are written as one person', () {
      final r = Recording(header: header, frames: [
        PoseFrame(tMs: 5, landmarks: person(), imageW: 480, imageH: 640),
      ]);
      final back = decodeRecording(encodeRecording(r));
      expect(back.frames.single.people, hasLength(1));
    });

    test('integer coordinates decode as doubles and re-encode stably', () {
      final text = rec(
          [frameLine(0, people: '[${landmarksJson(33, value: '[1,2,0,1]')}]')]);
      final once = encodeRecording(decodeRecording(text));
      expect(encodeRecording(decodeRecording(once)), once);
      expect(decodeRecording(text).frames.single.landmarks!.first.x, 1.0);
    });

    test('CRLF and missing trailing newline are accepted', () {
      final text = [headerLine(), frameLine(0), frameLine(10)].join('\r\n');
      expect(validateRecording(text), isEmpty);
      expect(decodeRecording(text).frames, hasLength(2));
    });

    test('header-only recording is valid', () {
      expect(decodeRecording('${headerLine()}\n').frames, isEmpty);
    });

    test('RecordingHeader.fromJson rejects bad headers', () {
      expect(RecordingHeader.fromJson(header.toJson()).fps, 15);
      expect(() => RecordingHeader.fromJson({...header.toJson(), 'fps': 0}),
          throwsA(isA<FormatError>()));
    });

    test('encode rejects non-finite numbers and wrong landmark counts', () {
      final bad = [...person()]..[3] = const Landmark(double.nan, 0, 0, 1);
      expect(
          () => encodeRecording(Recording(header: header, frames: [
                PoseFrame(tMs: 0, landmarks: bad, imageW: 1, imageH: 1),
              ])),
          throwsArgumentError);
      expect(
          () => encodeRecording(Recording(header: header, frames: [
                PoseFrame(
                    tMs: 0,
                    landmarks: null,
                    people: [person().sublist(1)],
                    imageW: 1,
                    imageH: 1),
              ])),
          throwsArgumentError);
      expect(
          () => encodeRecording(Recording(header: header, frames: [
                const PoseFrame(
                    tMs: 0,
                    landmarks: null,
                    imageW: 1,
                    imageH: 1,
                    tiltDeg: double.infinity),
              ])),
          throwsArgumentError);
    });
  });

  group('recording validation', () {
    test('empty file', () {
      expect(validateRecording(''), hasError(1, 'missing header'));
    });

    test('bad JSON on a frame line, other lines still checked', () {
      final errors = validateRecording(rec([
        '{"t":0,',
        frameLine(10, people: '[${landmarksJson(32)}]'),
      ]));
      expect(errors, hasLength(2));
      expect(errors, hasError(2, 'invalid JSON'));
      expect(errors, hasError(3, '32 landmarks'));
    });

    test('non-object line and empty line', () {
      final errors = validateRecording(rec(['[1,2]', '', frameLine(0)]));
      expect(errors, hasError(2, 'expected a JSON object'));
      expect(errors, hasError(3, 'empty line'));
    });

    test('wrong format name', () {
      expect(validateRecording(rec([], head: headerLine({'format': 'other'}))),
          hasError(1, '"format"'));
    });

    test('wrong version', () {
      expect(validateRecording(rec([], head: headerLine({'version': 2}))),
          hasError(1, '"version"'));
    });

    test('missing header fields', () {
      final json = header.toJson()
        ..remove('engine')
        ..remove('imageH');
      final errors = validateRecording(rec([], head: jsonEncode(json)));
      expect(errors, hasError(1, 'missing field "engine"'));
      expect(errors, hasError(1, 'missing field "imageH"'));
    });

    test('wrong header types and values', () {
      final errors = validateRecording(rec([],
          head: headerLine({
            'fps': 15.5,
            'orientation': 'sideways',
            'side': 'front',
            'device': 7,
            'imageW': 0,
          })));
      expect(errors, hasError(1, '"fps" must be an integer'));
      expect(errors, hasError(1, '"orientation" has unknown value'));
      expect(errors, hasError(1, '"side" has unknown value'));
      expect(errors, hasError(1, '"device" must be a string'));
      expect(errors, hasError(1, '"imageW" must be >= 1'));
    });

    test('frame missing fields', () {
      final errors = validateRecording(rec(['{"people":[]}', '{"t":5}']));
      expect(errors, hasError(2, 'missing field "t"'));
      expect(errors, hasError(3, 'missing field "people"'));
    });

    test('negative and non-integer t', () {
      final errors = validateRecording(rec([
        frameLine(-1),
        '{"t":2.5,"people":[]}',
      ]));
      expect(errors, hasError(2, '"t" must be >= 0'));
      expect(errors, hasError(3, '"t" must be an integer'));
    });

    test('non-increasing t', () {
      final errors =
          validateRecording(rec([frameLine(10), frameLine(10), frameLine(5)]));
      expect(errors, hasLength(2));
      expect(errors, hasError(3, 'strictly increasing'));
      expect(errors, hasError(4, 'must not decrease'));
    });

    test('equal t is allowed when one of the frames has no people', () {
      final ok = rec([
        frameLine(0),
        frameLine(100, people: '[]'), // heartbeat
        frameLine(100), // camera frame in the same millisecond
        frameLine(200),
        frameLine(200, people: '[]'),
        frameLine(300, people: '[]'),
        frameLine(300, people: '[]'),
      ]);
      expect(validateRecording(ok), isEmpty);
      expect(decodeRecording(ok).frames.map((f) => f.tMs),
          [0, 100, 100, 200, 200, 300, 300]);
    });

    test('equal t between two frames with people is rejected', () {
      // Even with a heartbeat in between.
      final errors = validateRecording(rec([
        frameLine(100),
        frameLine(100, people: '[]'),
        frameLine(100),
        frameLine(150, people: '[]'),
        frameLine(140, people: '[]'),
      ]));
      expect(errors, hasLength(2));
      expect(errors, hasError(4, 'strictly increasing between frames'));
      expect(errors, hasError(6, 'must not decrease'));
    });

    test('wrong landmark count and landmark shape', () {
      final errors = validateRecording(rec([
        frameLine(0, people: '[${landmarksJson(34)}]'),
        frameLine(1, people: '[${landmarksJson(33, value: '[1,2,3]')}]'),
        frameLine(2, people: '[{"x":1}]'),
        frameLine(3, people: '{}'),
      ]));
      expect(errors, hasError(2, '34 landmarks'));
      expect(errors, hasError(3, 'must be [x, y, z, conf]'));
      expect(errors, hasError(4, 'person 0 must be an array'));
      expect(errors, hasError(5, '"people" must be an array'));
    });

    test('non-numeric, infinite and out-of-range values', () {
      final errors = validateRecording(rec([
        frameLine(0, people: '[${landmarksJson(33, value: '[1,"2",0,1]')}]'),
        frameLine(1, people: '[${landmarksJson(33, value: '[1e999,2,0,1]')}]'),
        frameLine(2, people: '[${landmarksJson(33, value: '[1,2,0,1.5]')}]'),
        frameLine(3, extra: ',"tilt":-1e999'),
        frameLine(4, extra: ',"tilt":"flat"'),
        '{"t":1e999,"people":[]}',
      ]));
      expect(errors, hasError(2, 'is not a number'));
      expect(errors, hasError(3, 'not a finite number'));
      expect(errors, hasError(4, 'outside 0..1'));
      expect(errors, hasError(5, '"tilt" is not a finite number'));
      expect(errors, hasError(6, '"tilt" must be a number'));
      expect(errors, hasError(7, '"t" is not a finite number'));
    });

    test('NaN literal is invalid JSON', () {
      expect(
          validateRecording(rec([
            frameLine(0, people: '[${landmarksJson(33, value: '[NaN,2,0,1]')}]')
          ])),
          hasError(2, 'invalid JSON'));
    });

    test('decode throws the first error', () {
      expect(
          () => decodeRecording(rec([frameLine(5), frameLine(4), '{'])),
          throwsA(isA<FormatError>()
              .having((e) => e.line, 'line', 3)
              .having((e) => e.message, 'message', contains('decrease'))));
    });
  });

  group('labels round trip', () {
    test('encode -> decode -> encode is exact', () {
      final text = encodeLabels(labels);
      expect(validateLabels(text), isEmpty);
      final back = decodeLabels(text);
      expect(back.recording, labels.recording);
      expect(back.intervals, labels.intervals);
      expect(back.takbirTimesMs, labels.takbirTimesMs);
      expect(encodeLabels(back), text);
    });

    test('takbir events are interleaved in time order', () {
      final lines = const LineSplitter().convert(encodeLabels(labels));
      expect(lines, hasLength(1 + 4 + 3));
      expect(lines[2], '{"type":"takbir","tMs":1000}');
      expect(lines[3], contains('"startMs":1000'));
      expect(lines[5], '{"type":"takbir","tMs":9200}');
      expect(lines.last, '{"type":"takbir","tMs":20000}');
    });
  });

  group('label lookups', () {
    test('stateAt and postureAt use half-open intervals', () {
      expect(labels.stateAt(0), PrayerState.waiting);
      expect(labels.stateAt(999), PrayerState.waiting);
      expect(labels.stateAt(1000), PrayerState.takbir);
      expect(labels.stateAt(8999), PrayerState.qiyam1);
      expect(labels.postureAt(8999), Posture.standing);
      expect(labels.postureAt(10000), Posture.bowing);
      expect(labels.stateAt(11999), PrayerState.ruku1);
    });

    test('gaps and outside range return null', () {
      expect(labels.stateAt(9000), isNull);
      expect(labels.postureAt(9499), isNull);
      expect(labels.stateAt(12000), isNull);
      expect(labels.stateAt(-1), isNull);
      expect(const LabelSet(recording: 'x', intervals: []).stateAt(0), isNull);
    });
  });

  group('labels validation', () {
    test('empty file and bad header', () {
      expect(validateLabels(''), hasError(1, 'missing header'));
      expect(validateLabels(lab([], head: '{"format":"salah-recording"}')),
          hasError(1, '"format"'));
      expect(
          validateLabels(lab([],
              head: '{"format":"salah-labels","version":3,"recording":"a"}')),
          hasError(1, '"version"'));
      expect(
          validateLabels(
              lab([], head: '{"format":"salah-labels","version":1}')),
          hasError(1, 'missing field "recording"'));
    });

    test('bad JSON and unknown type', () {
      final errors = validateLabels(lab(['{oops', '{"type":"ameen"}', '{}']));
      expect(errors, hasError(2, 'invalid JSON'));
      expect(errors, hasError(3, '"type" has unknown value'));
      expect(errors, hasError(4, 'missing field "type"'));
    });

    test('missing interval fields', () {
      final errors = validateLabels(lab(['{"type":"interval","startMs":0}']));
      expect(errors, hasError(2, 'missing field "endMs"'));
      expect(errors, hasError(2, 'missing field "posture"'));
      expect(errors, hasError(2, 'missing field "state"'));
      expect(errors, hasError(2, 'missing field "rakah"'));
    });

    test('unknown posture and state names', () {
      final errors = validateLabels(lab([
        interval(0, 10, posture: 'kneeling'),
        interval(10, 20, state: 'qiyam3'),
      ]));
      expect(errors, hasError(2, '"posture" has unknown value "kneeling"'));
      expect(errors, hasError(3, '"state" has unknown value "qiyam3"'));
    });

    test('startMs must be before endMs', () {
      final errors = validateLabels(lab([interval(10, 10), interval(30, 20)]));
      expect(errors, hasError(2, 'must be less than endMs'));
      expect(errors, hasError(3, 'must be less than endMs'));
    });

    test('negative times', () {
      final errors =
          validateLabels(lab([interval(-5, 10), '{"type":"takbir","tMs":-1}']));
      expect(errors, hasError(2, '"startMs" must be >= 0'));
      expect(errors, hasError(3, '"tMs" must be >= 0'));
    });

    test('overlapping and unsorted intervals', () {
      final errors = validateLabels(lab([
        interval(0, 100),
        interval(50, 150),
        interval(10, 20),
      ]));
      expect(errors, hasError(3, 'overlaps previous 0-100'));
      expect(errors, hasError(4, 'must be sorted'));
    });

    test('adjacent intervals are fine', () {
      expect(
          validateLabels(lab([interval(0, 100), interval(100, 200)])), isEmpty);
    });

    test('rakah rules', () {
      final errors = validateLabels(lab([
        interval(0, 10, state: 'qiyam1', rakah: 0),
        interval(10, 20, state: 'ruku2', rakah: 1),
        interval(20, 30, state: 'waiting', rakah: 3),
        interval(30, 40, state: 'finalSitting', posture: 'sitting', rakah: 1),
      ]));
      expect(errors,
          hasError(2, 'rakah 0 is only allowed for waiting, takbir or done'));
      expect(errors, hasError(3, 'ruku2 must have rakah 2'));
      expect(errors, hasError(4, 'must be 0, 1 or 2'));
      expect(errors, hasError(5, 'finalSitting must have rakah 2'));
      expect(
          validateLabels(lab([
            interval(0, 10, state: 'waiting', rakah: 0),
            interval(10, 20, state: 'takbir', rakah: 0),
          ])),
          isEmpty);
    });

    test('done may have rakah 0, 1 or 2 (abandoned sessions)', () {
      for (final k in [0, 1, 2]) {
        expect(
            validateLabels(lab([
              interval(0, 10, state: 'waiting', rakah: 0),
              interval(10, 20, state: 'done', rakah: k),
            ])),
            isEmpty,
            reason: 'done with rakah $k');
      }
      expect(validateLabels(lab([interval(0, 10, state: 'done', rakah: 3)])),
          hasError(2, 'must be 0, 1 or 2'));
    });

    test('takbir times must be integers and strictly increasing', () {
      final errors = validateLabels(lab([
        '{"type":"takbir","tMs":100}',
        '{"type":"takbir","tMs":100}',
        '{"type":"takbir","tMs":1.5}',
        '{"type":"takbir"}',
      ]));
      expect(errors, hasError(3, 'strictly increasing'));
      expect(errors, hasError(4, '"tMs" must be an integer'));
      expect(errors, hasError(5, 'missing field "tMs"'));
    });

    test('decode throws the first error', () {
      expect(() => decodeLabels(lab([interval(0, 100), interval(50, 60), '{'])),
          throwsA(isA<FormatError>().having((e) => e.line, 'line', 3)));
    });
  });

  group('fixtures', () {
    final recText =
        File('test/fixtures/sample.recording.ndjson').readAsStringSync();
    final labText =
        File('test/fixtures/sample.labels.ndjson').readAsStringSync();

    test('sample recording validates and decodes', () {
      expect(validateRecording(recText), isEmpty);
      final r = decodeRecording(recText);
      expect(r.header.fps, 15);
      expect(r.frames, hasLength(4));
      expect(r.frames[1].tiltDeg, 0.5);
      expect(r.frames[2].hasPerson, isFalse);
      expect(r.frames[3].people, hasLength(2));
      final once = encodeRecording(r);
      expect(encodeRecording(decodeRecording(once)), once);
    });

    test('sample labels validate and re-encode byte for byte', () {
      expect(validateLabels(labText), isEmpty);
      final l = decodeLabels(labText);
      expect(l.recording, 'sample.recording.ndjson');
      expect(l.takbirTimesMs, [50]);
      expect(l.stateAt(100), PrayerState.qiyam1);
      expect(l.postureAt(150), Posture.bowing);
      expect(encodeLabels(l), labText);
    });

    test('labels cover the recording frames', () {
      final r = decodeRecording(recText);
      final l = decodeLabels(labText);
      for (final f in r.frames) {
        expect(l.stateAt(f.tMs), isNotNull, reason: 't=${f.tMs}');
      }
    });
  });
}
