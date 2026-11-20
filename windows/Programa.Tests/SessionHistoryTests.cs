using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class SessionHistoryTests
{
    private string _folder = null!;
    private string Session => Path.Combine(_folder, "session.json");

    [TestInitialize]
    public void Setup() => _folder = Directory.CreateTempSubdirectory("programa-history-").FullName;

    [TestCleanup]
    public void Cleanup() => Directory.Delete(_folder, recursive: true);

    private const string Workspace = "workspace-0123456789abcdef0123456789abcdef";
    private const string Surface = "surface-0123456789abcdef0123456789abcdef";

    /// <summary>A one-window session with one workspace and two tabs, saved at <paramref name="at"/>.</summary>
    private void Save(DateTime at, int version = SessionStore.CurrentVersion, bool? clean = null, string title = "a")
    {
        var core = JsonSerializer.SerializeToElement(new
        {
            workspaces = new[] { new { id = Workspace, title, panes = new[] { new { id = "pane-0123456789abcdef0123456789abcdef", surfaces = new[] { new { id = Surface }, new { id = "surface-ffffffffffffffffffffffffffffffff" } } } } } },
        });
        var session = new SavedSession(version, core, true, 240, null, new() { [Surface] = new SessionTerminal("C:\\src", "hello", null) }, CleanShutdown: clean);
        SessionStore.Save(session, Session);
        File.SetLastWriteTimeUtc(Session, at);
    }

    private static JsonNode Json(object value) => JsonNode.Parse(JsonSerializer.Serialize(value))!;

    [TestMethod]
    public void EachLaunchKeepsTheSessionOnceAndOnlyTheNewestTen()
    {
        Assert.IsFalse(SessionHistory.Rotate(Session));
        var start = new DateTime(2026, 11, 19, 8, 0, 0, DateTimeKind.Utc);
        Save(start);
        Assert.IsTrue(SessionHistory.Rotate(Session));
        // The same session again (a relaunch loop) is not kept twice.
        Assert.IsFalse(SessionHistory.Rotate(Session));
        for (var minute = 1; minute <= 12; minute++)
        {
            Save(start.AddMinutes(minute), title: $"t{minute}");
            SessionHistory.Rotate(Session);
        }
        var archives = SessionHistory.Archives(Session, owned: true).Select(Path.GetFileNameWithoutExtension).ToList();
        Assert.AreEqual(SessionHistory.Kept, archives.Count);
        Assert.AreEqual("20261119-081200-session", archives[0]);
        // Another build's archives in the same folder are listed but never pruned or picked as latest.
        File.WriteAllText(Path.Combine(SessionHistory.Folder(Session), "20991231-000000-session-dev.json"), "{}");
        Assert.AreEqual("20261119-081200-session", SessionHistory.Archives(Session, owned: true)[0].Split('\\')[^1][..^5]);
        Assert.AreEqual(SessionHistory.Kept + 1, SessionHistory.Archives(Session, owned: false).Count);
    }

    [TestMethod]
    public void TheListCountsWhatEachArchiveHolds()
    {
        Save(new DateTime(2026, 11, 19, 9, 30, 0, DateTimeKind.Utc), clean: true);
        SessionHistory.Rotate(Session);
        var entry = Json(SessionHistory.List(Session))["snapshots"]!.AsArray().Single()!;
        Assert.AreEqual("20261119-093000-session", (string?)entry["id"]);
        Assert.AreEqual(true, (bool?)entry["clean_shutdown"]);
        Assert.AreEqual((1, 1, 2), ((int)entry["window_count"]!, (int)entry["workspace_count"]!, (int)entry["panel_count"]!));
        Assert.AreEqual("2026-11-19T09:30:00Z", (string?)entry["saved_at"]);
    }

    [TestMethod]
    public void ARestoreGetsNewIdsAndRefusesAnotherVersion()
    {
        Assert.AreEqual("not_found", Assert.ThrowsExactly<ControlException>(() => SessionHistory.Restore(null, Session)).Code);
        Save(new DateTime(2026, 11, 19, 10, 0, 0, DateTimeKind.Utc));
        SessionHistory.Rotate(Session);
        var (windows, workspaces, panels) = SessionHistory.Restore("latest", Session);
        Assert.AreEqual((1, 1, 2), (windows.Count, workspaces, panels));
        var restored = windows[0];
        var restoredWorkspace = restored.Core.GetProperty("workspaces")[0].GetProperty("id").GetString()!;
        Assert.AreNotEqual(Workspace, restoredWorkspace);
        StringAssert.StartsWith(restoredWorkspace, "workspace-");
        // The saved terminal follows its surface to the new id.
        var restoredSurface = restored.Core.GetProperty("workspaces")[0].GetProperty("panes")[0].GetProperty("surfaces")[0].GetProperty("id").GetString()!;
        Assert.AreEqual("hello", restored.Terminals[restoredSurface].Text);
        Assert.IsFalse(restored.Terminals.ContainsKey(Surface));

        Save(new DateTime(2026, 11, 19, 11, 0, 0, DateTimeKind.Utc), version: 99);
        SessionHistory.Rotate(Session);
        Assert.AreEqual("version_mismatch", Assert.ThrowsExactly<ControlException>(() => SessionHistory.Restore(null, Session)).Code);
        Assert.AreEqual("not_found", Assert.ThrowsExactly<ControlException>(() => SessionHistory.Restore("nope", Session)).Code);
        // An unreadable session falls back to the newest archive that restores, skipping the other version.
        Assert.AreEqual(Workspace, SessionHistory.NewestRestorable(Session)!.Core.GetProperty("workspaces")[0].GetProperty("id").GetString());
    }
}
