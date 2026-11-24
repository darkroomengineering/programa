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

    public static TerminalSettings Load()
    {
        string text;
        try { text = File.ReadAllText(ShortcutSettings.SettingsPath); }
        catch (FileNotFoundException) { return Defaults; }
        catch (DirectoryNotFoundException) { return Defaults; }

        if (string.IsNullOrWhiteSpace(text)) return Defaults;
        using var document = JsonDocument.Parse(text, DocumentOptions);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Settings must contain a JSON object.");
        if (!root.TryGetProperty("windows", out var windows) || windows.ValueKind == JsonValueKind.Null)
            return Defaults;
        if (windows.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("windows must be an object.");

        var shell = ReadOptionalString(windows, "shell");
        if (shell is not null &&
            (!shell.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
             !Path.IsPathFullyQualified(shell) ||
             Path.GetFileName(shell).IndexOfAny(Path.GetInvalidFileNameChars()) >= 0))
            throw new InvalidDataException("windows.shell must be an absolute path to an .exe file.");

        var directory = ReadOptionalString(windows, "startingDirectory");
        if (directory is not null && !Path.IsPathFullyQualified(directory))
            throw new InvalidDataException("windows.startingDirectory must be an absolute path.");

        return new(shell, directory);
    }

    // ConPTY's command-line builder inserts the executable verbatim, before escaping arguments.
    public string? NativeShell => Shell is null ? null : $"\"{Shell}\"";

    private static string? ReadOptionalString(JsonElement windows, string key)
    {
        if (!windows.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null)
            return null;
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { } text ||
            string.IsNullOrWhiteSpace(text) || text.Contains('"') || text.Any(char.IsControl) ||
            text.IndexOfAny(Path.GetInvalidPathChars()) >= 0)
            throw new InvalidDataException($"windows.{key} must be a non-empty, unquoted path or null.");
        return text;
    }
}
