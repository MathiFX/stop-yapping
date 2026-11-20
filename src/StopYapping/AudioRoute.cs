using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace StopYapping;

internal sealed class DelayedMicrophone : IWaveProvider
{
    private readonly object sync = new();
    private readonly BufferedWaveProvider queued;
    private readonly int delayBytes;
    private readonly int maximumLead;
    private readonly byte[] discard;
    private bool blocked;

    public DelayedMicrophone(WaveFormat format, int delayMilliseconds, bool initiallyBlocked)
    {
        WaveFormat = format;
        blocked = initiallyBlocked;
        delayBytes = WaveFormat.ConvertLatencyToByteSize(delayMilliseconds);
        maximumLead = delayBytes + WaveFormat.ConvertLatencyToByteSize(120);
        discard = new byte[WaveFormat.ConvertLatencyToByteSize(100)];
        queued = new BufferedWaveProvider(format)
        {
            BufferDuration = TimeSpan.FromSeconds(2),
            DiscardOnBufferOverflow = true,
            ReadFully = false
        };
    }

    public WaveFormat WaveFormat { get; }

    public void SetBlocked(bool value)
    {
        lock (sync)
        {
            if (blocked == value)
                return;
            queued.ClearBuffer();
            blocked = value;
        }
    }

    public void Write(byte[] buffer, int count)
    {
        lock (sync)
        {
            if (!blocked)
                queued.AddSamples(buffer, 0, count);
        }
    }

    public int Read(byte[] buffer, int offset, int count)
    {
        lock (sync)
        {
            // Drop an old backlog after the audio clock stalls or an endpoint runs faster.
            if (queued.BufferedBytes > maximumLead)
            {
                int excess = queued.BufferedBytes - delayBytes - count;
                while (excess > 0)
                    excess -= queued.Read(discard, 0, Math.Min(excess, discard.Length));
            }

            int ready = Math.Max(0, queued.BufferedBytes - delayBytes);
            int copied = blocked ? 0 : queued.Read(buffer, offset, Math.Min(ready, count));
            Array.Clear(buffer, offset + copied, count - copied);
            return count;
        }
    }
}

internal sealed record AudioEndpoint(string Id, string Name)
{
    public override string ToString() => Name;
}

internal sealed class AudioRoute : IDisposable
{
    private readonly MMDevice input;
    private readonly MMDevice output;
    private readonly WasapiCapture capture;
    private readonly WasapiOut playback;
    private Exception? failure;
    private int stopping;

    public static AudioEndpoint[] List(DataFlow flow)
    {
        using var devices = new MMDeviceEnumerator();
        return devices.EnumerateAudioEndPoints(flow, DeviceState.Active).Select(device =>
        {
            using (device)
                return new AudioEndpoint(device.ID, device.FriendlyName);
        }).ToArray();
    }

    public static AudioEndpoint? FindCable() => List(DataFlow.Render)
        .Where(IsCable)
        .OrderBy(endpoint => endpoint.Name.Contains("16 Ch", StringComparison.OrdinalIgnoreCase))
        .ThenByDescending(endpoint => endpoint.Name.StartsWith("CABLE Input", StringComparison.OrdinalIgnoreCase))
        .FirstOrDefault();

    public static bool IsCable(AudioEndpoint endpoint) =>
        endpoint.Name.Contains("VB-Audio Virtual Cable", StringComparison.OrdinalIgnoreCase);

    public static string? DefaultInputId()
    {
        using var devices = new MMDeviceEnumerator();
        if (!devices.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia))
            return null;
        using var endpoint = devices.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);
        return endpoint.ID;
    }

    public AudioRoute(string inputId, string outputId, int delayMs, bool initiallyMuted)
    {
        using var devices = new MMDeviceEnumerator();
        input = devices.GetDevice(inputId);
        output = devices.GetDevice(outputId);
        capture = new WasapiCapture(input, true, 15);
        playback = new WasapiOut(output, AudioClientShareMode.Shared, true, 15);
        Buffer = new DelayedMicrophone(capture.WaveFormat, delayMs, initiallyMuted);
        capture.DataAvailable += (_, data) => Buffer.Write(data.Buffer, data.BytesRecorded);
        capture.RecordingStopped += (_, state) => OnStopped(state.Exception);
        playback.PlaybackStopped += (_, state) => OnStopped(state.Exception);
    }

    public DelayedMicrophone Buffer { get; }
    public Exception? Failure => Volatile.Read(ref failure);

    public void Start()
    {
        playback.Init(Buffer);
        capture.StartRecording();
        playback.Play();
    }

    private void OnStopped(Exception? error)
    {
        if (Volatile.Read(ref stopping) == 0)
            Volatile.Write(ref failure, error ?? new IOException("The audio device stopped."));
    }

    public void Dispose()
    {
        Volatile.Write(ref stopping, 1);
        try { playback.Dispose(); }
        finally
        {
            try { capture.Dispose(); }
            finally
            {
                output.Dispose();
                input.Dispose();
            }
        }
    }
}
