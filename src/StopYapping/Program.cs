using NAudio.CoreAudioApi;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Windows.Storage;

namespace StopYapping;

internal static class Program
{
    internal static readonly string DiscoveryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "vowen", "cli", "server.json");

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--self-test"))
            return SelfTest.Run();
        using var mutex = new Mutex(true, @"Local\StopYapping", out bool isFirst);
        using var settingsRequested = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\StopYapping.Settings");
        if (args.Contains("--settings"))
            settingsRequested.Set();
        if (!isFirst)
            return 0;

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var app = new TrayApp(settingsRequested);
        Application.Run(app);
        return 0;
    }
}

internal sealed record Preferences(string? MicrophoneId = null, int DelayMs = 180, bool Paused = false)
{
    private static readonly string Location = Path.Combine(SettingsFolder(), "settings.json");

    private static string SettingsFolder()
    {
        uint length = 0;
        return GetCurrentPackageFamilyName(ref length, IntPtr.Zero) == 122
            ? ApplicationData.Current.LocalFolder.Path
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StopYapping");
    }

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern int GetCurrentPackageFamilyName(ref uint length, IntPtr familyName);

    public static Preferences Load()
    {
        try
        {
            var values = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Location));
            return values is null ? new() : values with { DelayMs = Math.Clamp(values.DelayMs, 60, 500) };
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return new();
        }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Location)!);
        File.WriteAllText(Location + ".tmp", JsonSerializer.Serialize(this));
        File.Move(Location + ".tmp", Location, true);
    }
}

internal sealed class TrayApp : ApplicationContext
{
    private readonly object stateLock = new();
    private readonly NotifyIcon tray;
    private readonly ContextMenuStrip menu = new();
    private readonly ToolStripMenuItem status = new() { Enabled = false };
    private readonly ToolStripMenuItem pause = new();
    private readonly Icon appIcon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? (Icon)SystemIcons.Application.Clone();
    private readonly System.Windows.Forms.Timer refresh = new() { Interval = 150 };
    private readonly VowenMonitor monitor = new(Program.DiscoveryPath);
    private readonly CancellationTokenSource stop = new();
    private readonly Task monitoring;
    private Preferences preferences = Preferences.Load();
    private VowenState vowen;
    private AudioRoute? route;
    private SettingsWindow? openSettings;
    private string audioStatus = "Starting audio…";
    private long nextAttempt;
    private bool exiting;

