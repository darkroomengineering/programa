using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;

namespace Programa;

/// <summary>The app and notification settings in settings.json the Windows app honors, with the
/// macOS keys and defaults (docs/settings-json.md): app.appearance, app.warnBeforeQuit,
/// app.terminalTheme, app.terminalFont, notifications.sound, storage.autoCleanCaches,
/// storage.lowDiskWarningGB, customCommands.trustedDirectories, sidebarAppearance.showClaudeQuota, and the
/// app.* and automation.* switches below.</summary>
internal sealed record AppSettings(string Appearance, bool WarnBeforeQuit, string Sound, string? ThemeLight, string? ThemeDark, string? FontFamily, double? FontSize,
    bool AutoCleanCaches = true, double LowDiskWarningGB = 20, IReadOnlyList<string>? TrustedDirectories = null, bool ShowProviderUsage = true)
{
    private static readonly AppSettings Defaults = new("system", true, "default", null, null, null, null);

    /// <summary>app.confirmCloseLastPane: closing a workspace's last tab asks even when nothing runs.</summary>
    internal bool ConfirmCloseLastPane { get; init; } = true;
    /// <summary>app.newWorkspacePlacement: top, afterCurrent or end.</summary>
    internal string NewWorkspacePlacement { get; init; } = "afterCurrent";
    /// <summary>app.commandPaletteSearchesAllSurfaces: the switcher lists every workspace's tabs, not only the current one's.</summary>
    internal bool CommandPaletteSearchesAllSurfaces { get; init; }
    /// <summary>automation.claudeCodeIntegration: Claude Code gets Programa's hooks and MCP server.</summary>
    internal bool ClaudeCodeIntegration { get; init; } = true;
    /// <summary>automation.claudeTeamsByDefault: plain claude starts with agent teams on.</summary>
    internal bool ClaudeTeamsByDefault { get; init; } = true;
    /// <summary>automation.holdAgentTextWhileTyping: socket writes wait for a typed draft (draft_in_progress).</summary>
    internal bool HoldAgentTextWhileTyping { get; init; } = true;
    /// <summary>automation.protectApprovalPrompts: socket writes leave an approval prompt to you (agent_awaiting_approval).</summary>
    internal bool ProtectApprovalPrompts { get; init; } = true;

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
                root?["sidebarAppearance"]?["showClaudeQuota"] is JsonValue usage && usage.TryGetValue<bool>(out var showUsage) ? showUsage : true)
            {
                ConfirmCloseLastPane = Flag(app?["confirmCloseLastPane"], true),
                NewWorkspacePlacement = Text(app?["newWorkspacePlacement"]) is ("top" or "afterCurrent" or "end") and var placement ? placement : "afterCurrent",
                CommandPaletteSearchesAllSurfaces = Flag(app?["commandPaletteSearchesAllSurfaces"], false),
                ClaudeCodeIntegration = Flag(root?["automation"]?["claudeCodeIntegration"], true),
                ClaudeTeamsByDefault = Flag(root?["automation"]?["claudeTeamsByDefault"], true),
                HoldAgentTextWhileTyping = Flag(root?["automation"]?["holdAgentTextWhileTyping"], true),
                ProtectApprovalPrompts = Flag(root?["automation"]?["protectApprovalPrompts"], true),
            };
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            return Defaults;
        }
    }

    private static bool Flag(JsonNode? node, bool fallback) => node is JsonValue value && value.TryGetValue<bool>(out var on) ? on : fallback;

    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) && text.Length > 0 ? text : null;
}
