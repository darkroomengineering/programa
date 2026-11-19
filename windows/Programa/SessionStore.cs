using System.Text.Json;
using System.Text.Json.Serialization;

namespace Programa;

/// <summary>What one terminal brings back on relaunch: its directory, recent output and font size.</summary>
internal sealed record SessionTerminal(string? Cwd, string? Text, float? FontSize, AgentSession? Agent = null);

/// <summary>The window's frame in physical pixels.</summary>
internal sealed record SessionWindow(int X, int Y, int Width, int Height, bool Maximized);

/// <summary>The session restored on relaunch, as the macOS app restores layout, directories and
/// scrollback: one window, with every other open window under <see cref="OtherWindows"/>.
/// <see cref="Core"/> is that window's core snapshot, replayed with seed_snapshot.
/// Shells start fresh in their saved directories; processes do not survive a quit on Windows.</summary>
internal sealed record SavedSession(
    int Version,
    JsonElement Core,
    bool SidebarVisible,
    double SidebarWidth,
    SessionWindow? Window,
    Dictionary<string, SessionTerminal> Terminals,
    Dictionary<string, string>? MarkdownPanels = null,
    Dictionary<string, SessionReview>? ReviewPanels = null,
    string? WindowId = null,
    List<SavedSession>? OtherWindows = null);

internal static class SessionStore
{
    internal const int CurrentVersion = 1;

    /// <summary>Lines of output saved per terminal.</summary>
    internal const int SavedLines = 2000;

    /// <summary>The text up to its last non-empty line.</summary>
    internal static string WithoutLastLine(string text)
    {
        var end = text.TrimEnd('\n').LastIndexOf('\n');
        return end < 0 ? string.Empty : text[..end];
    }

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>Development builds keep their own session, so testing never replaces the installed
    /// app's (the macOS Debug builds are isolated the same way).</summary>
    internal static string DefaultPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programa",
        BuildIdentity.Value.Contains("0.0.0-dev", StringComparison.Ordinal) ? "session-dev.json" : "session.json");

    /// <summary>The saved session, or null when there is none or it cannot be read; an unreadable
    /// file is set aside as session.json.broken so it is not retried on every launch.</summary>
    internal static SavedSession? Load(string? path = null)
    {
        path ??= DefaultPath;
        if (!File.Exists(path)) return null;
        try
        {
            var session = JsonSerializer.Deserialize<SavedSession>(File.ReadAllBytes(path), Options);
            if (session is { Version: CurrentVersion }) return session;
            LaunchLog.Write($"session: ignoring {path} (version {session?.Version})");
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            LaunchLog.Write($"session: cannot read {path}: {error.Message}");
            try { File.Move(path, path + ".broken", overwrite: true); } catch (IOException) { }
        }
        return null;
    }

    /// <summary>Writes atomically, so a crash mid-write keeps the previous session.</summary>
    internal static void Save(SavedSession session, string? path = null)
    {
        path ??= DefaultPath;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + ".tmp";
            File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(session, Options));
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LaunchLog.Write($"session: cannot save {path}: {error.Message}");
        }
    }

    internal static void Delete(string? path = null)
    {
        try { File.Delete(path ?? DefaultPath); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
