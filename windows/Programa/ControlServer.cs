using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace Programa;

/// <summary>A control command failed in a way the caller should see, with a v2 error code.</summary>
internal sealed class ControlException(string code, string message, object? data = null) : Exception(message)
{
    public string Code { get; } = code;
    /// <summary>The error's `data` object (a timeout's `timeout_ms`), or null.</summary>
    public object? Data { get; } = data;
}

/// <summary>
/// The Windows counterpart of the macOS control socket: a named pipe speaking the same v2 protocol
/// (contracts/v2/protocol.json), one JSON request per line answered by one JSON line. Only the
/// current user can connect. Requests run through <see cref="_handler"/>, which the window runs on
/// its UI thread.
/// </summary>
internal sealed class ControlServer : IDisposable
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    private readonly Func<string, JsonElement, Task<object?>> _handler;
    private readonly CancellationTokenSource _stop = new();

    internal ControlServer(Func<string, JsonElement, Task<object?>> handler) => _handler = handler;

    /// <summary>Development builds listen on their own pipe, so they never answer for the installed app.</summary>
    internal static string PipeName { get; } =
        (BuildIdentity.Value.Contains("0.0.0-dev", StringComparison.Ordinal) ? "programa-dev-" : "programa-") + Environment.UserName;

    /// <summary>The path exported to terminals as PROGRAMA_SOCKET_PATH.</summary>
    internal static string PipePath => $@"\\.\pipe\{PipeName}";

    internal void Start() => _ = Task.Run(AcceptLoopAsync);

    private async Task AcceptLoopAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            NamedPipeServerStream pipe;
            try
            {
                pipe = new NamedPipeServerStream(PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            }
            catch (IOException error)
            {
                // Another Programa of the same build already owns the pipe.
                LaunchLog.Write($"control: pipe {PipeName} unavailable: {error.Message}");
                return;
            }
            try
            {
                await pipe.WaitForConnectionAsync(_stop.Token);
            }
            catch (OperationCanceledException)
            {
                await pipe.DisposeAsync();
                return;
            }
            _ = Task.Run(() => ServeAsync(pipe));
        }
    }

    private async Task ServeAsync(NamedPipeServerStream pipe)
    {
        await using (pipe)
        {
            using var reader = new StreamReader(pipe, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: false, leaveOpen: true);
            await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true, NewLine = "\n" };
            // Answers and pushed event frames share the pipe, one whole line at a time.
            var gate = new SemaphoreSlim(1, 1);
            async Task Write(string text)
            {
                await gate.WaitAsync();
                try { await writer.WriteLineAsync(text); }
                finally { gate.Release(); }
            }
            var connection = new Connection(Write);
            try
            {
                while (await reader.ReadLineAsync(_stop.Token) is { } line)
                {
                    if (line.Length == 0) continue;
                    await Write(await HandleLineAsync(line, connection));
                    // A new subscription starts pushing only after its answer.
                    connection.Subscription?.Start();
                }
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException)
            {
                // The client went away or the app is closing.
            }
            finally
            {
                if (connection.Subscription is { } subscription) EventHub.Remove(subscription);
            }
        }
    }

    /// <summary>One client connection: how to write to it, and its subscription (at most one).</summary>
    internal sealed class Connection(Func<string, Task> write)
    {
        internal Func<string, Task> Write { get; } = write;
        internal Subscription? Subscription { get; set; }
    }

    internal Task<string> HandleLineAsync(string line) => HandleLineAsync(line, null);

    internal async Task<string> HandleLineAsync(string line, Connection? connection)
    {
        object? id = null;
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new ControlException("invalid_request", "A request is one JSON object.");
            if (root.TryGetProperty("id", out var requestId)) id = requestId.Clone();
            var method = root.TryGetProperty("method", out var name) && name.ValueKind == JsonValueKind.String ? name.GetString() : null;
            if (string.IsNullOrEmpty(method)) throw new ControlException("invalid_request", "method is required.");
            var parameters = root.TryGetProperty("params", out var given) && given.ValueKind == JsonValueKind.Object
                ? given.Clone()
                : JsonDocument.Parse("{}").RootElement.Clone();
            var result = method switch
            {
                "subscribe" => Subscribe(parameters, connection),
                "unsubscribe" => Unsubscribe(connection),
                _ => await _handler(method, parameters),
            };
            return JsonSerializer.Serialize(new { id, ok = true, result = result ?? new { } }, Json);
        }
        catch (ControlException error)
        {
            return Failure(id, error.Code, error.Message, error.Data);
        }
        catch (JsonException error)
        {
            return Failure(id, "invalid_request", $"Not valid JSON: {error.Message}");
        }
        catch (Exception error)
        {
            LaunchLog.Write($"control: request failed: {error}");
            return Failure(id, "internal_error", error.Message);
        }
    }

    private static string Failure(object? id, string code, string message, object? data = null) =>
        data is null
            ? JsonSerializer.Serialize(new { id, ok = false, error = new { code, message } }, Json)
            : JsonSerializer.Serialize(new { id, ok = false, error = new { code, message, data } }, Json);

    /// <summary>`subscribe`: replaces this connection's subscription. `output` needs `surface_ids`.</summary>
    private static object Subscribe(JsonElement p, Connection? connection)
    {
        if (connection is null) throw new ControlException("unavailable", "subscribe needs a connection that stays open.");
        var classes = p.TryGetProperty("classes", out var given) && given.ValueKind == JsonValueKind.Array
            ? given.EnumerateArray().Select(item => item.ValueKind == JsonValueKind.String ? item.GetString()! : "").ToList()
            : [];
        if (classes.Count == 0) throw new ControlException("invalid_params", "classes is required: agent_state, output, workspace_lifecycle or needs_input.");
        if (classes.FirstOrDefault(name => !EventHub.Classes.Contains(name)) is { } unknown)
            throw new ControlException("invalid_params", $"Unknown event class '{unknown}'.");
        var surfaces = p.TryGetProperty("surface_ids", out var ids) && ids.ValueKind == JsonValueKind.Array
            ? ids.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.String).Select(item => item.GetString()!).ToList()
            : [];
        if (classes.Contains("output") && surfaces.Count == 0) throw new ControlException("invalid_params", "surface_ids is required with the output class.");
        if (connection.Subscription is { } previous) EventHub.Remove(previous);
        var subscription = new Subscription(classes.Distinct().ToList(), surfaces, connection.Write);
        connection.Subscription = subscription;
        EventHub.Add(subscription);
        return new { subscription_id = subscription.Id, classes = subscription.Classes, surface_ids = subscription.SurfaceIds, max_queued_events = EventHub.MaxQueuedEvents };
    }

    private static object Unsubscribe(Connection? connection)
    {
        if (connection?.Subscription is { } subscription) EventHub.Remove(subscription);
        if (connection is not null) connection.Subscription = null;
        return new { };
    }

    public void Dispose()
    {
        _stop.Cancel();
        _stop.Dispose();
    }
}
