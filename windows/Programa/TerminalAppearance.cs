using System.Globalization;
using System.Text.Json;
using Microsoft.Graphics.Canvas.Text;
using Windows.UI;

namespace Programa;

/// <summary>
/// The terminal font and colors, resolved like the macOS app: Ghostty's defaults, then the theme
/// named by the Ghostty config, then the config's own values (which win over the theme, as in
/// Ghostty), then settings.json's <c>app.terminalTheme</c> and <c>app.terminalFont</c>.
/// </summary>
internal sealed class TerminalAppearance
{
    /// <summary>Ghostty's embedded default font. Windows does not ship it, so it is bundled.</summary>
    internal const string BundledFontFamily = "JetBrains Mono";

    // Ghostty defaults (src/config/Config.zig at the pinned submodule). 13 is Ghostty's macOS
    // font-size; sizes are DIPs, which match macOS points on comparable displays.
    // ponytail: not Ghostty's Windows/Linux pt*96/72 conversion, which renders 33% larger than macOS.
    internal string FontFamily { get; private set; } = BundledFontFamily;
    internal float FontSize { get; private set; } = 13;
    internal Color Background { get; private set; } = Color.FromArgb(255, 0x28, 0x2C, 0x34);
    internal Color Foreground { get; private set; } = Color.FromArgb(255, 0xFF, 0xFF, 0xFF);
    internal Color? Cursor { get; private set; }
    internal Color? CursorText { get; private set; }
    internal Color? SelectionBackground { get; private set; }
    internal Color? SelectionForeground { get; private set; }
    internal Dictionary<int, Color> Palette { get; } = [];

    /// <summary>Ghostty's <c>command</c> and <c>initial-command</c> as written, the program new
    /// terminals start (programa_terminal.dll resolves it, TERMINAL_ABI.md); null for the default.</summary>
    internal string? Command { get; private set; }
    internal string? InitialCommand { get; private set; }

    private string? _theme;
    private bool _fontFamilySet;

    private static readonly Dictionary<bool, TerminalAppearance> Cache = [];

    /// <summary>The appearance for the app's light or dark mode, loaded once per mode.</summary>
    internal static TerminalAppearance For(bool dark)
    {
        lock (Cache)
        {
            if (!Cache.TryGetValue(dark, out var appearance))
            {
                var configHome = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") is { Length: > 0 } xdg
                    ? xdg
                    : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
                var ghostty = Path.Combine(configHome, "ghostty");
                Cache[dark] = appearance = Load(
                    dark,
                    [Path.Combine(ghostty, "config"), Path.Combine(ghostty, "config.ghostty")],
                    File.Exists(ShortcutSettings.SettingsPath) ? File.ReadAllText(ShortcutSettings.SettingsPath) : null,
                    [Path.Combine(ghostty, "themes"), Path.Combine(AppContext.BaseDirectory, "themes")]);
            }
            return appearance;
        }
    }

    /// <summary>Forgets the loaded appearances, so the next <see cref="For"/> reads the files again.</summary>
    internal static void Reload()
    {
        lock (Cache) Cache.Clear();
    }

    internal static TerminalAppearance Load(bool dark, IEnumerable<string> configFiles, string? settingsJson, IEnumerable<string> themeDirectories)
    {
        var configs = configFiles.Where(File.Exists).Select(File.ReadAllText).ToList();
        var (settingsTheme, settingsFamily, settingsSize) = ReadSettings(settingsJson);

        var probe = new TerminalAppearance();
        configs.ForEach(probe.Parse);
        var theme = settingsTheme ?? probe._theme;

        var appearance = new TerminalAppearance();
        if (theme is not null && FindTheme(ResolveThemeName(theme, dark), themeDirectories) is { } themePath)
            appearance.Parse(File.ReadAllText(themePath));
        configs.ForEach(appearance.Parse);
        if (settingsFamily is not null) appearance.FontFamily = settingsFamily;
        if (settingsSize is > 0) appearance.FontSize = settingsSize.Value;
        return appearance;
    }

    /// <summary>The Win2D font family for a style: the bundled file for JetBrains Mono or for a
    /// configured font that is not installed (Ghostty falls back to its embedded font the same way).</summary>
    internal string CanvasFontFamily(bool bold, bool italic)
    {
        var installed = !string.Equals(FontFamily, BundledFontFamily, StringComparison.OrdinalIgnoreCase)
            && CanvasTextFormat.GetSystemFontFamilies().Contains(FontFamily, StringComparer.OrdinalIgnoreCase);
        if (installed) return FontFamily;
        var style = (bold, italic) switch { (true, true) => "BoldItalic", (true, false) => "Bold", (false, true) => "Italic", _ => "Regular" };
        var path = Path.Combine(AppContext.BaseDirectory, "Fonts", $"JetBrainsMono-{style}.ttf");
        // Win2D loads file:// font URIs as a private collection; nothing is installed.
        return File.Exists(path) ? $"{new Uri(path).AbsoluteUri}#{BundledFontFamily}" : BundledFontFamily;
    }

    /// <summary>The colors object programa_terminal.dll takes (TERMINAL_ABI.md).</summary>
    internal object CoreColors => new
    {
        palette = Palette.ToDictionary(entry => entry.Key.ToString(CultureInfo.InvariantCulture), entry => Rgb(entry.Value)),
        foreground = Rgb(Foreground),
        background = Rgb(Background),
        cursor = Cursor is { } cursor ? Rgb(cursor) : null,
    };

