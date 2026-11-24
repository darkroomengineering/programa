using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class PaneGeometryTests
{
    private static LayoutSnapshot Pane(string id) => new() { Type = "pane", PaneId = id };

    private static LayoutSnapshot Split(string id, string direction, double ratio, LayoutSnapshot first, LayoutSnapshot second) =>
        new() { Type = "split", Id = id, Direction = direction, Ratio = ratio, First = first, Second = second };

    // a | (b / c): a side-by-side split (the core's "vertical"), its right side stacked.
    private static readonly LayoutSnapshot Layout =
        Split("outer", "vertical", 0.5, Pane("a"), Split("inner", "horizontal", 0.5, Pane("b"), Pane("c")));

    private static readonly PaneGeometry.Frame Container = new(0, 0, 1008, 808);

    [TestMethod]
    public void FramesFollowTheRatiosAroundTheDividers()
    {
        CollectionAssert.AreEqual(new[] { "a", "b", "c" }, PaneGeometry.Panes(Layout));
        var frames = PaneGeometry.Frames(Layout, Container);
        Assert.AreEqual(new PaneGeometry.Frame(0, 0, 500, 808), frames["a"]);
        Assert.AreEqual(new PaneGeometry.Frame(508, 0, 500, 400), frames["b"]);
        Assert.AreEqual(new PaneGeometry.Frame(508, 408, 500, 400), frames["c"]);
    }

    [TestMethod]
    public void AResizeMovesTheInnermostBorderOnThatSide()
    {
        // b's left border is the outer split's divider; b is in its second side, so left grows b.
        var left = PaneGeometry.Resize(Layout, "b", "left", 100, Container);
        Assert.AreEqual("outer", left.SplitId);
        Assert.AreEqual(0.5 - 100.0 / 1008, left.New, 1e-9);
        // b's bottom border is the inner split's; down moves it by points of the inner split's height.
        var down = PaneGeometry.Resize(Layout, "b", "down", 404, Container);
        Assert.AreEqual(("inner", 0.5), (down.SplitId, down.Old));
        Assert.AreEqual(0.9, down.New, 1e-9);

        Assert.AreEqual("Pane has no adjacent border in direction left",
            Assert.ThrowsExactly<ControlException>(() => PaneGeometry.Resize(Layout, "a", "left", 10, Container)).Message);
        Assert.AreEqual("No vertical split ancestor for pane",
            Assert.ThrowsExactly<ControlException>(() => PaneGeometry.Resize(Layout, "a", "up", 10, Container)).Message);
        Assert.AreEqual("not_found", Assert.ThrowsExactly<ControlException>(() => PaneGeometry.Resize(Layout, "zz", "up", 10, Container)).Code);
    }

    [TestMethod]
    public void ADropNearAnEdgeSplitsThatWayAndTheMiddleJoinsThePane()
    {
        // 800 x 600: the edges are 200 and 150 wide; left and right win at the corners.
        Assert.AreEqual("left", PaneGeometry.DropZone(10, 10, 800, 600));
        Assert.AreEqual("right", PaneGeometry.DropZone(790, 590, 800, 600));
        Assert.AreEqual("up", PaneGeometry.DropZone(400, 100, 800, 600));
        Assert.AreEqual("down", PaneGeometry.DropZone(400, 500, 800, 600));
        Assert.AreEqual("center", PaneGeometry.DropZone(400, 300, 800, 600));
        // A small pane still has 80 DIP edges.
        Assert.AreEqual("left", PaneGeometry.DropZone(70, 100, 200, 200));
        Assert.AreEqual(new PaneGeometry.Frame(400, 4, 396, 592), PaneGeometry.DropPlaceholder("right", 800, 600));
        Assert.AreEqual(new PaneGeometry.Frame(4, 300, 792, 296), PaneGeometry.DropPlaceholder("down", 800, 600));
        Assert.AreEqual(new PaneGeometry.Frame(4, 4, 792, 592), PaneGeometry.DropPlaceholder("center", 800, 600));
    }

    [TestMethod]
    public void TheAdjacentPaneIsTheOneBesideThatSideWithTheMostOverlap()
    {
        // a | (b / c): left of b or c is a; right of a, b and c overlap it equally, so the nearer
        // one wins, b first in layout order.
        Assert.AreEqual("a", PaneGeometry.Adjacent(Layout, "b", -1, 0));
        Assert.AreEqual("a", PaneGeometry.Adjacent(Layout, "c", -1, 0));
        Assert.AreEqual("b", PaneGeometry.Adjacent(Layout, "a", 1, 0));
        Assert.AreEqual("b", PaneGeometry.Adjacent(Layout, "c", 0, -1));
        Assert.IsNull(PaneGeometry.Adjacent(Layout, "a", -1, 0));
        Assert.IsNull(PaneGeometry.Adjacent(Layout, "b", 1, 0));
        // (a / b) | c, with b taller: right of a is c, and left of c is b, which overlaps it most.
        var stacked = Split("outer", "vertical", 0.5, Split("inner", "horizontal", 0.3, Pane("a"), Pane("b")), Pane("c"));
        Assert.AreEqual("c", PaneGeometry.Adjacent(stacked, "a", 1, 0));
        Assert.AreEqual("b", PaneGeometry.Adjacent(stacked, "c", -1, 0));
        Assert.IsNull(PaneGeometry.Adjacent(Pane("a"), "a", 1, 0));
    }

    [TestMethod]
    public void EqualizingGivesEveryPaneTheSameShareAndCanKeepToOneOrientation()
    {
        var all = PaneGeometry.Equalized(Layout, null);
        CollectionAssert.AreEqual(new[] { ("outer", 1.0 / 3), ("inner", 0.5) }, all);
        // macOS names: "vertical" is stacked, the core's "horizontal".
        CollectionAssert.AreEqual(new[] { ("inner", 0.5) }, PaneGeometry.Equalized(Layout, "vertical"));
        CollectionAssert.AreEqual(new[] { ("outer", 1.0 / 3) }, PaneGeometry.Equalized(Layout, "horizontal"));
        Assert.AreEqual(0, PaneGeometry.Equalized(Pane("a"), null).Count);
    }
}
