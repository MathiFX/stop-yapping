# Building Stop Yapping for macOS

You need macOS 13 or later with Xcode installed. Then run:

```bash
./mac/build.sh
```

It produces `artifacts/StopYapping-<version>-macOS.pkg`, a single installer with:

- **Stop Yapping.app** in `/Applications`, a menu bar app written in Swift (`mac/Sources`).
- **StopYapping.driver** in `/Library/Audio/Plug-Ins/HAL`, the Stop Yapping Mic virtual microphone.

## How it works

Stop Yapping reads Vowen’s local CLI endpoint from `~/Library/Application Support/vowen/cli/server.json` and polls `/v1/status`.
It copies your real microphone into a hidden output-only device, *Stop Yapping Feed*, with a short delay to catch the first word.
Whatever goes into the feed comes out of the visible, input-only **Stop Yapping Mic**. While Vowen records, the feed goes silent and the queued audio is thrown away.

By default the call mic is an exact copy of your microphone, so the noise suppression in Discord, Meet, FaceTime and other call apps works as designed. If you want, **Reduce background hiss** in the menu adds a gentle noise gate that learns the hiss level and lowers it by about 20 dB while you’re silent.

## Reliability and logs

The app runs as a launchd agent (`Contents/Library/LaunchAgents/com.stopyapping.app.agent.plist`), registered on first launch. It opens at login, and launchd restarts it a few seconds after a crash. Quitting from the menu is a clean exit, so it stays closed until the next login.

Everything worth knowing goes to `~/Library/Logs/Stop Yapping/StopYapping.log`: starts and stops with the reason, audio route changes and errors, Vowen state changes, sleep and wake. A crash writes the signal and a backtrace there before macOS writes its own report. **Show log** in the menu opens the folder.

Run the built-in checks with:

```bash
"mac/build/Stop Yapping.app/Contents/MacOS/StopYapping" --self-test
```

## The driver

The driver is BlackHole by Existential Audio (GPL-3.0), cloned at a pinned commit and built with different compile-time settings: name, bundle ID, plug-in factory ID, icon, one channel, and the input/output split described above.
BlackHole’s license doesn’t allow its name or branding on modified builds, so this one is renamed everywhere.
`mac/THIRD-PARTY-NOTICES.txt` carries the license and where to get the source. It ships inside the app.

## Signing and notarization

By default the app and driver are signed ad hoc and the package is unsigned. That’s fine on the machine that built it.
For a download that opens without warnings, you need an Apple Developer ID. Set these variables before building:

```bash
APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
PKG_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
NOTARY_PROFILE="stop-yapping" \
./mac/build.sh
```

`NOTARY_PROFILE` is a profile saved with `xcrun notarytool store-credentials`.
