using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class SidebarTests
{
    [TestMethod]
    public void RenameWorkspaceRoundTripsThroughTheCore()
    {
        using var core = new CoreClient();
        core.Dispatch(new { command = "create_workspace", workspace_id = "w", pane_id = "p", surface_id = "s", session_id = "session" });
        Assert.IsNull(core.Snapshot().Workspaces[0].Title);
        Assert.AreEqual("api", core.Dispatch(new { command = "rename_workspace", workspace_id = "w", title = " api " }).Workspaces[0].Title);
        Assert.IsNull(core.Dispatch(new { command = "rename_workspace", workspace_id = "w", title = "" }).Workspaces[0].Title);
    }

    [TestMethod]
    public void ConsoleExecutablePathsReadAsTheirName()
    {
        Assert.AreEqual("powershell", MainWindow.DisplayTitle(@"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"));
        Assert.AreEqual("✳ Claude Code", MainWindow.DisplayTitle("✳ Claude Code"));
        Assert.IsNull(MainWindow.DisplayTitle("  "));
    }

    [TestMethod]
    public void WorkspaceShortcutsAreValidAndDisplayLikeWindows()
    {
        // Every default is well formed and none collide.
        ShortcutSettings.Validate(ShortcutSettings.Defaults);
        Assert.AreEqual("Ctrl+Alt+Shift+W", ShortcutSettings.Display(ShortcutSettings.Defaults["close_workspace"]));
        Assert.AreEqual("Ctrl+PgDn", ShortcutSettings.Display(ShortcutSettings.Defaults["next_workspace"]));
        Assert.AreEqual("Ctrl+=", ShortcutSettings.Display(ShortcutSettings.Defaults["font_bigger"]));
        Assert.AreEqual("Ctrl+Shift+Enter", ShortcutSettings.Display(ShortcutSettings.Defaults["toggle_zoom"]));
    }

    [TestMethod]
    public void PaletteMatchesEveryWordInAnyOrder()
    {
        Assert.IsTrue(MainWindow.Matches("Toggle pane zoom", "zoom PANE"));
        Assert.IsTrue(MainWindow.Matches("Go to workspace: api", ""));
        Assert.IsFalse(MainWindow.Matches("Toggle pane zoom", "zoom tab"));
    }

    [TestMethod]
    public void RenameSurfaceRoundTripsThroughTheCore()
    {
        using var core = new CoreClient();
        core.Dispatch(new { command = "create_workspace", workspace_id = "w", pane_id = "p", surface_id = "s", session_id = "session" });
        var renamed = core.Dispatch(new { command = "rename_surface", workspace_id = "w", pane_id = "p", surface_id = "s", title = "server" });
        Assert.AreEqual("server", renamed.Workspaces[0].Panes[0].Surfaces[0].Title);
    }
}
