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

    /// <summary>app.autoResumeAgents: a restored terminal whose shell did not survive starts the agent it ran at quit again.</summary>
    internal bool AutoResumeAgents { get; init; } = true;
    /// <summary>app.reapLeftoverAgentProcesses: a Claude Code session that exits takes what it started down with it.</summary>
    internal bool ReapLeftoverAgentProcesses { get; init; } = true;
    /// <summary>automation.socketControlMode, normalized: off, programaOnly, automation or password
    /// (allowAll and the legacy aliases mean automation: the pipe never admits other users).</summary>
    internal string SocketControlMode { get; init; } = "programaOnly";
    /// <summary>automation.socketPassword, for password mode; null when unset or empty.</summary>
    internal string? SocketPassword { get; init; }
    /// <summary>app.saveScrollbackOnQuit: terminals' recent output is saved with the session and shown again on restore.</summary>
    internal bool SaveScrollbackOnQuit { get; init; } = true;
    /// <summary>automation.agentScreenDetection: agents without hooks get a status read off the screen.</summary>
    internal bool AgentScreenDetection { get; init; } = true;
    /// <summary>browser.externalAppOpenAllowlist: `app|scheme` entries that open without asking.</summary>
    internal IReadOnlyList<string> ExternalAppOpenAllowlist { get; init; } = [];

    internal ElementTheme Theme => Appearance switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };

    /// <summary>"none" silences toasts.</summary>
    internal bool Silent => string.Equals(Sound, "none", StringComparison.OrdinalIgnoreCase);

    /// <summary>The Windows toast sounds the picker offers, each with the macOS name it writes to notifications.sound.</summary>
    internal static readonly IReadOnlyList<(string Event, string Value)> WindowsSounds =
        [("Default", "default"), ("IM", "Ping"), ("Mail", "Glass"), ("Reminder", "Hero"), ("SMS", "Pop")];

    // Every macOS sound plays the Windows sound closest to it in character.
    private static readonly Dictionary<string, string> SoundEvents = new(StringComparer.OrdinalIgnoreCase)
    {
        ["default"] = "Default",
        ["Ping"] = "IM", ["Tink"] = "IM", ["Morse"] = "IM",
        ["Glass"] = "Mail", ["Purr"] = "Mail", ["Bottle"] = "Mail",
        ["Hero"] = "Reminder", ["Submarine"] = "Reminder", ["Blow"] = "Reminder", ["Funk"] = "Reminder",
        ["Pop"] = "SMS", ["Frog"] = "SMS", ["Basso"] = "SMS", ["Sosumi"] = "SMS",
    };

    /// <summary>The toast sound (ms-winsoundevent:Notification.&lt;event&gt;) a notifications.sound value plays:
    /// null for none, Default for a name macOS does not ship.</summary>
    internal static string? SoundEventFor(string sound) =>
        string.Equals(sound, "none", StringComparison.OrdinalIgnoreCase) ? null : SoundEvents.GetValueOrDefault(sound, "Default");

    /// <summary>macOS's socketControlMode values and legacy aliases, as Windows applies them; null when unknown.</summary>
    internal static string? NormalizeSocketMode(string? raw) => raw?.Trim().Replace("-", "").Replace("_", "").ToLowerInvariant() switch
    {
        "off" => "off",
        "programaonly" => "programaOnly",
        "password" => "password",
        "automation" or "notifications" or "allowall" or "openaccess" or "fullopenaccess" or "full" => "automation",
        _ => null,
    };

    internal static AppSettings Load()
    {
        try
        {
            return File.Exists(ShortcutSettings.SettingsPath) ? Parse(File.ReadAllText(ShortcutSettings.SettingsPath)) : Defaults;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return Defaults;
        }
    }

    /// <summary>settings.json's text as settings; a file that does not parse gives the defaults.</summary>
    internal static AppSettings Parse(string json)
    {
        try
        {
            var root = JsonNode.Parse(json, null, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
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
                AutoResumeAgents = Flag(app?["autoResumeAgents"], true),
                ReapLeftoverAgentProcesses = Flag(app?["reapLeftoverAgentProcesses"], true),
                SaveScrollbackOnQuit = Flag(app?["saveScrollbackOnQuit"], true),
                AgentScreenDetection = Flag(root?["automation"]?["agentScreenDetection"], true),
                SocketControlMode = NormalizeSocketMode(Text(root?["automation"]?["socketControlMode"])) ?? "programaOnly",
                SocketPassword = Text(root?["automation"]?["socketPassword"]),
                // Only `app|scheme` entries count, as on macOS: a bare app would allow every scheme.
                ExternalAppOpenAllowlist = root?["browser"]?["externalAppOpenAllowlist"] is JsonArray allowed
                    ? allowed.Select(Text).OfType<string>().Where(entry => entry.IndexOf('|') is > 0 and var bar && bar < entry.Length - 1).ToList()
                    : [],
            };
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException)
        {
            return Defaults;
        }
    }

    private static bool Flag(JsonNode? node, bool fallback) => node is JsonValue value && value.TryGetValue<bool>(out var on) ? on : fallback;

    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) && text.Length > 0 ? text : null;
}
