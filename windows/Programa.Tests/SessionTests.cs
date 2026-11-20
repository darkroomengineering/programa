using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class SessionTests
{
    [TestMethod]
    public void AnIdlePromptIsNotSavedTwice()
    {
        Assert.AreEqual("ls\nfile.txt", SessionStore.WithoutLastLine("ls\nfile.txt\nPS C:\\> "));
        Assert.AreEqual("ls", SessionStore.WithoutLastLine("ls\nPS C:\\> \n\n"));
        Assert.AreEqual(string.Empty, SessionStore.WithoutLastLine("PS C:\\> "));
    }

    [TestMethod]
    public void SavedCoreSnapshotSeedsAnIdenticalLayout()
    {
        using var original = new CoreClient();
        original.Dispatch(new { command = "create_workspace", workspace_id = "w", pane_id = "p", surface_id = "s", session_id = "session" });
        original.Dispatch(new { command = "split_pane", workspace_id = "w", pane_id = "p", split_id = "x", new_pane_id = "p2", new_surface_id = "s2", session_id = "session-2", direction = "vertical", ratio = 0.3 });
        original.Dispatch(new { command = "rename_workspace", workspace_id = "w", title = "api" });
        original.Dispatch(new { command = "rename_surface", workspace_id = "w", pane_id = "p2", surface_id = "s2", title = "logs" });
        var saved = JsonDocument.Parse(original.SnapshotJson()).RootElement;

        using var restored = new CoreClient();
        var snapshot = restored.Seed(saved);
        Assert.AreEqual("api", snapshot.Workspaces[0].Title);
        Assert.AreEqual("logs", snapshot.Workspaces[0].Panes[1].Surfaces[0].Title);
        Assert.AreEqual(0.3, snapshot.Workspaces[0].Layout.Ratio, 1e-9);
        Assert.AreEqual("p2", snapshot.Workspaces[0].SelectedPaneId);
    }

    [TestMethod]
    public void SessionFileRoundTripsAndSetsABrokenFileAside()
    {
        var directory = Directory.CreateTempSubdirectory("programa-session-").FullName;
        try
        {
            var path = Path.Combine(directory, "session.json");
            var core = JsonDocument.Parse("""{"abi_version":1,"revision":1,"selected_workspace_id":null,"workspaces":[]}""").RootElement;
            var session = new SavedSession(SessionStore.CurrentVersion, core, false, 300, new SessionWindow(10, 20, 800, 600, true),
                new Dictionary<string, SessionTerminal> { ["s"] = new(@"C:\Work", "line one\nline two", 15) });
            SessionStore.Save(session, path);

            var loaded = SessionStore.Load(path)!;
            Assert.IsFalse(loaded.SidebarVisible);
            Assert.AreEqual(300, loaded.SidebarWidth);
            Assert.AreEqual(new SessionWindow(10, 20, 800, 600, true), loaded.Window);
            Assert.AreEqual(new SessionTerminal(@"C:\Work", "line one\nline two", 15), loaded.Terminals["s"]);
            Assert.IsNull(loaded.OtherWindows);

            // Every other window rides along under the first, each with its own id.
            var second = session with { WindowId = "window-b", Terminals = new() { ["t"] = new(@"D:\Other", null, null) } };
            SessionStore.Save(session with { WindowId = "window-a", OtherWindows = [second] }, path);
            var both = SessionStore.Load(path)!;
            Assert.AreEqual("window-a", both.WindowId);
            Assert.AreEqual("window-b", both.OtherWindows!.Single().WindowId);
            Assert.AreEqual(@"D:\Other", both.OtherWindows![0].Terminals["t"].Cwd);

            File.WriteAllText(path, "{ not json");
            Assert.IsNull(SessionStore.Load(path));
            Assert.IsTrue(File.Exists(path + ".broken"));
            Assert.IsNull(SessionStore.Load(path));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
