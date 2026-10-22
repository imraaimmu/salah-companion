# Testing on a phone (Realme 16 Pro+)

This build is for testing only. It plays **placeholder tones, not recitation**, and its
posture thresholds have so far been tuned only on synthetic data. Use it for practice runs,
not for a real prayer.

APK: `salah-companion-arm64-v8a-release.apk` (about 37 MB; arm64, Android 8.0 or newer).
It is signed with a development key, not a store key.

## 1. Install

1. Copy the APK to the phone (USB cable into `Download/`, or send it to yourself in a chat
   or cloud drive and download it).
2. Open the **Files** app (or the app you downloaded it with), go to `Download`, and tap the
   APK.
3. Realme UI asks you to allow installs from that app: tap **Settings**, turn on **Allow
   from this source**, then go back. The same switch is under Settings > Apps > Special
   app access > Install unknown apps.
4. Tap **Install**. If Play Protect or Realme's security check warns about an unknown
   developer, choose **More details > Install anyway**. The app has no internet
   permission, so it cannot send anything anywhere.
5. Optional: turn the "install unknown apps" switch back off afterwards.

To update, install the new APK over the old one; your settings stay. To start over,
uninstall the app first.

## 2. First run

The setup screens explain the app (it works for all five daily prayers), ask for the **camera** (allow it: frames are processed
on the phone and dropped, nothing is recorded), let you pick surahs or keep **Auto**, pick
the opening-dua pause (Short, 6 s, is the default), and check the media volume. Turn the
media volume up to a comfortable level now: the app never changes it.

### Check the sound before you pray

Open **Settings** (the small icon on Home), scroll to **Audio** and tap **Test sound**.
It plays the first ayah of Al-Fatiha for a few seconds through exactly the same player
and audio settings the prayer uses. The line under the button says **Playing…**, then:

- **"You should hear a tone (placeholder audio)."** The audio works. In this build every
  ayah is a placeholder tone, because the qari's recording does not exist yet; you should
  hear a low tone ending in a short higher blip. If the screen says this but you heard
  nothing, check the media volume and that no Bluetooth device took the sound, and tell
  us.
- **"No sound: …"** followed by an error. Something stopped the audio. Please send us the
  exact text (a screenshot is best).
- **"Media volume is at zero …"** under it: turn the media volume up (the volume keys
  while the app is open) and try again.

## 3. Placing the phone

Put the phone **upright (portrait), back camera facing you, about hip height, 2 to 3 m
away, side-on to where you pray**. Stand near one edge of the camera's view and face the
other edge, so there is floor in front of you for sujood.

The **back camera** is the default and recommended (better in dim rooms). You can use the
**front camera** instead (screen facing you, so you can see yourself while placing the
phone): choose it in Settings → Camera, or tap the small **flip-camera button** at the top
right of the placement screen. The front camera usually sees a narrower area, so you may
need to move the phone further back; the whole body, head to feet, must still be in view.

Home shows **Start Fajr**, **Start Dhuhr** and so on: the prayer is guessed from the
phone's clock (Fajr 03:00–09:59, Dhuhr 10:00–15:29, Asr 15:30–17:59, Maghrib 18:00–19:29,
Isha 19:30–02:59). **Check the name on the button before you start**; tap another name in
the row under it to change it. A manual pick stays until the clock reaches the next
prayer's window.

