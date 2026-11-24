using System.Text.Json;

namespace Programa;

internal sealed record TerminalSettings(string? Shell, string? StartingDirectory)
{
    private static readonly TerminalSettings Defaults = new(null, null);
    private static readonly JsonDocumentOptions DocumentOptions = new()
    {
        CommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    /// <summary>The settings in the file, with the default for any key it cannot use; each rejected
    /// key goes to launch.log so a typo does not stop terminals from starting.</summary>
    public static TerminalSettings LoadOrDefaults()
    {
        string text;
        try { text = File.ReadAllText(ShortcutSettings.SettingsPath); }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return Defaults; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LaunchLog.Write($"settings: windows.shell and windows.startingDirectory ignored: {error.Message}");
            return Defaults;
        }
        var (settings, problems) = Parse(text);
        foreach (var (path, message) in problems) LaunchLog.Write($"settings: {path} ignored: {message}");
        return settings;
    }

    internal static (TerminalSettings Settings, List<(string Path, string Message)> Problems) Parse(string text)
    {
        var problems = new List<(string Path, string Message)>();
        if (string.IsNullOrWhiteSpace(text)) return (Defaults, problems);
        JsonDocument document;
        try { document = JsonDocument.Parse(text, DocumentOptions); }
        catch (JsonException error)
        {
            problems.Add(("windows", error.Message));
            return (Defaults, problems);
        }
        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                problems.Add(("windows", "the top level is not a JSON object"));
                return (Defaults, problems);
            }
            return (Read(document.RootElement, problems), problems);
        }
    }

    /// <summary>windows.shell and windows.startingDirectory from a parsed settings object. Each key is
    /// checked on its own: a rejected one is reported and left unset, and the other still applies.
    /// <see cref="SettingsCheck"/> calls this too, so `programa config check` reports the same problems.</summary>
    internal static TerminalSettings Read(JsonElement root, List<(string Path, string Message)> problems)
    {
        if (!root.TryGetProperty("windows", out var windows) || windows.ValueKind == JsonValueKind.Null)
            return Defaults;
        if (windows.ValueKind != JsonValueKind.Object)
        {
            problems.Add(("windows", "expected an object"));
            return Defaults;
        }

        var shell = ReadPath(windows, "shell", problems);
        if (shell is not null &&
            (!shell.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
             !Path.IsPathFullyQualified(shell) ||
             Path.GetFileName(shell).IndexOfAny(Path.GetInvalidFileNameChars()) >= 0))
        {
            problems.Add(("windows.shell", "expected an absolute path to an .exe file"));
            shell = null;
        }

        var directory = ReadPath(windows, "startingDirectory", problems);
        if (directory is not null && !Path.IsPathFullyQualified(directory))
        {
            problems.Add(("windows.startingDirectory", "expected an absolute path"));
            directory = null;
        }

        return new(shell, directory);
    }

    /// <summary>windows.shell as a Ghostty command line: quoted, so the core finds the program and
    /// keeps PowerShell's integration as it does for Ghostty's command.</summary>
    public string? Command => Shell is null ? null : $"\"{Shell}\"";

    private static string? ReadPath(JsonElement windows, string key, List<(string Path, string Message)> problems)
    {
        if (!windows.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null)
            return null;
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { } text ||
            string.IsNullOrWhiteSpace(text) || text.Contains('"') || text.Any(char.IsControl) ||
            text.IndexOfAny(Path.GetInvalidPathChars()) >= 0)
        {
            problems.Add(($"windows.{key}", "expected a non-empty, unquoted path or null"));
            return null;
        }
        return text;
    }
}
