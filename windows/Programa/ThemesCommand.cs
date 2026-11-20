using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Programa;

/// <summary>
/// `programa.exe --themes [--json] [list | set ... | clear]`, behind `programa themes`, as macOS's
/// CLI+Themes.swift. The macOS app keeps the choice in a managed Ghostty config; Windows keeps it
/// in settings.json's app.terminalTheme and app.terminalFont, which the running app reapplies when
/// the file changes. Background opacity and blur are macOS-only.
/// </summary>
internal static class ThemesCommand
{
    internal const string LaunchArgument = "--themes";

    private static readonly JsonDocumentOptions Options = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };

    private sealed class UsageException(string message) : Exception(message);

    /// <summary>The theme folders the terminal reads (TerminalAppearance), plus GHOSTTY_RESOURCES_DIR's.</summary>
    internal static IReadOnlyList<string> ThemeDirectories()
    {
        var configHome = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") is { Length: > 0 } xdg
            ? xdg
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var directories = new List<string>();
        if (Environment.GetEnvironmentVariable("GHOSTTY_RESOURCES_DIR") is { Length: > 0 } resources)
            directories.Add(Path.Combine(resources.Trim(), "themes"));
        directories.Add(Path.Combine(AppContext.BaseDirectory, "themes"));
        directories.Add(Path.Combine(configHome, "ghostty", "themes"));
        return directories;
    }

    internal static int Run(string[] args, string settingsPath, IReadOnlyList<string> themeDirectories, TextWriter output, TextWriter error)
    {
        var json = args.Contains("--json");
        var rest = args.Where(arg => arg != "--json").ToList();
        try
        {
            switch (rest.FirstOrDefault())
            {
                case null:
                    List(json, settingsPath, themeDirectories, output);
                    break;
                case "list":
                    if (rest.Count > 1) throw new UsageException("themes list does not take any positional arguments");
                    List(json, settingsPath, themeDirectories, output);
                    break;
                case "set":
                    Set(rest.Skip(1).ToList(), json, settingsPath, themeDirectories, output);
                    break;
                case "clear":
                    if (rest.Count > 1) throw new UsageException("themes clear does not take any positional arguments");
                    if (File.Exists(settingsPath)) Write(settingsPath, ("terminalTheme", null), ("terminalFont", null));
                    output.WriteLine(json
                        ? Pretty(new JsonObject { ["ok"] = true, ["cleared"] = true, ["config_path"] = settingsPath, ["reload_requested"] = true })
                        : $"OK cleared config={settingsPath} reload=requested");
                    break;
                case var other when other.StartsWith('-'):
                    throw new UsageException($"Unknown themes subcommand '{other}'. Run 'programa themes --help'.");
                default:
                    Set(rest, json, settingsPath, themeDirectories, output);
                    break;
            }
            return 0;
        }
        catch (Exception failure) when (failure is UsageException or IOException or UnauthorizedAccessException or InvalidDataException)
        {
            error.WriteLine($"Error: {failure.Message}");
            return 1;
        }
    }

    /// <summary>Every theme file name, once (ignoring case), sorted.</summary>
    internal static List<string> ThemeNames(IEnumerable<string> directories)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var names = new List<string>();
        foreach (var directory in directories.Where(Directory.Exists))
            foreach (var file in Directory.EnumerateFiles(directory))
            {
                var name = Path.GetFileName(file);
                if (!name.StartsWith('.') && seen.Add(name)) names.Add(name);
            }
        return [.. names.OrderBy(name => name, StringComparer.OrdinalIgnoreCase)];
    }

    private sealed record Current(string? Light, string? Dark, string? FontFamily, double? FontSize);

    private static Current Read(string settingsPath)
    {
        try
        {
            var app = File.Exists(settingsPath) ? JsonNode.Parse(File.ReadAllText(settingsPath), null, Options)?["app"] as JsonObject : null;
            var theme = app?["terminalTheme"] as JsonObject;
            var font = app?["terminalFont"] as JsonObject;
            return new(Text(theme?["light"]), Text(theme?["dark"]), Text(font?["family"]),
                font?["size"] is JsonValue size && size.TryGetValue<double>(out var points) && points > 0 ? points : null);
        }
        catch (JsonException) { return new(null, null, null, null); }
    }

    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) && text.Trim().Length > 0 ? text.Trim() : null;

    /// <summary>A size as macOS prints a Double: 13 is "13.0".</summary>
    private static string Number(double value) =>
        value == Math.Floor(value) ? value.ToString("0.0", CultureInfo.InvariantCulture) : value.ToString(CultureInfo.InvariantCulture);

    private static void List(bool json, string settingsPath, IReadOnlyList<string> directories, TextWriter output)
    {
        var themes = ThemeNames(directories);
        var current = Read(settingsPath);
        bool Is(string? selected, string theme) => string.Equals(selected, theme, StringComparison.OrdinalIgnoreCase);
        if (json)
        {
            output.WriteLine(Pretty(new JsonObject
            {
                ["themes"] = new JsonArray([.. themes.Select(theme => (JsonNode)new JsonObject
                {
                    ["name"] = theme, ["current_light"] = Is(current.Light, theme), ["current_dark"] = Is(current.Dark, theme),
                })]),
                ["current"] = new JsonObject
                {
                    ["light"] = current.Light, ["dark"] = current.Dark, ["source_path"] = (current.Light ?? current.Dark) is null ? null : settingsPath,
                    ["opacity"] = null, ["blur"] = null, ["font_family"] = current.FontFamily, ["font_size"] = current.FontSize,
                },
                ["config_path"] = settingsPath,
            }));
            return;
        }
        output.WriteLine($"Current light: {current.Light ?? "inherit"}");
        output.WriteLine($"Current dark: {current.Dark ?? "inherit"}");
        output.WriteLine("Opacity: inherit");
        output.WriteLine("Blur: inherit");
        output.WriteLine($"Font: {current.FontFamily ?? "inherit"} {(current.FontSize is { } size ? Number(size) : "")}");
        output.WriteLine($"Config: {settingsPath}");
        output.WriteLine();
        if (themes.Count == 0)
        {
            output.WriteLine("No themes found.");
            return;
        }
        foreach (var theme in themes)
        {
            var badges = new[] { Is(current.Light, theme) ? "light" : null, Is(current.Dark, theme) ? "dark" : null }.OfType<string>().ToList();
            output.WriteLine(badges.Count == 0 ? theme : $"{theme}  [{string.Join(", ", badges)}]");
        }
    }

    private static void Set(List<string> args, bool json, string settingsPath, IReadOnlyList<string> directories, TextWriter output)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var switches = new HashSet<string>(StringComparer.Ordinal);
        var remaining = new List<string>();
        for (var index = 0; index < args.Count; index++)
        {
            var arg = args[index];
            var (flag, inline) = arg.StartsWith("--", StringComparison.Ordinal) && arg.IndexOf('=') is > 2 and var at ? (arg[..at], arg[(at + 1)..]) : (arg, null);
            if (flag is "--light" or "--dark" or "--opacity" or "--font" or "--font-size")
            {
                values[flag] = inline ?? (index + 1 < args.Count ? args[++index] : throw new UsageException($"themes set: {flag} requires a value"));
            }
            else if (flag is "--blur" or "--no-blur") switches.Add(flag);
            else if (arg.StartsWith("--", StringComparison.Ordinal))
                throw new UsageException($"themes set: unknown flag '{arg}'. Known flags: --light <theme>, --dark <theme>, --opacity <0-1>, --blur, --no-blur, --font <name>, --font-size <n>");
            else remaining.Add(arg);
        }
        if (switches.Count == 2) throw new UsageException("themes set: cannot pass both --blur and --no-blur");
        if (values.ContainsKey("--opacity") || switches.Count > 0)
            throw new UsageException("themes set: --opacity, --blur and --no-blur are not supported on Windows");

        var themes = ThemeNames(directories);
        var current = Read(settingsPath);
        string? light, dark;
        var setTheme = true;
        if (!values.ContainsKey("--light") && !values.ContainsKey("--dark") && remaining.Count > 0)
            light = dark = Validated(string.Join(' ', remaining), themes);
        else
        {
            if (remaining.Count > 0) throw new UsageException($"themes set: unexpected argument '{string.Join(' ', remaining)}'");
            light = values.TryGetValue("--light", out var lightName) ? Validated(lightName, themes) : current.Light;
            dark = values.TryGetValue("--dark", out var darkName) ? Validated(darkName, themes) : current.Dark;
            setTheme = lightName is not null || darkName is not null;
        }
        var family = current.FontFamily;
        var size = current.FontSize;
        var setFont = false;
        if (values.TryGetValue("--font", out var font))
        {
            family = font.Trim().Length == 0 ? null : font.Trim();
            setFont = true;
        }
        if (values.TryGetValue("--font-size", out var rawSize))
        {
            size = double.TryParse(rawSize, NumberStyles.Float, CultureInfo.InvariantCulture, out var points) && points > 0
                ? points
                : throw new UsageException("themes set: --font-size must be a positive number");
            setFont = true;
        }
        if (!setTheme && !setFont)
            throw new UsageException("themes set requires a theme name or at least one flag: --light, --dark, --opacity, --blur/--no-blur, --font, --font-size");

        var changes = new List<(string Key, JsonNode? Value)>();
        if (setTheme) changes.Add(("terminalTheme", new JsonObject { ["light"] = light, ["dark"] = dark }));
        // The Mac reads a font only with both a family and a size, so the missing one is the default.
        if (setFont)
            changes.Add(("terminalFont", family is null && size is null ? null
                : new JsonObject { ["family"] = family ?? TerminalAppearance.BundledFontFamily, ["size"] = size ?? 13 }));
        Write(settingsPath, [.. changes]);
        output.WriteLine(json
            ? Pretty(new JsonObject
            {
                ["ok"] = true, ["light"] = light, ["dark"] = dark, ["opacity"] = null, ["blur"] = null,
                ["font_family"] = family, ["font_size"] = size, ["config_path"] = settingsPath, ["reload_requested"] = true,
            })
            : $"OK light={light ?? "-"} dark={dark ?? "-"} config={settingsPath} reload=requested");
    }

    /// <summary>The theme's own spelling, or the name as given when no themes are installed.</summary>
    private static string Validated(string raw, List<string> themes)
    {
        var name = raw.Trim();
        if (name.Length == 0) throw new UsageException("Theme name cannot be empty");
        if (themes.FirstOrDefault(theme => string.Equals(theme, name, StringComparison.OrdinalIgnoreCase)) is { } match) return match;
        if (themes.Count == 0) return name;
        var near = themes.Where(theme => theme.Contains(name, StringComparison.OrdinalIgnoreCase)).Take(5).ToList();
        var suggestion = near.Count == 0 ? "" : $" Did you mean: {string.Join(", ", near.Select(theme => $"'{theme}'"))}?";
        throw new UsageException($"Unknown theme '{name}'.{suggestion} Run 'programa themes' to list available themes.");
    }

    /// <summary>Sets app.&lt;key&gt; values, keeping every other byte of the file (ShortcutSettings.PatchValue).</summary>
    private static void Write(string settingsPath, params (string Key, JsonNode? Value)[] changes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);
        var bytes = File.Exists(settingsPath) ? File.ReadAllBytes(settingsPath) : [];
        try
        {
            foreach (var (key, value) in changes) bytes = ShortcutSettings.PatchValue(bytes, "app", key, value?.ToJsonString() ?? "null");
            JsonDocument.Parse(bytes.AsMemory(bytes.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]) ? 3 : 0), Options).Dispose();
        }
        catch (JsonException failure) { throw new InvalidDataException($"Invalid JSON in {settingsPath}", failure); }
        var temporary = settingsPath + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, settingsPath, true);
    }

    private static string Pretty(JsonNode node) =>
        node.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
}
