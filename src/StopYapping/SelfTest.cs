using NAudio.Wave;

namespace StopYapping;

internal static class SelfTest
{
    public static int Run()
    {
        try
        {
            _ = Preferences.Load();
            var format = new WaveFormat(8000, 16, 1);
            var gate = new DelayedMicrophone(format, 100, false);
            byte[] normal = Enumerable.Repeat((byte)12, 1600).ToArray();
            byte[] protectedSpeech = Enumerable.Repeat((byte)42, 1600).ToArray();
            byte[] read = new byte[1600];

            gate.Write(normal, normal.Length);
            gate.Read(read, 0, read.Length);
            Require(read.All(value => value == 0), "Audio escaped the initial delay.");

            gate.Write(protectedSpeech, protectedSpeech.Length);
            gate.Read(read, 0, read.Length);
            Require(read.SequenceEqual(normal), "Normal audio did not arrive after the configured delay.");

            gate.SetBlocked(true);
            gate.Write(protectedSpeech, protectedSpeech.Length);
            gate.Read(read, 0, read.Length);
            Require(read.All(value => value == 0), "Audio escaped while muted.");

            gate.SetBlocked(false);
            gate.Write(normal, normal.Length);
            gate.Read(read, 0, read.Length);
            Require(read.All(value => value == 0), "Audio queued before or during mute survived.");
            gate.Write(normal, normal.Length);
            gate.Read(read, 0, read.Length);
            Require(read.SequenceEqual(normal), "Normal audio did not resume after mute.");

            var missingEndpoint = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "server.json");
            using var monitor = new VowenMonitor(missingEndpoint);
            VowenState state = monitor.ReadAsync(CancellationToken.None).GetAwaiter().GetResult();
            Require(state == VowenState.Unavailable, "A missing Vowen endpoint must release the mute.");

            var usbMic = new AudioEndpoint("usb", "USB microphone");
            var headset = new AudioEndpoint("headset", "Headset microphone");
            Require(AudioRoute.ChooseInput([usbMic, headset], null, "headset") == headset, "The Windows default was ignored.");
            Require(AudioRoute.ChooseInput([usbMic, headset], "usb", "headset") == usbMic, "The selected microphone was ignored.");
            Require(AudioRoute.ChooseInput([usbMic], null, "cable") == usbMic, "The only available input was ignored.");
            Require(AudioRoute.ChooseInput([usbMic, headset], null, "cable") is null, "An ambiguous source was selected.");
            Require(AudioRoute.ChooseInput([headset], "usb", "headset") is null, "A disconnected source was silently switched.");
            Console.WriteLine("Audio buffer, microphone selection and Vowen disconnect tests passed.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }
}