Tap the Start button. The placement screen shows the chosen prayer at the top ("Dhuhr ·
4 rak'ahs"), the camera, your skeleton and four checks:

| Check | Passes when |
| --- | --- |
| Whole body in view | Head and near-side shoulder, hip, knee and ankle are inside the picture |
| Shoulder, hip, knee and ankle clear | Their average confidence is 0.7 or more for 3 s |
| Enough light | The camera delivers about 15 frames per second for 3 s (14.5 accepted) |
| Space for sujood | While you stand, the picture shows at least 0.2 x your height of floor in front of your toes. If recitation in rak'ah 2 or later is often missed, your head may be leaving the picture in sujood: step back a little |

The line above the checks says what to fix ("Move the phone back", "Step back a little so sujood fits in view", "Turn on a light", "Hold still"). **The prompts are text only in this
build, not spoken**, so you will need to glance at the screen, or have someone read it to
you. When all four pass, a quiet line reminds you to **raise your hands clearly for the
takbir** (rak'ah 1 recites only after the hand raise is seen), and a 5-second countdown
starts by itself: step onto your mat.

**Test both cameras.** Do the placement check (and, if you can, a practice prayer) once with
the back camera and once with the front camera:

- Tap the flip button: the preview should restart within a second or two with the other
  camera, the checks start over, and the choice is remembered (Settings → Camera shows it;
  the next Start opens the same camera).
- With the **front camera** the preview is mirrored, like a mirror: raise your right hand
  and it moves on the right of the screen. **The skeleton must sit exactly on your body**
  in the mirrored preview for both cameras; report it if it is on the wrong side or
  offset.
- Face left in one run and right in another, with each camera: the checks and the prayer
  should behave the same.
- Compare "Enough light" and the clear-points check between the cameras in a dim room.

## 4. A practice prayer

Pray the chosen prayer as you normally would (a practice run), with the phone placed as
above. **The app follows the prayer you chose**: if you pray 2 rak'ahs in a Dhuhr session,
it expects a third rak'ah and will play Al-Fatiha when you stand up after the salam.
The screen goes black with a tiny dim dot near the bottom: grey while it can see you,
**amber when it has lost you**.

What the tones mean:

- **Each ayah is one tone, 1.5 to 3 s long, ending in a short higher blip.** The blip
  marks the end of the ayah. Each surah has its own pitch; **Al-Fatiha is the lowest**.
- After your **takbir** (hands raised) and once you stand still, there are **6 s of
  silence** (the opening dua), then Al-Fatiha's 7 tones.
- After Al-Fatiha, a slightly longer silence (time for Ameen), then the surah's tones at a
  higher pitch, then silence.
- The silence between tones is the gap after each ayah (1.5 s by default, in Settings).
- **Nothing should sound during ruku, sujood, sitting, or after the salam.** If you bow
  before the surah ends, the tone should fade out within about half a second.
- When you stand up for **rak'ah 2**, about 1.5 s of silence, then Al-Fatiha (low tones)
  and the second surah.
- In Dhuhr, Asr, Maghrib and Isha: **nothing during the middle sitting** after rak'ah 2.
  When you stand up for **rak'ah 3 (and 4)**, about 1.5 s of silence, then **Al-Fatiha
  only** (7 low tones, no surah), the same in Dhuhr and Asr as in the others.
- If the takbir hand raise is not seen, rak'ah 1 stays silent on purpose. Rak'ah 2 should
  still play.

### Seeing what the app sees (tracking details)

If you hear nothing during a practice prayer, turn on **Settings → Testing → Show
tracking details during prayer (for testing)** and pray again. The prayer screen then
shows a few lines of small, dim text at the bottom (updated about 4 times a second; off,
the screen stays fully black):

- **Posture:** what the app thinks you are doing now (standing, bowing, prostrating,
  sitting, unknown), after smoothing, with the raw reading for the latest frame in
  brackets, and "no person" when nobody is seen.
- **State:** where it is in the prayer (waiting, takbir, qiyam, ruku, itidal, sujood,
  middle/final sitting) and the rak'ah number, plus "tracking lost" when it has lost you.
- **Takbir seen:** yes once a takbir hand raise was detected. If this stays **no** after
  you raised your hands, rak'ah 1 is silent by design: raise your hands higher and more
  clearly, side-on to the camera.
- **Audio:** the last recitation event: Start, Pause, Resume or Stop, with the rak'ah
  ("Start (rak'ah 1)"). "not played" after Start means the start was skipped (for example
  tracking was lost at that moment).
- **Interruption** and **Audio problem:** shown only when one happened; an audio problem
  is the error the player reported (please send us the exact text).

Glancing at the text spoils the stillness of the black screen, so use it only for test
runs, and turn it off afterwards. A photo of the screen at the moment the sound should
have started is very useful.

**To end early, long-press anywhere on the black screen for 1.5 s**, then tap **End**.
The Back button or switching to another app also ends the session (silently).

The summary ("Fajr completed · 2 rak'ahs", "Maghrib completed · 3 rak'ahs", with the
rak'ahs it counted) appears when you **get up from the final sitting** (or after 3 minutes
of sitting). It returns home by itself after 30 s. Auto uses one surah pair per day for
all that day's prayers, and moves on to the next pair at the first completed prayer of a
new day (see the line under the Start button).

Worth trying once each: a normal practice run of a 2-, 3- and 4-rak'ah prayer; one without raising your hands at the
takbir; stepping out of view for a few seconds while a tone plays; and a run in the dim
light you would really have at Fajr.

## 5. What to report back

For each run, please note:

1. **Placement:** which checks passed, which one stayed unticked and what the message
   said, how long until the countdown started, and where the phone was (distance,
   height, which camera: back or front).
2. **Rak'ah 1 start:** after the takbir and standing still, did the low tones start
   (after about 6 s)? Too early, too late, or not at all?
3. **Stop on bowing:** when you went into ruku, did the sound stop, and how quickly
   (immediately, about half a second, a second or more, or not until the ruku was
   complete)?
4. **Rak'ahs 2 to 4:** did each start about 1.5 s after you stood up (from sujood, or
   from the middle sitting for rak'ah 3)? Did rak'ahs 3 and 4 play Al-Fatiha only? Was
   the middle sitting silent?
5. **Any sound at the wrong time:** in ruku, i'tidal, sujood, sitting, after the salam, or
   twice in one rak'ah. This is the most important thing to report, with roughly when it
   happened.
6. **The dot:** did it turn amber when you were in view, or stay grey when you were not?
7. **End of session:** did the summary appear when you got up? Did it say completed, with
   the right prayer and number of rak'ahs?
8. **Light and speed:** did "Enough light" pass in your lighting (dim at Fajr and Isha), and did it ever
   take long to pass? Note any difference between the back and front camera.
9. **Heat and battery:** did the phone get warm? Battery percentage before and after a
   session.
10. **No sound at all:** what Settings → Test sound said, and, with the tracking details
    on, what the Takbir seen, Audio and Audio problem lines showed.
11. Anything else odd (a crash, the camera not opening, the app closing).

A short audio recording of the run on a second phone, with you saying "bowing" or
"standing" as you move, helps us time the tones against your movement. Do not record
video of a real prayer.

## Known limitations of this build

- **Placeholder tones, not recitation.** The qari's recordings are not in the app yet.
  The tones exist only to test timing; this build must not be shared as a prayer app.
  Test sound and the prayer both play these tones until the recording exists.
- **Tuned on synthetic data only.** The posture rules (standing, bowing, prostrating,
  sitting, the takbir hand raise) and every hold time were tuned against generated stick
  figures, not real people or real rooms. Expect mistakes; that is what this test is for.
- **Spoken placement prompts are not wired yet**: the placement screen shows text only.
- The floor-space check is a heuristic: it checks that the camera can see enough floor in
  front of you, not that the floor is actually clear.
- Auto surah pairs are a draft pending religious review. Practice mode is not built yet.
- Small phone tilt is corrected for, but do not move or bump the phone during a session:
  the standing height is calibrated at the start.
- With Bluetooth headphones the tones can start a little late (Bluetooth delay).
