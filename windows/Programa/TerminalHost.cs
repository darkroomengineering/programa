using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Programa;

/// <summary>The terminal host (`programa-host.exe`, core/crates/programa-terminal/src/host.rs) that
/// owns every terminal's ConPTY and shell, so they keep running when Programa quits or crashes and
/// reattach on the next launch, as on macOS. The app finds the host an earlier launch started
/// through %LOCALAPPDATA%\Programa\terminal-host.json (its random pipe name and token), or starts
/// one; without it terminals run in the app as before.</summary>
internal static class TerminalHost
{
    internal sealed record Connection(string Pipe, string Token);

    /// <summary>The host this app's terminals run in, or null when none could be started.</summary>
    internal static Connection? Current { get; private set; }

    /// <summary>Sessions that were running when this app started: their terminals reattach.</summary>
    internal static HashSet<string> LiveAtLaunch { get; private set; } = new(StringComparer.Ordinal);

    private static string StatePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programa", $"terminal-host{BuildIdentity.DevSuffix}.json");

    internal static void Start()
    {
        // ponytail: a kill switch for diagnosing the host; terminals then run in the app.
        if (Environment.GetEnvironmentVariable("PROGRAMA_TERMINAL_HOST") == "0") return;
        try
        {
            if (Read() is { } saved && List(saved) is { } live)
            {
                (Current, LiveAtLaunch) = (saved, live);
                LaunchLog.Write($"terminal host: reconnected, {live.Count} sessions running");
                return;
            }
            if (Executable() is not { } exe)
            {
                LaunchLog.Write("terminal host: programa-host.exe is missing; terminals run in the app");
                return;
            }
            var connection = new Connection($@"\\.\pipe\programa-host{BuildIdentity.DevSuffix}-{Environment.UserName}-{Hex(16)}", Hex(32));
            // The pipe name and token stay out of the command line; the host drops them before any shell starts.
            var start = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(exe)! };
            start.Environment["PROGRAMA_HOST_PIPE"] = connection.Pipe;
            start.Environment["PROGRAMA_HOST_TOKEN"] = connection.Token;
            using (Process.Start(start)) { }
            for (var attempt = 0; attempt < 60; attempt++)
            {
                if (List(connection) is not null)
                {
                    Current = connection;
                    Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!);
                    File.WriteAllText(StatePath, JsonSerializer.Serialize(new { pipe = connection.Pipe, token = connection.Token }));
                    LaunchLog.Write("terminal host: started");
                    return;
                }
                Thread.Sleep(50);
            }
            LaunchLog.Write("terminal host: did not answer; terminals run in the app");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            LaunchLog.Write($"terminal host: {error.Message}; terminals run in the app");
        }
    }

    /// <summary>Ends the sessions of terminals this launch did not restore (closed while Programa was
    /// away, or from a session file that was lost).</summary>
    internal static void Retain(IEnumerable<string> surfaceIds)
    {
        if (Current is not { } connection) return;
        var ids = surfaceIds.ToList();
        if (Request(connection, new JsonObject { ["op"] = "retain", ["ids"] = new JsonArray(ids.Select(id => (JsonNode)id).ToArray()) }) is { } answer && (int?)answer["killed"] is > 0 and var killed)
            LaunchLog.Write($"terminal host: ended {killed} sessions no workspace restored");
    }

    private static Connection? Read()
    {
        try
        {
            var saved = JsonNode.Parse(File.ReadAllText(StatePath));
            return (string?)saved?["pipe"] is { Length: > 0 } pipe && (string?)saved?["token"] is { Length: > 0 } token ? new Connection(pipe, token) : null;
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { return null; }
    }

    /// <summary>The running session ids, or null when the host does not answer.</summary>
    private static HashSet<string>? List(Connection connection) =>
        Request(connection, new JsonObject { ["op"] = "list" }) is { } answer
            ? answer["sessions"]?.AsArray().Select(session => (string?)session?["id"]).OfType<string>().ToHashSet(StringComparer.Ordinal) ?? []
            : null;

    private static JsonObject? Request(Connection connection, JsonObject body)
    {
        try
        {
            body["token"] = connection.Token;
            body["version"] = 1;
            const string localPrefix = @"\\.\pipe\";
            if (!connection.Pipe.StartsWith(localPrefix, StringComparison.OrdinalIgnoreCase) ||
                connection.Pipe.Length == localPrefix.Length)
                return null;
            using var pipe = new NamedPipeClientStream(".", connection.Pipe[localPrefix.Length..], PipeDirection.InOut,
                PipeOptions.None, TokenImpersonationLevel.Identification);
            pipe.Connect(500);
            var request = Encoding.UTF8.GetBytes(body.ToJsonString() + "\n");
            pipe.Write(request);
            var line = new List<byte>();
            for (var next = pipe.ReadByte(); next is >= 0 and not '\n'; next = pipe.ReadByte()) line.Add((byte)next);
            return JsonNode.Parse(Encoding.UTF8.GetString([.. line])) is JsonObject answer && (bool?)answer["ok"] == true ? answer : null;
        }
        catch (Exception error) when (error is IOException or TimeoutException or JsonException or UnauthorizedAccessException or InvalidOperationException) { return null; }
    }

    /// <summary>The host with Windows Terminal's conpty.dll and OpenConsole.exe beside it, copied out
    /// of the app (which unpacks to %TEMP%) to the tools folder; a running host keeps its copy.</summary>
    private static string? Executable()
    {
        var target = McpConfig.BinDirectory;
        foreach (var name in new[] { "programa-host.exe", "conpty.dll", "OpenConsole.exe" })
        {
            var from = new FileInfo(Path.Combine(AppContext.BaseDirectory, name));
            var to = new FileInfo(Path.Combine(target, name));
            if (!from.Exists || (to.Exists && to.Length == from.Length && to.LastWriteTimeUtc == from.LastWriteTimeUtc)) continue;
            try
            {
                Directory.CreateDirectory(target);
                from.CopyTo(to.FullName, overwrite: true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { LaunchLog.Write($"terminal host: kept the {name} in use: {error.Message}"); }
        }
        var staged = Path.Combine(target, "programa-host.exe");
        if (File.Exists(staged)) return staged;
        var bundled = Path.Combine(AppContext.BaseDirectory, "programa-host.exe");
        return File.Exists(bundled) ? bundled : null;
    }

    private static string Hex(int bytes) => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(bytes));
}
