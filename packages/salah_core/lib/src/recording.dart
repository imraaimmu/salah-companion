/// NDJSON recording and label files used for tuning and regression tests.
/// See docs/recording-format.md and docs/SPEC.md, section "Test data".
///
/// Recordings hold landmark numbers only, never images.
library;

import 'dart:convert';

import 'pose.dart';
import 'posture.dart';
import 'prayer.dart';

const String recordingFormatName = 'salah-recording';
const String labelsFormatName = 'salah-labels';
const int recordingFormatVersion = 1;
const int labelsFormatVersion = 1;

const List<String> _orientations = ['portrait', 'landscape'];
const List<String> _sides = ['left', 'right'];

/// A problem found while reading a recording or label file.
class FormatError implements Exception {
  /// 1-based line number in the file.
  final int line;
  final String message;

  const FormatError(this.line, this.message);

  @override
  bool operator ==(Object other) =>
      other is FormatError && other.line == line && other.message == message;

  @override
  int get hashCode => Object.hash(line, message);

  @override
  String toString() => 'FormatError(line $line: $message)';
}

/// First line of a `*.recording.ndjson` file.
class RecordingHeader {
  final String engine;
  final String model;
  final int fps;

  /// "portrait" or "landscape".
  final String orientation;

  /// Which side of the body faces the camera: "left" or "right".
  final String side;
  final String device;
  final int imageW;
  final int imageH;

  const RecordingHeader({
    required this.engine,
    required this.model,
    required this.fps,
    required this.orientation,
    required this.side,
    required this.device,
    required this.imageW,
    required this.imageH,
  });

  Map<String, Object?> toJson() => {
        'format': recordingFormatName,
        'version': recordingFormatVersion,
        'engine': engine,
        'model': model,
        'fps': fps,
        'orientation': orientation,
        'side': side,
        'device': device,
        'imageW': imageW,
        'imageH': imageH,
      };

  /// Throws [FormatError] (line 1) if [json] is not a valid header.
  factory RecordingHeader.fromJson(Map<String, Object?> json) {
    final errors = <FormatError>[];
    final header = _parseRecordingHeader(json, errors);
    if (errors.isNotEmpty) throw errors.first;
    return header!;
  }
}

class Recording {
  final RecordingHeader header;
  final List<PoseFrame> frames;

  const Recording({required this.header, required this.frames});
}

/// One labelled span, half-open: [startMs, endMs).
class LabelInterval {
  final int startMs;
  final int endMs;
  final Posture posture;
  final PrayerState state;

  /// 0 (only for waiting or takbir before the prayer, or done after an
  /// abandoned session), 1 or 2.
  final int rakah;

  const LabelInterval({
    required this.startMs,
    required this.endMs,
    required this.posture,
    required this.state,
    required this.rakah,
  });

  bool contains(int tMs) => tMs >= startMs && tMs < endMs;

  Map<String, Object?> toJson() => {
        'type': 'interval',
        'startMs': startMs,
        'endMs': endMs,
        'posture': posture.name,
        'state': state.name,
        'rakah': rakah,
      };

  @override
  bool operator ==(Object other) =>
      other is LabelInterval &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.posture == posture &&
      other.state == state &&
      other.rakah == rakah;

  @override
  int get hashCode => Object.hash(startMs, endMs, posture, state, rakah);

  @override
  String toString() =>
      'LabelInterval($startMs-$endMs ms, $posture, $state, rakah $rakah)';
}

class LabelSet {
  /// File name of the recording these labels describe.
  final String recording;

  /// Sorted, non-overlapping.
  final List<LabelInterval> intervals;

  /// Sorted, strictly increasing.
  final List<int> takbirTimesMs;

  const LabelSet({
    required this.recording,
    required this.intervals,
    this.takbirTimesMs = const [],
  });

