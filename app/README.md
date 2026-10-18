# Salah Companion app (Flutter)

The Android app shell. Prayer logic lives in the pure-Dart package
[`../packages/salah_core`](../packages/salah_core), which this app depends on.

## Run

```
cd app
flutter pub get
flutter run            # on a connected Android phone
flutter test
flutter analyze
```

## Privacy rules built into the Android project

- `android/app/src/release/AndroidManifest.xml` strips `INTERNET` and
  `ACCESS_NETWORK_STATE` from release builds. Debug builds keep `INTERNET` only for
  Flutter's development tools.
- Backup and device transfer of app data are off (`allowBackup="false"`,
  `res/xml/data_extraction_rules.xml`).
- `minSdk` is 26.

The launcher icon is a placeholder vector (no image files yet).
