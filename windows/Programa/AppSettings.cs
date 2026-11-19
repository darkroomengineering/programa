using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;

namespace Programa;

/// <summary>The app and notification settings in settings.json the Windows app honors, with the
/// macOS keys and defaults (docs/settings-json.md): app.appearance, app.warnBeforeQuit,
/// app.terminalTheme, app.terminalFont, notifications.sound, storage.autoCleanCaches,
/// storage.lowDiskWarningGB, customCommands.trustedDirectories and sidebarAppearance.showClaudeQuota.</summary>
internal sealed record AppSettings(string Appearance, bool WarnBeforeQuit, string Sound, string? ThemeLight, string? ThemeDark, string? FontFamily, double? FontSize,
    bool AutoCleanCaches = true, double LowDiskWarningGB = 20, IReadOnlyList<string>? TrustedDirectories = null, bool ShowProviderUsage = true)
{
    private static readonly AppSettings Defaults = new("system", true, "default", null, null, null, null);

    internal ElementTheme Theme => Appearance switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };

    /// <summary>"none" silences toasts; the macOS sound names (Glass, Ping…) play Windows' default sound.</summary>
    internal bool Silent => string.Equals(Sound, "none", StringComparison.OrdinalIgnoreCase);

    internal static AppSettings Load()
    {
        try
        {
            if (!File.Exists(ShortcutSettings.SettingsPath)) return Defaults;
            var root = JsonNode.Parse(File.ReadAllText(ShortcutSettings.SettingsPath), null, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            var app = root?["app"] as JsonObject;
            return new AppSettings(
                Text(app?["appearance"]) is { } appearance && appearance is "light" or "dark" or "system" ? appearance : Defaults.Appearance,
                app?["warnBeforeQuit"] is JsonValue warn && warn.TryGetValue<bool>(out var on) ? on : Defaults.WarnBeforeQuit,
                Text(root?["notifications"]?["sound"]) ?? Defaults.Sound,
                Text(app?["terminalTheme"]?["light"]),
                Text(app?["terminalTheme"]?["dark"]),
                Text(app?["terminalFont"]?["family"]),
                app?["terminalFont"]?["size"] is JsonValue size && size.TryGetValue<double>(out var points) && points > 0 ? points : null,
                root?["storage"]?["autoCleanCaches"] is JsonValue clean && clean.TryGetValue<bool>(out var auto) ? auto : true,
                root?["storage"]?["lowDiskWarningGB"] is JsonValue low && low.TryGetValue<double>(out var gb) && gb >= 0 ? gb : 20,
                // A list replaces the trusted roots of programa.json commands; trimmed, blanks dropped.
                root?["customCommands"]?["trustedDirectories"] is JsonArray roots
                    ? roots.Select(Text).OfType<string>().Select(path => path.Trim()).Where(path => path.Length > 0).ToList()
                    : null,
                root?["sidebarAppearance"]?["showClaudeQuota"] is JsonValue usage && usage.TryGetValue<bool>(out var showUsage) ? showUsage : true);
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            return Defaults;
        }
    }

    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) && text.Length > 0 ? text : null;
}
