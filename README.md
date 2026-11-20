# Stop Yapping 🎙️

<img src="packaging/Assets/stop-yapping.png" alt="Stop Yapping icon" width="96">

My friends are sick of hearing me yap every time I use Vowen. And I don’t have the brainpower to remember to mute and unmute myself every single time. So I made a little app to do it for me.

Stop Yapping mutes your call mic while you dictate with Vowen and brings it back when you're done. It works hands-free, too.

## 📦 Can I download it?

- **Windows** · Download the [Windows 11 installer](../../releases/tag/v0.2.1). It includes the audio driver in the same download. This preview is unsigned, so Windows may display an unknown publisher warning.
- **Mac** · Download the [macOS installer](../../releases/tag/v0.3.0-mac). It includes the Stop Yapping Mic virtual microphone in the same download. See [Set it up on a Mac](#-set-it-up-on-a-mac).

## 🎧 Set it up on Windows

You’ll need a Windows 11 x64 PC and [Vowen](https://vowen.ai/) with its local CLI integration turned on.

1. Open the installer and click **Install**. If you don’t already have VB-CABLE, setup will ask to install the included driver. That part needs an admin prompt and may need a restart.
2. Open **Stop Yapping** from Start. It uses your normal Windows microphone or lets you choose another in its settings.
3. In the calling apps you want to mute, pick **CABLE Output** as the microphone. Keep your regular mic in Vowen and your headphones as the Windows default output.

Stop Yapping can start when you sign in. You can pause it from its icon by the clock. If Windows tucks it away, look under the tray arrow.

## 🍎 Set it up on a Mac

You’ll need macOS 13 Ventura or later (Apple silicon or Intel) and [Vowen](https://vowen.ai/) with its local CLI integration turned on.

1. Open `StopYapping-…-macOS.pkg` and click **Install**. macOS asks for your password once, because the virtual microphone is a system audio driver. No restart needed.
   This preview isn’t notarized yet. If macOS says it can’t check the package, open **System Settings → Privacy & Security** and click **Open Anyway**.
2. Stop Yapping opens in the menu bar. Click **Allow** when it asks for microphone access. It uses your Mac’s default microphone, or pick another from its **Microphone** menu.
3. In the calling apps you want to mute, pick **Stop Yapping Mic** as the microphone. Keep your regular mic in Vowen.

Turn on **Open at login** from the menu bar icon so it’s always ready. The icon shows a crossed-out mic while your call mic is muted.

## 🛠️ Make it yours

Want Vowen-aware muting in your own app? Take the parts you need, adapt them, and build them right into your project. The code is [MIT-licensed](LICENSE). Keep the copyright and license notice when you share copies or substantial parts of the code.

## A couple more things

- **Delay** · The app buffers 180 ms by default to help catch the start of your first word. You can change that from the tray.
- **Uninstall** · Switch your calling apps back to your regular mic first. On Windows, remove Stop Yapping from **Windows Settings → Apps → Installed apps**. You can uninstall VB-CABLE separately if you no longer use it. On a Mac, choose **Uninstall Stop Yapping…** from the menu bar icon. It removes the app and Stop Yapping Mic.
- **Building it yourself** · See the [Windows packaging guide](packaging/README.md) or the [Mac build guide](mac/README.md).

**VB-CABLE** is made by [VB-Audio](https://vb-audio.com/Cable/) and is donationware. You can support them on their site.

**Stop Yapping Mic** on Mac is built from [BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio, licensed under GPL-3.0. It is an unofficial, renamed build. See [mac/THIRD-PARTY-NOTICES.txt](mac/THIRD-PARTY-NOTICES.txt).

Made for Vowen users. An independent project.
