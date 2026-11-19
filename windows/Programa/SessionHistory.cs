using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Programa;

/// <summary>Session history, as on macOS (docs/plans/snapshot-restore.md): each launch copies the
/// session file into session-history\&lt;yyyyMMdd-HHmmss&gt;-&lt;session&gt;.json before anything can
/// overwrite it, skipping a copy identical to the newest and keeping the 10 newest. snapshot.list
/// shows the archives; snapshot.restore opens one as new windows, with new ids, so it never touches
/// an open window or a running shell. An unreadable session file falls back to the newest archive
/// that restores. Release and development builds share the folder, each owning its own archives.</summary>
internal static partial class SessionHistory
{
    internal const int Kept = 10;
    private const int ScanLimit = 256;

    internal static string Folder(string sessionPath) => Path.Combine(Path.GetDirectoryName(sessionPath)!, "session-history");

    /// <summary>The archive name's tail: session or session-dev.</summary>
    private static string Owner(string sessionPath) => Path.GetFileNameWithoutExtension(sessionPath);

    /// <summary>The archives, newest first; only this build's when <paramref name="owned"/>.</summary>
    internal static List<string> Archives(string sessionPath, bool owned)
    {
        var folder = Folder(sessionPath);
        if (!Directory.Exists(folder)) return [];
        var owner = Owner(sessionPath);
        return Directory.EnumerateFiles(folder, "*.json").Take(ScanLimit)
            .Where(path => Stamp(path) is not null && (!owned || Path.GetFileNameWithoutExtension(path)[16..] == owner))
            .OrderByDescending(path => Path.GetFileName(path), StringComparer.Ordinal).ToList();
    }

    /// <summary>When an archive was saved, from its name; null for a file that is not an archive.</summary>
    private static DateTimeOffset? Stamp(string path)
    {
        var name = Path.GetFileNameWithoutExtension(path);
        return name.Length > 16 && name[15] == '-'
            && DateTime.TryParseExact(name[..15], "yyyyMMdd-HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var stamp)
            ? new DateTimeOffset(stamp, TimeSpan.Zero) : null;
    }

    /// <summary>Copies the session file into the history; false when there was nothing new to keep.
    /// Never fails a launch.</summary>
    internal static bool Rotate(string? sessionPath = null)
    {
        sessionPath ??= SessionStore.DefaultPath;
        try
        {
            if (!File.Exists(sessionPath)) return false;
            var bytes = File.ReadAllBytes(sessionPath);
            var archives = Archives(sessionPath, owned: true);
            if (archives.Count > 0 && File.ReadAllBytes(archives[0]).AsSpan().SequenceEqual(bytes)) return false;
            Directory.CreateDirectory(Folder(sessionPath));
            var stamp = File.GetLastWriteTimeUtc(sessionPath).ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            File.WriteAllBytes(Path.Combine(Folder(sessionPath), $"{stamp}-{Owner(sessionPath)}.json"), bytes);
            foreach (var old in Archives(sessionPath, owned: true).Skip(Kept)) File.Delete(old);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LaunchLog.Write($"session: history not kept: {error.Message}");
            return false;
        }
    }

    /// <summary>snapshot.list: every archive that parses, newest first.</summary>
    internal static object List(string? sessionPath = null)
    {
        sessionPath ??= SessionStore.DefaultPath;
        var snapshots = new List<object>();
        foreach (var path in Archives(sessionPath, owned: false))
        {
            if (Read(path) is not { } session) continue;
            var saved = session.SavedAt ?? Stamp(path)!.Value;
            var (windows, workspaces, panels) = Counts(session);
            snapshots.Add(new
            {
                id = Path.GetFileNameWithoutExtension(path),
                saved_at = saved.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
                created_at = saved.ToUnixTimeMilliseconds() / 1000.0,
                clean_shutdown = session.CleanShutdown,
                window_count = windows,
                workspace_count = workspaces,
                panel_count = panels,
            });
        }
        return new { snapshots };
    }

    /// <summary>snapshot.restore: the archive named <paramref name="id"/> (else this build's newest),
    /// with fresh ids, and its counts; the caller opens its windows.</summary>
    internal static (List<SavedSession> Windows, int Workspaces, int Panels) Restore(string? id, string? sessionPath = null)
    {
        sessionPath ??= SessionStore.DefaultPath;
        var path = id is null || id.Equals("latest", StringComparison.OrdinalIgnoreCase)
            ? Archives(sessionPath, owned: true).FirstOrDefault()
            : Archives(sessionPath, owned: false).FirstOrDefault(item => Path.GetFileNameWithoutExtension(item) == id);
        if (path is null) throw new ControlException("not_found", "No archived snapshot found");
        if (Read(path, freshIds: true) is not { } session) throw new ControlException("not_found", "Archived snapshot is unreadable or corrupt");
        if (session.Version != SessionStore.CurrentVersion)
            throw new ControlException("version_mismatch", $"Archived snapshot version {session.Version} does not match the current schema version {SessionStore.CurrentVersion}");
        var (_, workspaces, panels) = Counts(session);
        if (workspaces == 0) throw new ControlException("not_found", "Archived snapshot has no windows to restore");
        return ([session with { OtherWindows = null }, .. session.OtherWindows ?? []], workspaces, panels);
    }

    /// <summary>The newest of this build's archives that restores, for an unreadable session file.</summary>
    internal static SavedSession? NewestRestorable(string? sessionPath = null)
    {
        sessionPath ??= SessionStore.DefaultPath;
        foreach (var path in Archives(sessionPath, owned: true).Take(Kept))
            if (Read(path) is { Version: SessionStore.CurrentVersion } session && Counts(session).Workspaces > 0)
            {
                LaunchLog.Write($"session: restored from {Path.GetFileName(path)}");
                return session;
            }
        return null;
    }

    private static SavedSession? Read(string path, bool freshIds = false)
    {
        try
        {
            var bytes = File.ReadAllBytes(path);
            return SessionStore.Parse(freshIds ? Encoding.UTF8.GetBytes(FreshIds(Encoding.UTF8.GetString(bytes))) : bytes);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>Every window, workspace, pane, split, surface and session id swapped for a new one,
    /// the same old id always for the same new one.</summary>
    internal static string FreshIds(string json)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        return GeneratedId().Replace(json, match =>
        {
            if (!map.TryGetValue(match.Value, out var fresh))
                map[match.Value] = fresh = $"{match.Groups[1].Value}-{Guid.NewGuid():N}";
            return fresh;
        });
    }

    [GeneratedRegex(@"\b(window|workspace|pane|split|surface|session)-[0-9a-f]{32}\b")]
    private static partial Regex GeneratedId();

    private static (int Windows, int Workspaces, int Panels) Counts(SavedSession session)
    {
        var windows = new[] { session }.Concat(session.OtherWindows ?? []).ToList();
        var workspaces = windows.SelectMany(window => Elements(window.Core, "workspaces")).ToList();
        return (windows.Count, workspaces.Count, workspaces.SelectMany(workspace => Elements(workspace, "panes")).Sum(pane => Elements(pane, "surfaces").Count()));
    }

    private static IEnumerable<JsonElement> Elements(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var items) && items.ValueKind == JsonValueKind.Array ? items.EnumerateArray() : [];
}
