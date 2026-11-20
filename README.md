# Stop Yapping 🎙️

I yap at Vowen a lot. My friends on Discord didn't sign up for the audiobook.

Stop Yapping mutes your call mic while you dictate with Vowen and brings it back when you're done. It works hands-free, too.

## 📦 Can I download it?

**The source code is available now. The Windows installer is coming later.** It still needs a signature Windows can verify. When it's ready, it'll be in [Releases](../../releases).

## 🎧 How setup will work

You’ll need a Windows 11 x64 PC and [Vowen](https://vowen.ai/) with its local CLI integration turned on.

1. Install [VB-CABLE](https://vb-audio.com/Cable/) once. It needs an admin prompt and may ask you to restart. Keep your real mic and headphones as the Windows defaults.
2. Double-click the Stop Yapping installer, click **Install**, then open **Stop Yapping** from Start.
3. In Discord → **Voice & Video**, pick **CABLE Output** as the microphone. Keep your real mic selected in Vowen.

Want to use it in another call app? Pick **CABLE Output** as the mic there, too. Stop Yapping starts when you sign in, and you can pause it from its icon by the clock.

## 🛠️ Make it yours

Fork it, change it, share it or sell your own version. It's [MIT-licensed](LICENSE). Just keep the copyright and license notice with copies or substantial parts of the code you share.

## A couple more things

- **Privacy** · Stop Yapping keeps your audio on your PC and sends no telemetry.
- **Uninstall** · Switch Discord back to your real mic, then remove Stop Yapping from **Windows Settings → Apps → Installed apps**. You can uninstall VB-CABLE separately if you no longer use it.
- **Building it yourself** · See the [Windows packaging guide](packaging/README.md).

Made for Vowen users. An independent project.
