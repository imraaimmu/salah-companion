# Recording and label format

Test recordings and their labels are two NDJSON files per prayer: UTF-8 text, one JSON object per line, LF or CRLF line endings. The codec and validator live in `packages/salah_core/lib/src/recording.dart`; see also docs/SPEC.md, "Test data".

**Recordings contain landmark numbers only, never images or video.** No field may hold pixels, thumbnails, audio or anything that identifies a person beyond the pose landmarks themselves.

## Recording: `<name>.recording.ndjson`

Line 1 is the header. Every other line is one frame.

```
{"format":"salah-recording","version":1,"engine":"mediapipe-pose-landmarker","model":"lite","fps":15,"orientation":"portrait","side":"left","device":"Pixel 6a","imageW":480,"imageH":640}
{"t":0,"people":[[[212.4,88.1,-0.12,0.98], ... 33 landmarks ...]]}
{"t":67,"people":[[[212.9,88.3,-0.11,0.97], ... ]],"tilt":0.5}
{"t":100,"people":[]}
```

Header fields (all required):

| Field | Type | Notes |
| --- | --- | --- |
| `format` | string | Always `"salah-recording"` |
| `version` | int | Always `1` |
| `engine`, `model` | string | Pose engine and model, non-empty |
| `fps` | int | Camera frame rate, at least 1 |
| `orientation` | string | `"portrait"` or `"landscape"` |
| `side` | string | Body side facing the camera: `"left"` or `"right"` |
| `device` | string | Phone model |
| `imageW`, `imageH` | int | Upright frame size in pixels, at least 1 |

Frame fields:

| Field | Type | Notes |
| --- | --- | --- |
| `t` | int | Milliseconds since session start, at least 0, never decreasing. Two frames that both have people must not share a `t`; a frame with `people: []` may share its `t` with its neighbours (the engine's heartbeats never do: they are stamped strictly between camera frames, see the heartbeat rule in docs/SPEC.md section 5) |
| `people` | array | Each person is exactly 33 landmarks in BlazePose order. `[]` means no person: a camera frame in which nobody was detected, or a heartbeat written into the recording. The replay harness feeds both as frames (an `unknown` reading); it inserts any missing heartbeats itself by the heartbeat rule |
| `tilt` | number | Optional, default 0. Phone roll in degrees relative to session start |

A landmark is `[x, y, z, conf]`: x and y in pixels of the upright, unmirrored frame, z relative to the hips, conf in 0..1. All numbers must be finite. Unknown extra fields are ignored.

## Labels: `<name>.labels.ndjson`

Line 1 is the header. Every other line is either an interval or a takbir event. The current format is **version 2**; readers also accept version 1 (below).

Labels are **ground truth**: where the person really is in the prayer, switching at the
middle of each movement, without the state machine's hold delays. Frames in the middle of
a posture change may be labelled `unknown`. A `takbir` event marks only the **opening**
takbir (takbirat al-ihram), at the moment the hands come back down. Hand raises at ruku, in
qunut or when standing up from the middle sitting are not takbir events.

```
{"format":"salah-labels","version":2,"recording":"dhuhr-001.recording.ndjson","prayer":"dhuhr"}
{"type":"interval","startMs":0,"endMs":4200,"posture":"standing","state":"waiting","rakah":0}
{"type":"takbir","tMs":4200}
{"type":"interval","startMs":4200,"endMs":5100,"posture":"standing","state":"takbir","rakah":0}
{"type":"interval","startMs":5100,"endMs":61000,"posture":"standing","state":"qiyam","rakah":1}
...
{"type":"interval","startMs":150300,"endMs":171000,"posture":"sitting","state":"middleSitting","rakah":2}
{"type":"interval","startMs":171000,"endMs":172100,"posture":"unknown","state":"qiyam","rakah":3}
```

Header fields:

| Field | Type | Notes |
| --- | --- | --- |
| `format` | string | Always `"salah-labels"` |
| `version` | int | `2` (written); `1` is still read |
| `recording` | string | File name of the matching recording, non-empty |
| `prayer` | string | Version 2 only, optional (default `"fajr"`): `fajr`, `dhuhr`, `asr`, `maghrib` or `isha`. Sets N, the number of rak'ahs (2, 4, 4, 3, 4) |

Intervals and takbir events:

- Intervals are half-open, `[startMs, endMs)`, with `0 <= startMs < endMs`. They are sorted and do not overlap; touching (`endMs` equal to the next `startMs`) is fine, and gaps mean "not labelled".
- `posture` is one of `standing`, `bowing`, `prostrating`, `sitting`, `unknown`.
- `state` is a `PrayerState` name, the same in every rak'ah: `waiting`, `takbir`, `qiyam`, `ruku`, `itidal`, `sujood` (both prostrations and the jalsa), `middleSitting` (the first tashahhud after rak'ah 2 of a 3- or 4-rak'ah prayer), `finalSitting`, `done`.
- `rakah` says which rak'ah, from 0 to N:
  - `waiting` and `takbir`: 0 before the prayer (any value up to N is accepted);
  - `qiyam`, `ruku`, `itidal`, `sujood`: 1 to N;
  - `middleSitting`: 2, and only in a prayer with N > 2;
  - `finalSitting`: N (sujood al-sahw and the salam are part of it);
  - `done`: 0 to N, because an abandoned session can end in `done` at any point.
- A takbir event marks the moment a takbir hand raise completes. `tMs` is an int, at least 0, and takbir times are strictly increasing.

The encoder always writes version 2, with the `prayer` field, and writes intervals and takbir events in time order (a takbir at the same time as an interval start comes first), so encode → decode → encode is byte-exact.

### Version 1 (read only)

Version 1 files have no `prayer` (they are Fajr) and name the rak'ah in the state: `qiyam1`, `ruku1`, `itidal1`, `sujood1`, `qiyam2`, `ruku2`, `itidal2`, `sujood2`, plus `waiting`, `takbir`, `finalSitting` and `done`. The rules are those of the time: `rakah` is 0, 1 or 2; states ending in 1 need rakah 1, states ending in 2 and `finalSitting` need rakah 2; `waiting`, `takbir` and `done` accept 0, 1 or 2. The decoder maps each state to its version 2 equivalent, e.g. `qiyam1` → (`qiyam`, 1), `sujood2` → (`sujood`, 2), `finalSitting` → (`finalSitting`, 2). Re-encoding a version 1 file writes it as version 2.
