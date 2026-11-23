using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class SidebarRowModelTests
{
    [TestMethod]
    public void SpinnerGlyphsAreStrippedOtherSymbolsStay()
    {
        Assert.AreEqual("Claude Code", SidebarRowModel.StripSpinnerGlyph("✳ Claude Code"));
        Assert.AreEqual("Fix tests", SidebarRowModel.StripSpinnerGlyph("⠋ Fix tests"));
        Assert.AreEqual("Fix tests", SidebarRowModel.StripSpinnerGlyph("◐\uFE0E Fix tests"));
        Assert.AreEqual("© 2024", SidebarRowModel.StripSpinnerGlyph("© 2024"));
        Assert.AreEqual("✳ ", SidebarRowModel.StripSpinnerGlyph("✳ "));
        Assert.AreEqual("✳x", SidebarRowModel.StripSpinnerGlyph("✳x"));
    }

    [TestMethod]
    public void DigitsNameTheFirstEightAndTheLast()
    {
        Assert.AreEqual(1, SidebarRowModel.ShortcutDigit(0, 3));
        Assert.AreEqual(3, SidebarRowModel.ShortcutDigit(2, 3));
        Assert.AreEqual(9, SidebarRowModel.ShortcutDigit(8, 9));
        Assert.IsNull(SidebarRowModel.ShortcutDigit(8, 12));
        Assert.AreEqual(9, SidebarRowModel.ShortcutDigit(11, 12));
        Assert.IsNull(SidebarRowModel.ShortcutDigit(3, 3));
    }

    [TestMethod]
    public void StatusLineFollowsTheMacOrder()
    {
        Assert.AreEqual(SidebarRowModel.StatusSource.Agent, SidebarRowModel.PickStatus("working", true, true));
        Assert.AreEqual(SidebarRowModel.StatusSource.Notification, SidebarRowModel.PickStatus("done", true, true));
        Assert.AreEqual(SidebarRowModel.StatusSource.Agent, SidebarRowModel.PickStatus("done", false, true));
        Assert.AreEqual(SidebarRowModel.StatusSource.Log, SidebarRowModel.PickStatus(null, false, true));
        Assert.IsNull(SidebarRowModel.PickStatus(null, false, false));
    }

    [TestMethod]
    public void CustomColorsTakeHexWithOrWithoutTheHash()
    {
        Assert.AreEqual("#1565C0", MainWindow.NormalizeHexColor(" 1565c0 "));
        Assert.AreEqual("#ABCDEF", MainWindow.NormalizeHexColor("#abcdef"));
        Assert.IsNull(MainWindow.NormalizeHexColor("#12345"));
        Assert.IsNull(MainWindow.NormalizeHexColor("blue"));
        Assert.IsNull(MainWindow.NormalizeHexColor(""));
    }

    [TestMethod]
    public void SidebarWidthStaysWithinTheMacRange()
    {
        Assert.AreEqual(238, MainWindow.ClampSidebarWidth(100, 2000));
        Assert.AreEqual(600, MainWindow.ClampSidebarWidth(900, 2400));
        // A third of the window at most, but never under the minimum.
        Assert.AreEqual(400, MainWindow.ClampSidebarWidth(500, 1200));
        Assert.AreEqual(238, MainWindow.ClampSidebarWidth(500, 600));
    }

    [TestMethod]
    public void WorktreeFolderRoundTripsThroughTheCore()
    {
        using var core = new CoreClient();
        core.Dispatch(new { command = "create_workspace", workspace_id = "repo", pane_id = "p1", surface_id = "s1", session_id = "a" });
        core.Dispatch(new { command = "create_workspace", workspace_id = "wt", pane_id = "p2", surface_id = "s2", session_id = "b" });
        core.Dispatch(new { command = "set_workspace_parent", workspace_id = "wt", parent_id = "repo" });
        var folder = core.Dispatch(new { command = "set_workspace_worktree_folder", workspace_id = "repo", repo = @"C:\src\repo" });
        Assert.AreEqual(@"C:\src\repo", folder.Workspaces[0].WorktreeRepo);
        var stopped = core.Dispatch(new { command = "set_workspace_worktree_folder", workspace_id = "repo", repo = (string?)null });
        Assert.IsNull(stopped.Workspaces[0].WorktreeRepo);
        Assert.IsNull(stopped.Workspaces[1].ParentId);
    }

    [TestMethod]
    public void DraggedRowsLandTogetherInOrder()
    {
        using var core = new CoreClient();
        foreach (var id in new[] { "a", "b", "c", "d" })
            core.Dispatch(new { command = "create_workspace", workspace_id = id, pane_id = "p" + id, surface_id = "s" + id, session_id = "x" + id, placement = "end" });
        string Order(CoreSnapshot snapshot) => string.Join(",", snapshot.Workspaces.Select(item => item.Id));
        var snapshot = MainWindow.MoveWorkspaces(core.Dispatch, core.Snapshot(), ["a", "b"], 4);
        Assert.AreEqual("c,d,a,b", Order(snapshot));
        snapshot = MainWindow.MoveWorkspaces(core.Dispatch, snapshot, ["b", "d"], 0);
        Assert.AreEqual("d,b,c,a", Order(snapshot));
        snapshot = MainWindow.MoveWorkspaces(core.Dispatch, snapshot, ["c"], 2);
        Assert.AreEqual("d,b,c,a", Order(snapshot));
        // Above a pinned row, a row stops right after the pinned ones.
        snapshot = core.Dispatch(new { command = "set_workspace_pinned", workspace_id = "a", pinned = true });
        snapshot = MainWindow.MoveWorkspaces(core.Dispatch, snapshot, ["c"], 0);
        Assert.AreEqual("a,c,d,b", Order(snapshot));
    }

    [TestMethod]
    public void BranchLinesAreOnePerDirectoryWithDirtyMarks()
    {
        var lines = SidebarRowModel.BranchLines(
        [
            ("main", false, @"C:\Users\me\src\api"),
            ("feature", true, @"C:\USERS\me\src\api\"),
            (null, false, @"C:\Users\me"),
            ("docs", false, null),
            (null, false, @"C:\Users\me\src\web"),
        ], title: "web", home: @"C:\Users\me");
        CollectionAssert.AreEqual(new[]
        {
            new SidebarRowModel.BranchLine("feature*", @"~\src\api"),
            new SidebarRowModel.BranchLine("docs", null),
            new SidebarRowModel.BranchLine(null, @"~\src\web"),
        }, lines);
    }
}
