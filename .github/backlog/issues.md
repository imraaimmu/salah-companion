# Initial issue backlog

Each `## ` heading becomes one GitHub issue. The `Labels:` line sets its labels.
Section numbers refer to docs/SPEC.md. Created by `scripts/create_issues.py`.

## Scaffold the Flutter project and core interfaces
Labels: W0-setup, good first issue

Create the Flutter app skeleton (Android first) with the package layout from SPEC section 5 ("Technical architecture").

- Add the Dart types and abstract classes from the "Interfaces" code block, unchanged: `Landmark`, `PoseFrame`, `CameraConfig`, `Posture`, `PostureReading`, `PrayerState`, `PrayerEvent` and subclasses, `AyahClip`, `RecitationPlan`, `PoseEngine`, `PostureClassifier`, `PostureSmoother`, `PrayerStateMachine`, `RecitationPlayer`.
- Pure-Dart logic (classifier, smoother, state machine, scheduler) lives in a separate package with no Flutter dependency, so it tests fast in CI.
- Android `applicationId`: decide with the maintainer; the internal test app gets its own ID ending in `.internal`.

**Done when:** `flutter analyze` and `dart test` pass on an empty test suite; README explains how to run.

## CI: analyzer, tests, and the privacy gates
Labels: W7-qa, privacy

Set up GitHub Actions (SPEC sections 5, 8 and 9).

- `flutter analyze`, `dart test` for the pure-Dart package, `flutter test`.
- **No-INTERNET gate:** build the release APK and fail if `aapt2 dump permissions` lists `android.permission.INTERNET` or `ACCESS_NETWORK_STATE`. Add `tools:node="remove"` entries to the main manifest.
- **No-recorder gate:** fail the store build if any recorder code or file-writing of landmarks is present.
- Per-frame Dart benchmark: classifier + smoother + state machine under 1 ms per frame.

**Done when:** all gates run on every pull request and a deliberate violation makes CI fail.

## Spike: MediaPipe Pose Landmarker on the reference phones
Labels: W1-pose, spike, needs-device

Confirm the default engine meets the spike criteria in SPEC section 5 ("Pose engine choice").

- Realme 16 Pro+ and the budget floor phone; rear camera, portrait, 15 fps.
- Measure: fps under a single dim lamp; standing vs sitting separation and sujood detection with knees hidden (loose clothing); model size; network capture showing zero traffic.
- Compare lite / full / heavy models. Optionally compare ML Kit in a throwaway build for reference only.

**Done when:** a short written note in `docs/spikes/` with numbers and a model recommendation.

## Choose the budget floor phone
Labels: W1-pose, maintainer

Pick one widely used budget Android phone with about 4 GB RAM as the minimum supported device (SPEC section 5, "Performance targets"). Both reference phones must reach 15 fps.

## Android native bridge: CameraX + MediaPipe to PoseFrame
Labels: W1-pose, needs-device

Implement `PoseEngine` for Android (SPEC sections 5 and 6).

- Camera capture and inference run natively; only landmarks cross to Dart over an EventChannel (about 0.5 KB per frame). No camera images pass through Flutter.
- Landmarks in pixel coordinates of the upright, unmirrored frame; confidence mapped to `conf`; camera sensor timestamps; `tiltDeg` from the accelerometer.
- Emit a heartbeat `PoseFrame` with `landmarks: null` every 100 ms when no person is detected.
- Support up to 3 people (`numPoses`) so the classifier can pick the user.
- Placement preview as a native texture.

**Done when:** landmark mapping has Kotlin unit tests; demo on a real phone streams frames at 15 fps.

## FakePoseEngine that replays recordings
Labels: W1-pose, good first issue

A `PoseEngine` implementation that reads NDJSON recordings (see the recording format issue) and emits `PoseFrame`s with their original timestamps, for tests and the replay harness.

**Done when:** unit tests replay a sample file and get identical frames back.

## Define the NDJSON recording and label format, with a validator
Labels: W2-data, good first issue

Specify and implement the format in SPEC section 6 ("Test data").

- Header line: `engine`, `model`, `fps`, `orientation`, `side`, `device`.
- One line per frame: `t` and 33 × `[x, y, z, conf]`, or `null`.
- Separate label file of intervals: `startMs`, `endMs`, `posture`, `prayerState`, `rakah`.
- Write `docs/recording-format.md` and a validator with tests.

## Synthetic prayer sequence generator
Labels: W2-data, W4-state-machine

Generate labelled synthetic Fajr sequences in the recording format, with noise, landmark dropouts and timing variation, so classifier and state-machine work can start before real recordings exist (SPEC section 6).

Must be able to produce every required replay case in SPEC section 4, including: standing 30 s before takbir, a missed takbir, Shafi'i and Maliki qunut, raised hands at ruku, a brief sitting before rak'ah 2, a hurried jalsa, a missed ruku, a long tashahhud, sujood al-sahw, and a second person in frame.

**Done when:** generator has tests and can emit at least 500 perturbed sequences deterministically from a seed.

## Internal test app with landmark recorder
Labels: W2-data, privacy, needs-device

A separate app (own package ID ending in `.internal`, never published) that records landmark numbers only, never images or video, from consenting team members and volunteers (SPEC sections 6 and 8).

- Explicit consent screen before any recording.
- Files stay on the device until the volunteer shares them with the team.

## Stick-figure replay labelling tool
Labels: W2-data

A small tool (desktop or web, offline) that draws a stick figure from a recording and lets a person mark posture and prayer-state intervals, writing the label file. No camera footage is needed at any point (SPEC section 6).

## PostureClassifier with hip-height-first rules
Labels: W3-classifier

Implement the classifier in SPEC section 6 ("Features per frame", "Starting rules").

