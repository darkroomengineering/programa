namespace Programa;

/// <summary>The parts of a sidebar row that are plain rules, as on macOS (Sources/TabItemView.swift,
/// Sources/WorkspaceSidebarModels.swift, Sources/WorkspaceShortcutMapper.swift).</summary>
internal static class SidebarRowModel
{
    internal sealed record BranchLine(string? Branch, string? Directory);

    internal enum StatusSource { Agent, Notification, Log }

    /// <summary>Drops one leading agent spinner glyph and its space ("✳ Fix tests" becomes "Fix
    /// tests"). Only spinner frames count, so "© 2024" stays; a title of the glyph alone stays.</summary>
    internal static string StripSpinnerGlyph(string title)
    {
        if (title.Length == 0 || !IsSpinnerGlyph(title[0])) return title;
        var next = 1;
        while (next < title.Length && title[next] == (char)0xFE0E) next++;
        return next + 1 < title.Length && title[next] == ' ' ? title[(next + 1)..] : title;
    }

    private static bool IsSpinnerGlyph(char c) =>
        c is >= (char)0x2801 and <= (char)0x28FF or >= (char)0x25D0 and <= (char)0x25D3 or >= (char)0x25F4 and <= (char)0x25F7
            or (char)0x00B7 or (char)0x2722 or (char)0x2733 or (char)0x2736 or (char)0x273B or (char)0x273D;

    /// <summary>The Ctrl+N digit that selects the workspace at <paramref name="index"/>: 1-8 the
    /// first eight, 9 the last one.</summary>
    internal static int? ShortcutDigit(int index, int count) =>
        index < 0 || index >= count ? null : index < 8 ? index + 1 : index == count - 1 ? 9 : null;

    /// <summary>The one status line: the agent while it works or waits, else the latest notification,
    /// else the agent's resting state, else the latest log line.</summary>
    internal static StatusSource? PickStatus(string? agentState, bool hasNotification, bool hasLog) =>
        agentState is "working" or "blocked" ? StatusSource.Agent
            : hasNotification ? StatusSource.Notification
            : agentState is not null ? StatusSource.Agent
            : hasLog ? StatusSource.Log
            : null;

    /// <summary>One line per directory (or per branch, for a panel without one), in panel order: a
    /// later panel's branch replaces an earlier one's, `*` marks a dirty tree, and the home directory
    /// or one the title already shows is left out.</summary>
    internal static List<BranchLine> BranchLines(IEnumerable<(string? Branch, bool Dirty, string? Directory)> panels, string title, string? home = null)
    {
        var order = new List<string>();
        var entries = new Dictionary<string, (string? Branch, bool Dirty, string? Directory)>(StringComparer.OrdinalIgnoreCase);
        foreach (var panel in panels)
        {
            var branch = string.IsNullOrWhiteSpace(panel.Branch) ? null : panel.Branch.Trim();
            var directory = string.IsNullOrWhiteSpace(panel.Directory) ? null : panel.Directory.Trim();
            if (branch is null && directory is null) continue;
            var key = directory is not null ? "d:" + directory.TrimEnd('\\', '/') : "b:" + branch;
            if (!entries.TryGetValue(key, out var existing))
            {
                order.Add(key);
                entries[key] = (branch, branch is not null && panel.Dirty, directory);
            }
            else if (directory is not null && branch is not null) entries[key] = existing with { Branch = branch, Dirty = panel.Dirty };
            else if (directory is null && panel.Dirty) entries[key] = existing with { Dirty = true };
        }
        var lines = new List<BranchLine>();
        foreach (var key in order)
        {
            var (branch, dirty, directory) = entries[key];
            var shown = directory is null ? null : GitInfo.AbbreviateHome(directory, home);
            if (shown == "~" || string.Equals(shown, title, StringComparison.OrdinalIgnoreCase)) shown = null;
            if (branch is null && shown is null) continue;
            lines.Add(new BranchLine(branch is null ? null : dirty ? branch + "*" : branch, shown));
        }
        return lines;
    }
}
