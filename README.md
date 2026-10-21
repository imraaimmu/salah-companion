# Salah Companion

A free, private prayer companion for Muslims who are still learning their surahs.

Prop your phone up beside your prayer mat. When the app sees you standing in qiyam, it
recites Al-Fatiha and a short surah aloud (Al-Fatiha alone in rak'ahs 3 and 4), and you
recite along with it. It works for all five daily prayers. It stays silent
in every other position, and silent whenever it is unsure.

> **Status: design stage.** The pilot covers all five fard prayers (Fajr 2 rak'ahs,
> Dhuhr 4, Asr 4, Maghrib 3, Isha 4) on Android. The full
> product and technical spec is in [docs/SPEC.md](docs/SPEC.md). No app build exists yet.

## Promises that never change

- **Free forever.** No price, no ads, no in-app purchases, no paid features. Not here, and
  not in any fork (see [Licence](#licence)).
- **No video, ever.** Camera frames are turned into body-position numbers on your phone
  and thrown away immediately. Nothing is recorded or saved.
- **No data collection.** No account, no analytics, no crash reporting, no tracking.
- **Fully offline.** The Android app does not even request internet permission.

Pull requests that weaken any of these are declined.

## How it works

1. MediaPipe Pose Landmarker finds 33 body points in each camera frame, on the phone.
2. A posture classifier labels each moment: standing, bowing, prostrating or sitting.
3. A prayer state machine follows the order of the prayer you chose on Home (Fajr,
   Dhuhr, Asr, Maghrib or Isha, guessed from the clock), so it knows a standing after a
   bow (i'tidal) is not qiyam, and when the middle sitting comes.
4. Only when qiyam is confirmed does the app play the recitation, ayah by ayah, with
   gaps you choose so you can follow along.

Details, diagrams and acceptance criteria: [docs/SPEC.md](docs/SPEC.md).

## Contributing

Contributions are welcome: code, testing on your phone, recording test prayers
(landmark numbers only), translations, and review by people with knowledge of fiqh.
Start with [CONTRIBUTING.md](CONTRIBUTING.md) and issues labelled
`good first issue`.

## Licence

Salah Companion is **source-available**: anyone can read, use, change and share it free
of charge, but **no one may sell it or earn money from it, or from any part of it**.

- Code: [PolyForm Noncommercial License 1.0.0](LICENSE) plus the
  [Additional Terms](ADDITIONAL-TERMS.md) that forbid charging and all other ways of
  earning from it, for everyone.
- Name and logo: reserved for official free releases; forks must rename
  ([TRADEMARKS.md](TRADEMARKS.md)).
- Recitation audio: licensed separately ([assets/audio/README.md](assets/audio/README.md)).
- Third-party components: [NOTICE.md](NOTICE.md).

Because commercial use is forbidden, this is not "open source" under the OSI definition.

## A note on the prayer itself

The app is meant as a temporary companion while you learn. Scholars differ on following
an outside recitation during a fard prayer, and the project is seeking formal religious
review before its first release. Practice mode is there to help you memorise and stop
needing the app.