  LabelInterval? intervalAt(int tMs) {
    var lo = 0;
    var hi = intervals.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final iv = intervals[mid];
      if (tMs < iv.startMs) {
        hi = mid - 1;
      } else if (tMs >= iv.endMs) {
        lo = mid + 1;
      } else {
        return iv;
      }
    }
    return null;
  }

  /// The labelled state at [tMs], or null if no interval covers it.
  PrayerState? stateAt(int tMs) => intervalAt(tMs)?.state;

  /// The labelled posture at [tMs], or null if no interval covers it.
  Posture? postureAt(int tMs) => intervalAt(tMs)?.posture;
}

// ---------------------------------------------------------------------------
// Encoding

/// Encodes [r] as NDJSON, one line per object, ending with a newline.
///
/// Each frame's people are written from [PoseFrame.people]; if that is empty
/// but [PoseFrame.landmarks] is set, the landmarks are written as one person.
/// `tilt` is omitted when it is 0. Throws [ArgumentError] for non-finite
/// numbers or a person without exactly 33 landmarks.
String encodeRecording(Recording r) {
  final buf = StringBuffer()..writeln(jsonEncode(r.header.toJson()));
  for (final f in r.frames) {
    final people = f.people.isNotEmpty
        ? f.people
        : (f.landmarks != null ? [f.landmarks!] : const <List<Landmark>>[]);
    final json = <String, Object?>{
      't': f.tMs,
      'people': [
        for (final p in people)
          [
            if (p.length != LandmarkIndex.count)
              throw ArgumentError('frame ${f.tMs}: person has ${p.length} '
                  'landmarks, expected ${LandmarkIndex.count}'),
            for (final l in p)
              [
                _finite(l.x, f.tMs),
                _finite(l.y, f.tMs),
                _finite(l.z, f.tMs),
                _finite(l.conf, f.tMs),
              ],
          ],
      ],
      if (f.tiltDeg != 0) 'tilt': _finite(f.tiltDeg, f.tMs),
    };
    buf.writeln(jsonEncode(json));
  }
  return buf.toString();
}

double _finite(double v, int tMs) {
  if (!v.isFinite) throw ArgumentError('frame $tMs: non-finite number $v');
  return v;
}

