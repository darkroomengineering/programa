using System.Text;
using System.Text.Json;

namespace Programa;

/// <summary>
/// `programa.exe --check-settings [PATH]`, behind `programa config check`, as macOS's
/// SettingsFileCheck: reads settings.json without applying it and prints each problem as
/// <c>settings.json:LINE: key.path: message</c>. Exits 0 when the file is valid or absent, 1 when it
/// has problems, 2 when an explicit path does not exist. It checks what the Windows app reads with
/// the macOS messages: the JSONC syntax, app.appearance, app.terminalTheme, app.terminalFont and
/// customCommands.trustedDirectories.
/// </summary>
internal static class SettingsCheck
{
    internal const string LaunchArgument = "--check-settings";

    private static readonly JsonDocumentOptions Options = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };

    internal static int Run(string? explicitPath, string defaultPath, TextWriter output, TextWriter error)
    {
        string path;
        if (explicitPath is not null)
        {
            path = explicitPath.StartsWith('~')
                ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + explicitPath[1..]
                : explicitPath;
            if (!File.Exists(path))
            {
                error.WriteLine($"No settings file at {path}");
                return 2;
            }
        }
        else if (File.Exists(defaultPath)) path = defaultPath;
        else
        {
            output.WriteLine($"No settings.json at {defaultPath}; the defaults are in use");
            return 0;
        }
        var name = Path.GetFileName(path);
        var problems = Problems(File.ReadAllBytes(path));
        if (problems.Count == 0)
        {
            output.WriteLine($"{name} is valid");
            return 0;
        }
        foreach (var problem in problems) output.WriteLine(problem.Format(name));
        return 1;
    }

    internal sealed record Problem(int? Line, string? KeyPath, string Message)
    {
        internal string Format(string fileName) =>
            fileName + (Line is { } line ? $":{line}" : "") + ": " + (KeyPath is null ? "" : KeyPath + ": ") + Message;
    }

    internal static List<Problem> Problems(byte[] bytes)
    {
        var data = bytes.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]) ? bytes[3..] : bytes;
        if (string.IsNullOrWhiteSpace(Encoding.UTF8.GetString(data))) return [new(null, null, "the file is empty")];
        JsonDocument document;
        try { document = JsonDocument.Parse(data, Options); }
        catch (JsonException parseError)
        {
            // .NET appends "LineNumber: 2 | BytePositionInLine: 4."; the line is the problem's own.
            var message = parseError.Message.Split(" LineNumber:")[0].Trim();
            return [new(parseError.LineNumber is { } line ? (int)line + 1 : null, null, message)];
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return [new(1, null, "the top level is not a JSON object")];
            var found = new List<(string Path, string Message)>();
            if (Member(root, "app") is { ValueKind: JsonValueKind.Object } app)
            {
                if (Member(app, "appearance") is { ValueKind: JsonValueKind.String } appearance
                    && appearance.GetString() is not ("system" or "light" or "dark" or "auto"))
                    found.Add(("app.appearance", "expected one of \"system\", \"light\", \"dark\", \"auto\""));
                if (Member(app, "terminalTheme") is { } theme && theme.ValueKind != JsonValueKind.Null)
                {
                    if (theme.ValueKind != JsonValueKind.Object)
                        found.Add(("app.terminalTheme", "expected an object with light and dark theme names, or null"));
                    else
                        foreach (var mode in new[] { "light", "dark" })
                            if (Member(theme, mode) is { } name && name.ValueKind != JsonValueKind.Null
                                && (name.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(name.GetString())))
                                found.Add(($"app.terminalTheme.{mode}", "expected a non-empty theme name or null"));
                }
                if (Member(app, "terminalFont") is { } font && font.ValueKind != JsonValueKind.Null
                    && !(font.ValueKind == JsonValueKind.Object
                        && Member(font, "family") is { ValueKind: JsonValueKind.String } family && !string.IsNullOrWhiteSpace(family.GetString())
                        && Member(font, "size") is { ValueKind: JsonValueKind.Number } size && size.GetDouble() > 0))
                    found.Add(("app.terminalFont", "expected an object with a non-empty family and a size above 0, or null"));
            }
            if (Member(root, "customCommands") is { ValueKind: JsonValueKind.Object } commands
                && Member(commands, "trustedDirectories") is { } roots && roots.ValueKind != JsonValueKind.Null
                && !(roots.ValueKind == JsonValueKind.Array && roots.EnumerateArray().All(item => item.ValueKind == JsonValueKind.String)))
                found.Add(("customCommands.trustedDirectories", "expected an array of strings"));
            var lines = KeyLines(data);
            return [.. found
                .Select(item => new Problem(LineOf(lines, item.Path), item.Path, item.Message))
                .OrderBy(problem => problem.Line ?? int.MaxValue).ThenBy(problem => problem.KeyPath, StringComparer.Ordinal)];
        }
    }

    private static JsonElement? Member(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) ? value : null;

    /// <summary>The line of a key path, or of its nearest parent that is in the file.</summary>
    private static int? LineOf(Dictionary<string, int> lines, string path)
    {
        for (var key = path; key.Length > 0; key = key.Contains('.') ? key[..key.LastIndexOf('.')] : "")
            if (lines.TryGetValue(key, out var line)) return line;
        return null;
    }

    /// <summary>The 1-based line of every object key outside arrays, by dotted path.</summary>
    private static Dictionary<string, int> KeyLines(byte[] data)
    {
        var lines = new Dictionary<string, int>(StringComparer.Ordinal);
        var reader = new Utf8JsonReader(data, new JsonReaderOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
        // Each open container's path; null inside an array, where keys are not indexed.
        var stack = new Stack<string?>();
        string? pending = null;
        while (reader.Read())
        {
            switch (reader.TokenType)
            {
                case JsonTokenType.PropertyName when stack.TryPeek(out var parent) && parent is not null:
                    var key = reader.GetString()!;
                    pending = parent.Length == 0 ? key : $"{parent}.{key}";
                    lines.TryAdd(pending, LineAt(data, (int)reader.TokenStartIndex));
                    continue;
                case JsonTokenType.StartObject:
                    stack.Push(stack.Count == 0 ? "" : stack.Peek() is null ? null : pending);
                    break;
                case JsonTokenType.StartArray:
                    stack.Push(null);
                    break;
                case JsonTokenType.EndObject or JsonTokenType.EndArray:
                    stack.TryPop(out _);
                    break;
            }
            pending = null;
        }
        return lines;
    }

    private static int LineAt(byte[] data, int offset)
    {
        var line = 1;
        for (var index = 0; index < offset && index < data.Length; index++)
            if (data[index] == '\n' || (data[index] == '\r' && (index + 1 >= data.Length || data[index + 1] != '\n'))) line++;
        return line;
    }

    /// <summary>The app's stdout or stderr as UTF-8, for the CLI that reads it from a pipe.</summary>
    internal static StreamWriter Utf8Writer(Stream stream) => new(stream, new UTF8Encoding(false)) { AutoFlush = true };
}
