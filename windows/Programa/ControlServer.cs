using System.Collections.Concurrent;
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
    internal static string PipeName { get; } = $"programa{BuildIdentity.DevSuffix}-{Environment.UserName}";

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

    /// <summary>How a connection may use the pipe (automation.socketControlMode), decided when it connects.</summary>
    internal enum Access { Allowed, NeedsLogin, Denied, Off }

    /// <summary>automation.socketControlMode for a client, as on macOS, except that password mode also lets
    /// Programa terminals in without a login (the macOS CLI reads the saved password itself, so terminals
    /// never notice the mode there either). Every mode admits only the current user: the pipe's ACL.</summary>
    internal static Access Decide(string mode, bool fromProgramaTerminal) => mode switch
    {
        "off" => Access.Off,
        "automation" => Access.Allowed,
        "password" => fromProgramaTerminal ? Access.Allowed : Access.NeedsLogin,
        _ => fromProgramaTerminal ? Access.Allowed : Access.Denied,
    };

    /// <summary>Whether <paramref name="pid"/> runs inside Programa: this app or the terminal host (whose shells
    /// are every terminal) is among its ancestors. Each root must still be the process it was (same start
    /// time), and each parent must have started before its child, so a reused pid breaks the chain.</summary>
    internal static bool DescendsFrom(uint pid, IReadOnlyDictionary<uint, long> roots, Func<uint, (uint Parent, long Started, string Name)?> describe)
    {
        long? childStarted = null;
        for (var depth = 0; depth < 64 && pid > 4; depth++)
        {
            if (describe(pid) is not { } process || (childStarted is { } started && process.Started > started)) return false;
            if (roots.TryGetValue(pid, out var rootStarted)) return rootStarted == process.Started;
            (pid, childStarted) = (process.Parent, process.Started);
        }
        return false;
    }

    private static Access AccessFor(NamedPipeServerStream pipe)
    {
        var settings = AppSettings.Load();
        if (settings.SocketControlMode is "off" or "automation") return Decide(settings.SocketControlMode, false);
        var roots = new Dictionary<uint, long>();
        foreach (var root in new[] { (uint)Environment.ProcessId, TerminalHost.ProcessId })
            if (root != 0 && LeftoverReaper.Describe(root) is { } process) roots[root] = process.Started;
        var fromTerminal = GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var client) && DescendsFrom(client, roots, LeftoverReaper.Describe);
        return Decide(settings.SocketControlMode, fromTerminal);
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint clientProcessId);

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
            // ponytail: the mode is read once per connection; a subscription keeps its access until it reconnects.
            var connection = new Connection(Write) { Access = AccessFor(pipe) };
            try
            {
                while (await reader.ReadLineAsync(_stop.Token) is { } line)
                {
                    if (line.Length == 0) continue;
                    await Write(await HandleLineAsync(line, connection));
                    // A refused client is told once, as macOS closes it; five wrong passwords close it too.
                    if (connection.Access is Access.Denied or Access.Off || connection.Failures >= MaxLoginFailures) break;
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
                // However the client goes, its banner claim goes with it.
                BannerClaims.TryRemove(connection, out _);
            }
        }
    }

    /// <summary>One client connection: how to write to it, and its subscription (at most one).</summary>
    internal sealed class Connection(Func<string, Task> write)
    {
        internal Func<string, Task> Write { get; } = write;
        internal Subscription? Subscription { get; set; }
        internal Access Access { get; set; } = Access.Allowed;
        /// <summary>Failed auth.login attempts on this connection.</summary>
        internal int Failures { get; set; }
    }

    private const int MaxLoginFailures = 5;

    /// <summary>automation.socketPassword, read at each login.</summary>
    internal Func<string?> Password { get; init; } = () => AppSettings.Load().SocketPassword;

    /// <summary>The time source for the login lockout.</summary>
    internal Func<DateTime> Now { get; init; } = () => DateTime.UtcNow;

    private readonly object _loginGate = new();
    private int _consecutiveFailures;
    private DateTime _lockedUntil;

    /// <summary>The access gate for one request: null lets it through, else the answer that refuses it.</summary>
    private string? Refusal(object? id, string method, JsonElement p, Connection? connection)
    {
        switch (connection?.Access)
        {
            case Access.Off: return Failure(id, "unavailable", "Socket control is off (Settings > Automation > Socket Control Mode).");
            case Access.Denied: return Failure(id, "access_denied", "Access denied: only processes started inside Programa terminals can connect (Settings > Automation > Socket Control Mode).");
            case Access.NeedsLogin when method == "auth.login": return Login(id, p, connection);
            case Access.NeedsLogin: return Failure(id, "auth_required", "Authentication required. Call auth.login first.");
            default: return null;
        }
    }

    /// <summary>auth.login in password mode, as on macOS: five free failures across connections, then a lockout
    /// that starts at a second and doubles up to a minute; a success resets it.</summary>
    private string Login(object? id, JsonElement p, Connection connection)
    {
        var given = p.TryGetProperty("password", out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        if (string.IsNullOrEmpty(given)) return Failure(id, "invalid_params", "auth.login requires params.password");
        if (Password() is not { } expected) return Failure(id, "auth_unconfigured", "Password mode is enabled but no socket password is configured in Settings.");
        lock (_loginGate)
        {
            var now = Now();
            if (now < _lockedUntil)
            {
                connection.Failures++;
                return Failure(id, "auth_failed", "Too many failed attempts; try again later.");
            }
            static byte[] Hash(string text) => System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(text));
            if (System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(Hash(given), Hash(expected)))
            {
                _consecutiveFailures = 0;
                connection.Access = Access.Allowed;
                return JsonSerializer.Serialize(new { id, ok = true, result = new { authenticated = true } }, Json);
            }
            connection.Failures++;
            if (++_consecutiveFailures > MaxLoginFailures)
                _lockedUntil = now + TimeSpan.FromSeconds(Math.Min(60, Math.Pow(2, Math.Min(_consecutiveFailures - MaxLoginFailures - 1, 16))));
            return Failure(id, "auth_failed", "Invalid password.");
        }
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
            if (Refusal(id, method, parameters, connection) is { } refused) return refused;
            var result = method switch
            {
                "subscribe" => Subscribe(parameters, connection),
                "unsubscribe" => Unsubscribe(connection),
                "notification.claim_banners" => ClaimBanners(parameters, connection),
                // Allowed already (a Programa terminal, automation mode, or logged in).
                "auth.login" => new { authenticated = true, required = false },
                "app.browsers" => Browsers.Report(),
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

    /// <summary>The banner kinds each open connection shows itself (`notification.claim_banners`).</summary>
    private static readonly ConcurrentDictionary<Connection, string[]> BannerClaims = new();

    /// <summary>Whether an open connection shows <paramref name="kind"/>'s banner itself.</summary>
    internal static bool BannerClaimed(string kind) => BannerClaims.Values.Any(kinds => kinds.Contains(kind));

    /// <summary>`notification.claim_banners`: replaces this connection's claim; `[]` releases it.</summary>
    private static object ClaimBanners(JsonElement p, Connection? connection)
    {
        const string valid = "needs_input";
        if (!p.TryGetProperty("kinds", out var given) || given.ValueKind != JsonValueKind.Array)
            throw new ControlException("invalid_params", $"kinds must be an array of: {valid}");
        var kinds = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var item in given.EnumerateArray())
        {
            var name = item.ValueKind == JsonValueKind.String ? item.GetString()! : item.GetRawText();
            if (name != valid) throw new ControlException("invalid_params", $"Unknown notification kind '{name}' -- use: {valid}");
            kinds.Add(name);
        }
        if (connection is null) throw new ControlException("unavailable", "notification.claim_banners needs a connection that stays open.");
        if (kinds.Count == 0) BannerClaims.TryRemove(connection, out _);
        else BannerClaims[connection] = [.. kinds];
        return new { claimed = kinds };
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