- Lock the near side at session start; pixel coordinates corrected for tilt; distances divided by shoulder-hip length.
- Hip height is the main feature; standing is never decided from torso angle alone.
- Person selection by hip position and torso length when several people are detected.

**Done when (agent gate):** on held-out labelled data, standing vs sitting confusion with knees hidden is 1% of frames or less, and sujood recall is 95% or more.

## Takbir hand-raise event detector
Labels: W3-classifier, religious-review

Detect the takbir raise as an event before smoothing (SPEC section 6): near wrist rises from below the elbow to at least 70% of the way from hip to shoulder, then comes down, within 2 s.

Must work for raising to the ears, shoulders or chest, for men and women, and must not fire on adjusting a hijab or cap. Covered by synthetic and recorded cases from every school.

## PostureSmoother
Labels: W3-classifier, good first issue

Majority vote over a 0.5 s sliding window plus hysteresis (SPEC section 6, "Smoothing and confirmation"). No hold times here: those live only in the state machine. Takbir events pass through untouched.

## PrayerStateMachine (anchor-based)
Labels: W4-state-machine

Implement SPEC section 4 exactly: states table, anchor rules, takbir only from Waiting, early stop, ignored postures, lost-tracking freeze, timeouts, and the sensor clock plus heartbeat.

**Done when (agent gate):** every transition unit-tested; every required replay case passes; zero wrong-time audio across the full replay set.

## SessionController
Labels: W4-state-machine

Pure-Dart controller between the state machine and the player (SPEC section 5): builds the `RecitationPlan` from settings and content, runs the opening-dua and rak'ah 2 pauses, cancels a pending start if the user bows, and handles calls, backgrounding, headphone unplugging and audio interruptions.

**Done when:** unit-tested with a fake player and fake lifecycle events.

## RecitationScheduler and RecitationPlayer
Labels: W5-audio

SPEC section 7 ("Reciter and pace").

- `RecitationScheduler.timeline(plan)` returns the start time of every clip, including the ayah gap and the Ameen gap (ayah gap + 1.5 s after Al-Fatiha). Unit-tested to ±10 ms.
- Player on `just_audio` + `audio_session`: gaps via silence clips or playlist silence, whichever works on both platforms; 300 ms volume fade; playback audio category.
- Placeholder tone assets generated by a script until real audio exists.

## ContentRepository, surah manifest and Auto pair table
Labels: W5-audio, religious-review

Bundled content per SPEC section 7: surah list in mushaf order, the reviewer-approved Auto pair table, Uthmani Arabic text with Tanzil attribution, transliteration and English translation from clearly licensed sources, and the basmalah rule. Includes the automated file-count and silence check.

## Commission the qari recording
Labels: W5-audio, maintainer, religious-review

Find a qualified qari to record Al-Fatiha and the pilot surahs, one file per ayah, in a slow follow-along style, with a written licence that allows free use in this app and its free forks and forbids commercial use (SPEC section 7, "Licensing"). Every file signed off by a qari.

## Home screen
Labels: W6-ui, good first issue

SPEC section 3 ("Screens and visual style"): one large round Start Fajr button, a small settings icon, a small practice-mode icon, and one quiet line with today's surahs. Dark theme. Widget and golden tests; TalkBack labels.

## Placement check screen
Labels: W6-ui, needs-device

SPEC section 3 ("Placing the phone"): full-screen preview with skeleton and one status line; spoken prompts and a tone; passes on confidence 0.7 or more for 3 s, 15 fps for 3 s, and floor space for sujood; the countdown then starts by itself.

## Prayer screen
Labels: W6-ui

SPEC section 3: pure black, one tiny dim tracking dot (amber when lost), no text, no animation, no sounds except the recitation; long-press anywhere to end; screen kept awake. Optional "soft glow" setting, off by default.

## First-run setup and settings
Labels: W6-ui

SPEC section 3 ("First-time setup"): welcome and intent, camera permission with plain-language privacy note, surah choice or Auto, opening-dua length (default Short, 6 s), ayah gap (default 1.5 s), audio check (volume above zero, Bluetooth warning), placement guide. Settings stored locally; Android auto-backup off.

## Practice mode
Labels: W6-ui, W5-audio

Play any surah in the list ayah by ayah with Arabic, transliteration and translation, with repeat. Bundled Uthmani font (KFGQPC Hafs); right-to-left layout tested.

## Field-test build with on-device log
Labels: W7-qa, privacy

SPEC section 9 ("Phases"): a build that keeps an on-device log of states and timings only (no landmarks, no images), cleared on uninstall, with a "Test log" screen showing one summary line per prayer for testers to copy onto the field-test form.

## Store compliance checklist
Labels: W7-qa, privacy, maintainer

SPEC section 8 ("Privacy"): Google Play Data safety "No data collected / shared", hosted privacy policy based on PRIVACY.md, camera permission text (reviewed for wording about prayer), and for iOS later: App Privacy "Data Not Collected", camera usage description, privacy manifest.

## Religious review: brief and scholar sign-off
Labels: religious-review, maintainer

Prepare the brief in SPEC section 8 ("Religious review") and get rulings on: following an outside recitation in fard prayer under each madhhab; whether a madhhab setting is needed; timings; surah list, Auto pairs and basmalah; women's postures; all wording about prayer. Record outcomes in docs/SPEC.md.

## Legal review of the licence and name policy
Labels: legal, maintainer

Have a lawyer review LICENSE (PolyForm Noncommercial 1.0.0), ADDITIONAL-TERMS.md and TRADEMARKS.md before the first public release, so the "no one may charge or earn from it" intent is enforceable, including for noncommercial organizations, and confirm compatibility with Apache 2.0 (MediaPipe) and the audio licence.