/// Encodes [labels] as NDJSON. Intervals and takbir events are written in
/// time order; a takbir at the same time as an interval start comes first.
String encodeLabels(LabelSet labels) {
  final buf = StringBuffer()
    ..writeln(jsonEncode({
      'format': labelsFormatName,
      'version': labelsFormatVersion,
      'recording': labels.recording,
    }));
  var ti = 0;
  final takbirs = labels.takbirTimesMs;
  for (final iv in labels.intervals) {
    while (ti < takbirs.length && takbirs[ti] <= iv.startMs) {
      buf.writeln(jsonEncode({'type': 'takbir', 'tMs': takbirs[ti++]}));
    }
    buf.writeln(jsonEncode(iv.toJson()));
  }
  while (ti < takbirs.length) {
    buf.writeln(jsonEncode({'type': 'takbir', 'tMs': takbirs[ti++]}));
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Decoding and validation

/// Decodes a recording. Throws [FormatError] for the first problem.
Recording decodeRecording(String text) {
  final errors = <FormatError>[];
  final r = _parseRecording(text, errors);
  if (errors.isNotEmpty) throw errors.first;
  return r!;
}

/// Returns every problem in a recording file; empty means valid.
List<FormatError> validateRecording(String text) {
  final errors = <FormatError>[];
  _parseRecording(text, errors);
  return errors;
}

/// Decodes a label file. Throws [FormatError] for the first problem.
LabelSet decodeLabels(String text) {
  final errors = <FormatError>[];
  final l = _parseLabels(text, errors);
  if (errors.isNotEmpty) throw errors.first;
  return l!;
}

/// Returns every problem in a label file; empty means valid.
List<FormatError> validateLabels(String text) {
  final errors = <FormatError>[];
  _parseLabels(text, errors);
  return errors;
}

/// Splits into lines, accepting LF or CRLF and one trailing newline.
List<String> _lines(String text) {
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return [
    for (final l in lines) l.endsWith('\r') ? l.substring(0, l.length - 1) : l
  ];
}

/// Parses one line as a JSON object, or records an error and returns null.
Map<String, Object?>? _object(String line, int lineNo, List<FormatError> e) {
  if (line.trim().isEmpty) {
    e.add(FormatError(lineNo, 'empty line'));
    return null;
  }
  Object? v;
  try {
    v = jsonDecode(line);
  } on FormatException catch (ex) {
    e.add(FormatError(lineNo, 'invalid JSON: ${ex.message}'));
    return null;
  }
  if (v is! Map<String, Object?>) {
    e.add(FormatError(lineNo, 'expected a JSON object'));
    return null;
  }
  return v;
}

/// Field readers. Each records an error and returns null when the field is
/// missing or has the wrong type.
class _Fields {
  final Map<String, Object?> json;
  final int line;
  final List<FormatError> errors;
  _Fields(this.json, this.line, this.errors);

  void _err(String m) => errors.add(FormatError(line, m));

  Object? _require(String key) {
    if (!json.containsKey(key)) {
      _err('missing field "$key"');
      return null;
    }
    final v = json[key];
    if (v == null) _err('field "$key" is null');
    return v;
  }

  String? string(String key, {bool nonEmpty = false}) {
    final v = _require(key);
    if (v == null) return null;
    if (v is! String) {
      _err('field "$key" must be a string');
      return null;
    }
    if (nonEmpty && v.isEmpty) {
      _err('field "$key" must not be empty');
      return null;
    }
    return v;
  }

  int? integer(String key, {int? min}) {
    final v = _require(key);
    if (v == null) return null;
    if (v is double && !v.isFinite) {
      _err('field "$key" is not a finite number');
      return null;
    }
    if (v is! int) {
      _err('field "$key" must be an integer');
      return null;
    }
    if (min != null && v < min) {
      _err('field "$key" must be >= $min, got $v');
      return null;
    }
    return v;
  }

  String? oneOf(String key, List<String> allowed) {
    final v = string(key);
    if (v == null) return null;
    if (!allowed.contains(v)) {
      _err('field "$key" has unknown value "$v" '
          '(expected one of ${allowed.join(', ')})');
      return null;
    }
    return v;
  }

  bool expectConst(String key, Object value) {
    final v = _require(key);
    if (v == null) return false;
    if (v != value) {
      _err('field "$key" must be ${jsonEncode(value)}, got ${jsonEncode(v)}');
      return false;
    }
    return true;
  }
}

RecordingHeader? _parseRecordingHeader(
    Map<String, Object?> json, List<FormatError> errors) {
  final f = _Fields(json, 1, errors);
  final before = errors.length;
  final formatOk = f.expectConst('format', recordingFormatName);
  if (!formatOk) return null;
  f.expectConst('version', recordingFormatVersion);
  final engine = f.string('engine', nonEmpty: true);
  final model = f.string('model', nonEmpty: true);
  final fps = f.integer('fps', min: 1);
  final orientation = f.oneOf('orientation', _orientations);
  final side = f.oneOf('side', _sides);
  final device = f.string('device');
  final imageW = f.integer('imageW', min: 1);
  final imageH = f.integer('imageH', min: 1);
  if (errors.length != before) return null;
  return RecordingHeader(
    engine: engine!,
    model: model!,
    fps: fps!,
    orientation: orientation!,
    side: side!,
    device: device!,
    imageW: imageW!,
    imageH: imageH!,
  );
}

Recording? _parseRecording(String text, List<FormatError> errors) {
  final lines = _lines(text);
  if (lines.isEmpty) {
    errors.add(const FormatError(1, 'missing header'));
    return null;
  }
  final before = errors.length;
  RecordingHeader? header;
  final headerJson = _object(lines[0], 1, errors);
  if (headerJson != null) header = _parseRecordingHeader(headerJson, errors);

  final frames = <PoseFrame>[];
  int? lastT;
  // Whether a frame with people has already been seen at lastT.
  var peopleAtLastT = false;
  for (var i = 1; i < lines.length; i++) {
    final lineNo = i + 1;
    final json = _object(lines[i], lineNo, errors);
    if (json == null) continue;
    final frame = _parseFrame(json, lineNo, errors, header);
    if (frame == null) continue;
    final hasPeople = frame.people.isNotEmpty;
    if (lastT != null && frame.tMs < lastT) {
      errors.add(FormatError(
          lineNo, '"t" must not decrease (${frame.tMs} after $lastT)'));
    } else if (lastT != null &&
        frame.tMs == lastT &&
        hasPeople &&
        peopleAtLastT) {
      errors.add(FormatError(
          lineNo,
          '"t" must be strictly increasing between frames with people '
          '(${frame.tMs} after $lastT)'));
    }
    if (lastT == null || frame.tMs != lastT) peopleAtLastT = false;
    if (hasPeople) peopleAtLastT = true;
    lastT = frame.tMs;
    frames.add(frame);
  }
  if (errors.length != before || header == null) return null;
  return Recording(header: header, frames: frames);
}

PoseFrame? _parseFrame(Map<String, Object?> json, int line,
    List<FormatError> errors, RecordingHeader? header) {
  final f = _Fields(json, line, errors);
  final before = errors.length;
  final t = f.integer('t', min: 0);

  var tilt = 0.0;
  if (json.containsKey('tilt')) {
    final v = json['tilt'];
    if (v is! num) {
      f._err('field "tilt" must be a number');
    } else if (!v.isFinite) {
      f._err('field "tilt" is not a finite number');
    } else {
      tilt = v.toDouble();
    }
  }

  final people = <List<Landmark>>[];
  final rawPeople = f._require('people');
  if (rawPeople != null && rawPeople is! List) {
    f._err('field "people" must be an array');
  } else if (rawPeople is List) {
    for (var p = 0; p < rawPeople.length; p++) {
      final person = _parsePerson(rawPeople[p], p, f);
      if (person != null) people.add(person);
    }
  }
  if (errors.length != before) return null;
  return PoseFrame(
    tMs: t!,
    landmarks: people.length == 1 ? people.single : null,
    people: people,
    imageW: header?.imageW ?? 0,
    imageH: header?.imageH ?? 0,
    tiltDeg: tilt,
  );
}

List<Landmark>? _parsePerson(Object? raw, int p, _Fields f) {
  if (raw is! List) {
    f._err('person $p must be an array of landmarks');
    return null;
  }
  if (raw.length != LandmarkIndex.count) {
    f._err('person $p has ${raw.length} landmarks, '
        'expected ${LandmarkIndex.count}');
    return null;
  }
  final out = <Landmark>[];
  var ok = true;
  for (var i = 0; i < raw.length; i++) {
    final lm = raw[i];
    if (lm is! List || lm.length != 4) {
      f._err('person $p landmark $i must be [x, y, z, conf]');
      ok = false;
      continue;
    }
    final nums = <double>[];
    for (var k = 0; k < 4; k++) {
      final v = lm[k];
      if (v is! num) {
        f._err('person $p landmark $i value $k is not a number');
        ok = false;
        break;
      }
      if (!v.isFinite) {
        f._err('person $p landmark $i value $k is not a finite number');
        ok = false;
        break;
      }
      nums.add(v.toDouble());
    }
    if (nums.length != 4) continue;
    if (nums[3] < 0 || nums[3] > 1) {
      f._err('person $p landmark $i conf ${nums[3]} is outside 0..1');
      ok = false;
      continue;
    }
    out.add(Landmark(nums[0], nums[1], nums[2], nums[3]));
  }
  return ok ? out : null;
}

LabelSet? _parseLabels(String text, List<FormatError> errors) {
  final lines = _lines(text);
  if (lines.isEmpty) {
    errors.add(const FormatError(1, 'missing header'));
    return null;
  }
  final before = errors.length;
  String? recording;
  final headerJson = _object(lines[0], 1, errors);
  if (headerJson != null) {
    final f = _Fields(headerJson, 1, errors);
    if (f.expectConst('format', labelsFormatName)) {
      f.expectConst('version', labelsFormatVersion);
      recording = f.string('recording', nonEmpty: true);
    }
  }

  final intervals = <LabelInterval>[];
  final takbirs = <int>[];
  for (var i = 1; i < lines.length; i++) {
    final lineNo = i + 1;
    final json = _object(lines[i], lineNo, errors);
    if (json == null) continue;
    final f = _Fields(json, lineNo, errors);
    final type = f.oneOf('type', const ['interval', 'takbir']);
    if (type == 'takbir') {
      final t = f.integer('tMs', min: 0);
      if (t == null) continue;
      if (takbirs.isNotEmpty && t <= takbirs.last) {
        f._err('takbir times must be strictly increasing '
            '($t after ${takbirs.last})');
      }
      takbirs.add(t);
    } else if (type == 'interval') {
      final iv = _parseInterval(f);
      if (iv == null) continue;
      if (intervals.isNotEmpty && iv.startMs < intervals.last.endMs) {
        final prev = intervals.last;
        f._err(iv.startMs < prev.startMs
            ? 'intervals must be sorted (startMs ${iv.startMs} '
                'before previous ${prev.startMs})'
            : 'interval ${iv.startMs}-${iv.endMs} overlaps previous '
                '${prev.startMs}-${prev.endMs}');
      }
      intervals.add(iv);
    }
  }
  if (errors.length != before || recording == null) return null;
  return LabelSet(
      recording: recording, intervals: intervals, takbirTimesMs: takbirs);
}

LabelInterval? _parseInterval(_Fields f) {
  final before = f.errors.length;
  final start = f.integer('startMs', min: 0);
  final end = f.integer('endMs', min: 0);
  final postureName =
      f.oneOf('posture', [for (final p in Posture.values) p.name]);
  final stateName =
      f.oneOf('state', [for (final s in PrayerState.values) s.name]);
  final rakah = f.integer('rakah');
  if (f.errors.length != before) return null;

  if (start! >= end!) {
    f._err('startMs ($start) must be less than endMs ($end)');
  }
  final state = PrayerState.values.byName(stateName!);
  final allowed = _allowedRakahs(state);
  if (rakah! < 0 || rakah > 2) {
    f._err('field "rakah" must be 0, 1 or 2, got $rakah');
  } else if (!allowed.contains(rakah)) {
    f._err(rakah == 0
        ? 'rakah 0 is only allowed for waiting, takbir or done, '
            'not ${state.name}'
        : 'state ${state.name} must have rakah ${allowed.join(' or ')}, '
            'got $rakah');
  }
  if (f.errors.length != before) return null;
  return LabelInterval(
    startMs: start,
    endMs: end,
    posture: Posture.values.byName(postureName!),
    state: state,
    rakah: rakah,
  );
}

/// The rak'ah numbers a state may be labelled with.
List<int> _allowedRakahs(PrayerState s) => switch (s) {
      PrayerState.waiting || PrayerState.takbir => const [0, 1, 2],
      PrayerState.qiyam1 ||
      PrayerState.ruku1 ||
      PrayerState.itidal1 ||
      PrayerState.sujood1 =>
        const [1],
      PrayerState.qiyam2 ||
      PrayerState.ruku2 ||
      PrayerState.itidal2 ||
      PrayerState.sujood2 ||
      PrayerState.finalSitting =>
        const [2],
      // An abandoned session can end in done at any point.
      PrayerState.done => const [0, 1, 2],
    };
