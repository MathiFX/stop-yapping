# Stop Yapping 🎙️

<img src="packaging/Assets/stop-yapping.png" alt="Stop Yapping icon" width="96">

My friends are sick of hearing me yap every time I use Vowen. And I don’t have the brainpower to remember to mute and unmute myself every single time. So I made a little app to do it for me.

Stop Yapping mutes your call mic while you dictate with Vowen and brings it back when you're done. It works hands-free, too.

## 📦 Can I download it?

Download **StopYapping-Setup-x64.exe** from [Releases](../../releases). It includes the audio driver, so one download is enough. This preview installer is unsigned, so Windows may show an unknown publisher warning or block it on some PCs.

## 🎧 Set it up

You’ll need a Windows 11 x64 PC and [Vowen](https://vowen.ai/) with its local CLI integration turned on.

1. Open the installer and click **Install**. If you don’t already have VB-CABLE, setup will ask to install the included driver. That part needs an admin prompt and may need a restart.
2. Open **Stop Yapping** from Start. It uses your normal Windows microphone or lets you choose another in its settings.
3. In the calling apps you want to mute, pick **CABLE Output** as the microphone. Keep your regular mic in Vowen and your headphones as the Windows default output.

Stop Yapping can start when you sign in. You can pause it from its icon by the clock. If Windows tucks it away, look under the tray arrow.

## 🛠️ Make it yours

Fork it, change it, share it or sell your own version. It's [MIT-licensed](LICENSE). Just keep the copyright and license notice with copies or substantial parts of the code you share.

## A couple more things

- **Delay** · The app buffers 180 ms by default to help catch the start of your first word. You can change that from the tray.
- **Uninstall** · Switch your calling apps back to your regular mic, then remove Stop Yapping from **Windows Settings → Apps → Installed apps**. You can uninstall VB-CABLE separately if you no longer use it.
- **Building it yourself** · See the [Windows packaging guide](packaging/README.md).

**VB-CABLE** is made by [VB-Audio](https://vb-audio.com/Cable/) and is donationware. You can support them on their site.

Made for Vowen users. An independent project.
