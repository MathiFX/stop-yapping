# Stop Yapping

I dictate a lot with Vowen. My friends on Discord didn't sign up to hear me talk to my computer. So I made a little Windows tray app that quietly mutes my call mic while I dictate and brings it back when I'm done.

Use it with Discord or any call app that lets you pick a microphone. It follows Vowen's recording state, so hands-free dictation works without holding a key. There are no Discord mute sounds.

## Getting it

The source code and Windows package build are public. A signed download is pending. When one is ready, it will be posted under [Releases](../../releases).

## Setup

1. Use Windows 11 on an x64 PC and a version of [Vowen](https://vowen.ai/) with its local CLI integration enabled. The separate command-line executable is optional.
2. Install [VB-CABLE from VB-Audio](https://vb-audio.com/Cable/) and follow its restart instructions. In Windows Sound settings, make sure your real microphone and speakers are still your defaults.
3. Install Stop Yapping, open it from Start, then choose your real microphone in its tray settings if needed. Leave Vowen on the real microphone.
4. In Discord **Voice & Video**, select **CABLE Output** as the microphone. Keep your usual headphones or speakers as the output. Use **Mic Test** to try talking before, during, and after dictation.

Stop Yapping starts at sign-in after you first open it. Its tray menu lets you pause automatic muting without interrupting your mic. You can manage automatic startup in Windows Settings.

The app adds 180 ms of buffering by default so it has time to discard the beginning of a dictation. You can adjust that under **First-word protection**. The timing depends on how quickly Vowen reports that recording started. If Vowen stops responding, Stop Yapping lets your call mic through.

## Uninstall

Choose your real microphone again in Discord and any other apps using **CABLE Output**. Then go to **Settings → Apps → Installed apps → Stop Yapping → Uninstall**. Windows removes the app, its startup entry and its package-local settings. VB-CABLE has its own uninstaller and can be removed separately if nothing else uses it.

## Privacy

Audio stays on your PC and is only buffered in memory. The app sends no audio or telemetry to a server. It reads Vowen's recording state over localhost and sends microphone audio to VB-CABLE, where your chosen call apps can receive it.

Stop Yapping is an independent project for Vowen users.

## Build from source

See [Windows packaging](packaging/README.md). The code is [MIT-licensed](LICENSE).