    public TrayApp(EventWaitHandle settingsRequested)
    {
        tray = new NotifyIcon
        {
            Icon = appIcon, Text = "Stop Yapping", Visible = true, ContextMenuStrip = menu
        };
        menu.Items.Add(status);
        menu.Items.Add(new ToolStripSeparator());
        pause.Click += (_, _) => TogglePause();
        menu.Items.Add(pause);
        menu.Items.Add("Settings…", null, (_, _) => ShowSettings());
        menu.Items.Add("Windows startup settings…", null, (_, _) => OpenStartupSettings());
        menu.Items.Add("VB-CABLE by VB-Audio…", null, (_, _) => OpenLink("https://vb-audio.com/Cable/"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => ExitThread());
        tray.DoubleClick += (_, _) => ShowSettings();
        monitoring = Task.Run(() => monitor.RunAsync(UpdateVowen, stop.Token));
        refresh.Tick += (_, _) =>
        {
            RefreshState();
            if (settingsRequested.WaitOne(0))
                ShowSettings();
        };
        refresh.Start();
        RefreshState();
    }

    private void UpdateVowen(VowenState newState)
    {
        lock (stateLock)
        {
            vowen = newState;
            route?.Buffer.SetBlocked(ShouldMute);
        }
    }

    private bool ShouldMute => !preferences.Paused && vowen == VowenState.Recording;

    private void RefreshState()
    {
        if (route?.Failure is Exception failure)
        {
            RouteError(failure);
            StopRoute();
        }
        if (route is null && Environment.TickCount64 >= nextAttempt)
            StartRoute();

        string label;
        lock (stateLock)
        {
            label = route is null ? audioStatus
                : preferences.Paused ? "Automatic muting paused"
                : ShouldMute ? "Dictating · Virtual mic muted"
                : vowen == VowenState.Unavailable ? "Vowen unavailable · Mic live"
                : "Ready · Mic live";
            pause.Text = preferences.Paused ? "Resume automatic muting" : "Pause automatic muting";
        }

        status.Text = label;
        if (openSettings is not null)
            openSettings.RouteStatus = label;
        string tooltip = "Stop Yapping · " + label;
        tray.Text = tooltip[..Math.Min(63, tooltip.Length)];
    }

    private void StartRoute()
    {
        nextAttempt = Environment.TickCount64 + 2000;
        AudioRoute? candidate = null;
        try
        {
            AudioEndpoint? cable = AudioRoute.FindCable();
            if (cable is null)
            {
                audioStatus = "VB-CABLE is missing";
                return;
            }
            AudioEndpoint[] inputs = AudioRoute.List(DataFlow.Capture).Where(endpoint => !AudioRoute.IsCable(endpoint)).ToArray();
            AudioEndpoint? input = GetInput(inputs);
            if (input is null)
            {
                audioStatus = "Select an available microphone";
                return;
            }

            candidate = new AudioRoute(input.Id, cable.Id, preferences.DelayMs, true);
            lock (stateLock)
            {
                candidate.Buffer.SetBlocked(ShouldMute);
                route = candidate;
            }
            candidate.Start();
        }
        catch (Exception error)
        {
            RouteError(error);
            if (candidate is not null)
                StopRoute();
        }
    }

    private AudioEndpoint? GetInput(AudioEndpoint[] inputs) =>
        AudioRoute.ChooseInput(inputs, preferences.MicrophoneId,
            preferences.MicrophoneId is null ? AudioRoute.DefaultInputId() : null);

    private void RouteError(Exception error)
    {
        audioStatus = "Audio unavailable · Retrying";
        Trace.WriteLine(error.Message, "Stop Yapping");
        nextAttempt = Environment.TickCount64 + 2000;
    }

    private void StopRoute()
    {
        AudioRoute? current;
        lock (stateLock)
        {
            current = route;
            route = null;
            current?.Buffer.SetBlocked(true);
        }
        try { current?.Dispose(); }
        catch (Exception error) { RouteError(error); }
    }

    private void TogglePause()
    {
        lock (stateLock)
        {
            preferences = preferences with { Paused = !preferences.Paused };
            route?.Buffer.SetBlocked(ShouldMute);
        }
        TrySave();
        RefreshState();
    }

    private static void OpenStartupSettings()
        => OpenLink("ms-settings:startupapps");

    private static void OpenLink(string destination)
    {
        try
        {
            Process.Start(new ProcessStartInfo(destination) { UseShellExecute = true });
        }
        catch (Exception error) { ShowError(error.Message); }
    }

    private void ShowSettings()
    {
        if (openSettings is not null)
        {
            openSettings.Activate();
            return;
        }
        try
        {
            var inputs = AudioRoute.List(DataFlow.Capture).Where(endpoint => !AudioRoute.IsCable(endpoint)).ToArray();
            using var form = new SettingsWindow(inputs, GetInput(inputs), preferences.DelayMs, AudioRoute.FindCable() is not null)
            {
                Icon = appIcon,
                RouteStatus = status.Text
            };
            openSettings = form;
            if (form.ShowDialog() != DialogResult.OK)
                return;

            lock (stateLock)
                preferences = preferences with { MicrophoneId = form.Microphone!.Id, DelayMs = form.DelayMs };
            TrySave();
            StopRoute();
            nextAttempt = 0;
            RefreshState();
        }
        catch (Exception error) { ShowError(error.Message); }
        finally { openSettings = null; }
    }

    private void TrySave()
    {
        try { preferences.Save(); }
        catch (Exception error) { ShowError(error.Message); }
    }

    private static void ShowError(string message) =>
        MessageBox.Show(message, "Stop Yapping", MessageBoxButtons.OK, MessageBoxIcon.Warning);

    protected override void ExitThreadCore()
    {
        if (exiting)
            return;
        exiting = true;
        refresh.Stop();
        tray.Visible = false;
        stop.Cancel();
        try { monitoring.GetAwaiter().GetResult(); }
        finally
        {
            StopRoute();
            monitor.Dispose();
            stop.Dispose();
            refresh.Dispose();
            tray.Dispose();
            appIcon.Dispose();
            menu.Dispose();
            base.ExitThreadCore();
        }
    }
}
