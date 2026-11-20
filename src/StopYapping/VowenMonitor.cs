using System.Net.Http.Json;
using System.Net.Http.Headers;
using System.Text.Json;

namespace StopYapping;

internal enum VowenState { Unavailable, Idle, Recording }

internal sealed class VowenMonitor(string discoveryPath) : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly HttpClient http = new(new SocketsHttpHandler
    {
        UseProxy = false,
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromMilliseconds(150)
    }) { Timeout = TimeSpan.FromMilliseconds(200) };

    private Discovery? discovery;

    public async Task RunAsync(Action<VowenState> publish, CancellationToken stop)
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                VowenState state = await ReadAsync(stop).ConfigureAwait(false);
                publish(state);
                await Task.Delay(state == VowenState.Unavailable ? 100 : 25, stop).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
    }

    public async Task<VowenState> ReadAsync(CancellationToken stop)
    {
        try
        {
            if (discovery is null)
            {
                using var file = new FileStream(discoveryPath, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
                discovery = await JsonSerializer.DeserializeAsync<Discovery>(file, JsonOptions, stop)
                    .ConfigureAwait(false);
            }

            if (discovery is not { Port: > 0 and <= 65535, Token.Length: > 0 })
            {
                discovery = null;
                return VowenState.Unavailable;
            }

            using var request = new HttpRequestMessage(HttpMethod.Get,
                $"http://127.0.0.1:{discovery.Port}/v1/status");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", discovery.Token);
            using var response = await http.SendAsync(request, stop).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            var status = await response.Content.ReadFromJsonAsync<Status>(JsonOptions, stop)
                .ConfigureAwait(false);
            if (status?.Recording is bool recording)
                return recording ? VowenState.Recording : VowenState.Idle;
        }
        catch (OperationCanceledException) when (!stop.IsCancellationRequested) { }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or HttpRequestException or JsonException or FormatException) { }

        discovery = null;
        return VowenState.Unavailable;
    }

    public void Dispose() => http.Dispose();

    private sealed record Discovery(int Port, string? Token);
    private sealed record Status(bool? Recording);
}
