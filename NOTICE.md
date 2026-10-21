# Notices

Salah Companion
Copyright (c) 2026 Pratheesha and the Salah Companion contributors.
Licensed under the PolyForm Noncommercial License 1.0.0 with the Additional Terms in
ADDITIONAL-TERMS.md. See LICENSE.

## Third-party software

Third-party components keep their own licences. Each is listed here as it is added.

| Component | Use | Licence |
| --- | --- | --- |
| Flutter | App framework | BSD 3-Clause |
| MediaPipe Tasks Vision (`com.google.mediapipe:tasks-vision`, Google) | On-device pose detection | Apache 2.0 |
| MediaPipe `pose_landmarker` model (lite/full, Google; downloaded at build time, not committed) | Pose model bundled in the APK | Apache 2.0 |
| CameraX (`androidx.camera`, The Android Open Source Project) | Camera frames and preview | Apache 2.0 |
| just_audio (Ryan Heise and contributors) | Recitation playback | MIT |
| audio_session (Ryan Heise and contributors) | Audio focus, headphone and interruption events | MIT |
| shared_preferences (The Flutter Authors) | Settings stored on the phone | BSD 3-Clause |
| wakelock_plus (creativecreatorormaybenot and contributors) | Keeps the screen on during a session | BSD 3-Clause |
| screen_brightness (Jack Liu) | Dims the screen during a session | MIT |

just_audio brings in further packages (among them rxdart, Apache 2.0; uuid, MIT;
path_provider and crypto, BSD 3-Clause). `flutter pub deps` in `app/` lists them all, and
each keeps its own licence.

### Datatransport API stand-ins

`app/android/app/src/main/java/com/google/android/datatransport/` holds small no-op classes
with the same names as Google's datatransport API, so MediaPipe's usage-statistics client
links but never queues or sends anything (the real library is excluded from the build).
They were written for this project from MediaPipe's call sites only (class, method and field
names and signatures); no Google code was copied. They are covered by this project's
LICENSE. A JVM test (`DatatransportStubsTest`) checks they still match what MediaPipe calls.

## Quran text

The Arabic Quran text in `app/assets/quran/uthmani.json` is the **Tanzil Quran Text
(Uthmani, Version 1.1)**, Copyright (C) 2007-2024 Tanzil Project, licensed under
Creative Commons Attribution 3.0 with the condition that only verbatim copies may be
made. Source: [Tanzil Project, tanzil.net](https://tanzil.net). Check updates at
<https://tanzil.net/updates/>.

The file holds the complete ayahs of Al-Fatiha and the 15 pilot surahs, unaltered, with
Tanzil's copyright block reproduced in full. It is the text as Tanzil exports it without
pause marks, sajdah signs or rub-el-hizb signs. Because tanzil.net could not be reached
from the build environment, the copy was taken from the Tanzil file shipped in the PyPI
package `quran-transcript` 0.6.4, and checked for these surahs against an independent
copy of Tanzil's Uthmani 1.0.2 file (PyPI `pyquran` 1.0.1): the only differences are
Tanzil's own 1.1 orthography updates. Before release, a maintainer should rebuild it
straight from tanzil.net with `scripts/fetch_quran_text.py --download` (which also lets
the religious reviewer decide whether pause marks are shown) and diff the result.

The app's credits screen must name Tanzil Project and link to tanzil.net.

### Translation and transliteration

None is bundled yet. No English translation or transliteration with a clearly free
licence was found in the sources reachable during the build: Tanzil's translations and
transliteration carry their own terms (non-commercial only, and copyright stays with the
translator or publisher), and Saheeh International is not freely licensed. A candidate
must have a clear licence that allows redistribution in a free app, be added here with
its source and terms, and be reviewed (#26) before it is bundled.

## Recitation audio

Recitation audio is **not** covered by LICENSE. It is licensed separately; see
[assets/audio/README.md](assets/audio/README.md).