    // int[], not byte[]: System.Text.Json writes byte[] as a base64 string.
    private static int[] Rgb(Color color) => [color.R, color.G, color.B];

    /// <summary>Applies Ghostty config or theme file lines. Unknown keys are ignored.</summary>
    internal void Parse(string contents)
    {
        foreach (var raw in contents.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line[0] == '#') continue;
            var separator = line.IndexOf('=');
            if (separator < 0) continue;
            var key = line[..separator].Trim();
            var text = line[(separator + 1)..].Trim();
            var value = text.Trim('"');
            // As in Ghostty, only quotes around the whole value go, so a quoted program path keeps
            // its quotes; an empty value restores the default.
            var command = text.Length >= 2 && text[0] == '"' && text[^1] == '"' ? text[1..^1] : text;
            switch (key)
            {
                case "command": Command = command.Length > 0 ? command : null; break;
                case "initial-command": InitialCommand = command.Length > 0 ? command : null; break;
                // Repeated font-family lines form a fallback list; the first is the primary font.
                case "font-family" when !_fontFamilySet && value.Length > 0:
                    FontFamily = value;
                    _fontFamilySet = true;
                    break;
                case "font-size" when float.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var size) && size > 0:
                    FontSize = size;
                    break;
                case "theme": _theme = value; break;
                case "background" when ParseColor(value) is { } color: Background = color; break;
                case "foreground" when ParseColor(value) is { } color: Foreground = color; break;
                case "cursor-color": Cursor = ParseColor(value); break;
                case "cursor-text": CursorText = ParseColor(value); break;
                case "selection-background": SelectionBackground = ParseColor(value); break;
                case "selection-foreground": SelectionForeground = ParseColor(value); break;
                case "palette":
                    var parts = value.Split('=', 2);
                    if (parts.Length == 2 && int.TryParse(parts[0].Trim(), out var index) && index is >= 0 and <= 255 && ParseColor(parts[1].Trim()) is { } entry)
                        Palette[index] = entry;
                    break;
            }
        }
    }

    /// <summary>"#RRGGBB" or "RRGGBB"; anything else (X11 names, cell-foreground) is ignored.</summary>
    internal static Color? ParseColor(string value)
    {
        var hex = value.TrimStart('#');
        return hex.Length == 6 && uint.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb)
            ? Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb)
            : null;
    }

    /// <summary>Picks from "light:A,dark:B" by mode; a plain name or the other mode's name is the fallback.</summary>
    internal static string ResolveThemeName(string raw, bool dark)
    {
        string? light = null, darkTheme = null, fallback = null;
        foreach (var token in raw.Split(','))
        {
            var entry = token.Trim();
            if (entry.Length == 0) continue;
            var parts = entry.Split(':', 2);
            if (parts.Length != 2) { fallback ??= entry; continue; }
            var name = parts[1].Trim();
            if (name.Length == 0) continue;
            switch (parts[0].Trim().ToLowerInvariant())
            {
                case "light": light ??= name; break;
                case "dark": darkTheme ??= name; break;
                default: fallback ??= name; break;
            }
        }
        return (dark ? darkTheme : light) ?? fallback ?? darkTheme ?? light ?? raw.Trim();
    }

    private static string? FindTheme(string name, IEnumerable<string> directories)
    {
        var candidates = new[] { name, StripBuiltin(name) }.Distinct();
        return directories
            .SelectMany(directory => candidates.Select(candidate => Path.Combine(directory, candidate)))
            .FirstOrDefault(File.Exists);

        static string StripBuiltin(string value)
        {
            if (value.StartsWith("builtin ", StringComparison.OrdinalIgnoreCase)) value = value[8..];
            return value.EndsWith(" (builtin)", StringComparison.OrdinalIgnoreCase) ? value[..^10] : value;
        }
    }

    /// <summary>settings.json <c>app.terminalTheme</c> {light, dark} and <c>app.terminalFont</c>
    /// {family, size}, the macOS keys (docs/terminal-themes.md). null or absent inherits Ghostty's.</summary>
    private static (string? Theme, string? Family, float? Size) ReadSettings(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return (null, null, null);
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            if (!document.RootElement.TryGetProperty("app", out var app) || app.ValueKind != JsonValueKind.Object) return (null, null, null);
            string? theme = null, family = null;
            float? size = null;
            if (app.TryGetProperty("terminalTheme", out var themes) && themes.ValueKind == JsonValueKind.Object)
            {
                var light = Text(themes, "light");
                var dark = Text(themes, "dark");
                if (light is not null || dark is not null)
                    theme = string.Join(',', new[] { light is null ? null : $"light:{light}", dark is null ? null : $"dark:{dark}" }.OfType<string>());
            }
            if (app.TryGetProperty("terminalFont", out var font) && font.ValueKind == JsonValueKind.Object)
            {
                family = Text(font, "family");
                if (font.TryGetProperty("size", out var value) && value.ValueKind == JsonValueKind.Number) size = value.GetSingle();
            }
            return (theme, family, size);
        }
        catch (JsonException)
        {
            // An unreadable settings file leaves Ghostty's values in place; Settings reports the error.
            return (null, null, null);
        }

        static string? Text(JsonElement parent, string name) =>
            parent.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text ? text : null;
    }
}
