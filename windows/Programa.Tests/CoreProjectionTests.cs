using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class CoreProjectionTests
{
    [TestMethod]
    public void NativeCoreDispatchReordersSurfaces()
    {
        using var core = new CoreClient();
        var created = core.Dispatch(new { command = "create_workspace", workspace_id = "w", pane_id = "p", surface_id = "s1", session_id = "session-1" });
        var second = core.Dispatch(new { command = "create_surface", workspace_id = "w", pane_id = "p", surface_id = "s2", session_id = "session-2" });
        var reordered = core.Dispatch(new { command = "reorder_surface", workspace_id = "w", pane_id = "p", surface_id = "s2", before_surface_id = "s1" });

        Assert.AreEqual(1UL, created.Revision);
        Assert.AreEqual(2UL, second.Revision);
        Assert.AreEqual(3UL, reordered.Revision);
        CollectionAssert.AreEqual(new[] { "s2", "s1" }, reordered.Workspaces[0].Panes[0].Surfaces.Select(surface => surface.Id).ToArray());
    }

    [TestMethod]
    public void ATabColorReachesTheSnapshotAndClears()
    {
        using var core = new CoreClient();
        core.Dispatch(new { command = "create_workspace", workspace_id = "w", pane_id = "p", surface_id = "s1", session_id = "session-1" });
        var colored = core.Dispatch(new { command = "set_surface_color", workspace_id = "w", pane_id = "p", surface_id = "s1", color = MainWindow.NormalizedHex("1565c0") });
        Assert.AreEqual("#1565C0", colored.Workspaces[0].Panes[0].Surfaces[0].Color);
        Assert.IsTrue(core.SnapshotJson().Contains("\"color\":\"#1565C0\"", StringComparison.Ordinal), "the session file keeps the core's JSON");
        var cleared = core.Dispatch(new { command = "set_surface_color", workspace_id = "w", pane_id = "p", surface_id = "s1", color = (string?)null });
        Assert.IsNull(cleared.Workspaces[0].Panes[0].Surfaces[0].Color);
    }

    [TestMethod]
    public void TypedTabColorsNormalizeLikeMacOS()
    {
        Assert.AreEqual("#1565C0", MainWindow.NormalizedHex(" #1565c0 "));
        Assert.AreEqual("#ABCDEF", MainWindow.NormalizedHex("abcdef"));
        foreach (var bad in new[] { "", "#", "##123456", "#12345", "#1234567", "blue", "#12345G" })
            Assert.IsNull(MainWindow.NormalizedHex(bad), bad);
    }

    [TestMethod]
    public void RecursiveLayoutDeserializesFromCoreSnapshot()
    {
        const string json = """
        {"abi_version":1,"revision":9,"selected_workspace_id":"w","workspaces":[{"id":"w","selected_pane_id":"p2","panes":[{"id":"p1","selected_surface_id":"s1","surfaces":[{"id":"s1","session_id":"session-1","is_pinned":false}]},{"id":"p2","selected_surface_id":"s2","surfaces":[{"id":"s2","session_id":"session-2","is_pinned":true}]}],"layout":{"type":"split","id":"x","direction":"vertical","ratio":0.4,"first":{"type":"pane","pane_id":"p1"},"second":{"type":"pane","pane_id":"p2"}}}]}
        """;
        var snapshot = JsonSerializer.Deserialize<CoreSnapshot>(json);

        Assert.IsNotNull(snapshot);
        Assert.AreEqual(9UL, snapshot.Revision);
        Assert.AreEqual("s2", snapshot.Workspaces[0].SelectedPane!.SelectedSurface!.Id);
        Assert.AreEqual("p2", snapshot.Workspaces[0].Layout.Second!.PaneId);
    }

    [TestMethod]
    public void ShortcutValidationRejectsTerminalControlsAndDuplicates()
    {
        var reserved = ShortcutSettings.Defaults.ToDictionary(pair => pair.Key, pair => pair.Value);
        reserved["new_tab"] = "ctrl-c";
        Assert.ThrowsExactly<InvalidDataException>(() => ShortcutSettings.Create(reserved));

        var duplicate = ShortcutSettings.Defaults.ToDictionary(pair => pair.Key, pair => pair.Value);
        duplicate["close_tab"] = duplicate["new_tab"];
        Assert.ThrowsExactly<InvalidDataException>(() => ShortcutSettings.Create(duplicate));
    }

    [TestMethod]
    public void AnActionCanHaveNoShortcutAndFunctionKeysStandAlone()
    {
        var values = ShortcutSettings.Defaults.ToDictionary(pair => pair.Key, pair => pair.Value);
        // Unbound actions never clash with each other, and an emptied default is unbound too.
        values["find"] = " ";
        values["toggle_full_screen"] = "F12";
        values["close_window"] = "ctrl-shift-F4";
        var settings = ShortcutSettings.Create(values);
        Assert.AreEqual(("", "", "", "f12", "ctrl-shift-f4"), (settings.Values["find"], settings.Values["open_review"], settings.Values["use_selection_for_find"], settings.Values["toggle_full_screen"], settings.Values["close_window"]));
        Assert.AreEqual(("", "F11", "Ctrl+Shift+F1"), (ShortcutSettings.Display(""), ShortcutSettings.Display(ShortcutSettings.Defaults["toggle_full_screen"]), ShortcutSettings.Display(ShortcutSettings.Defaults["send_feedback"])));

        // Any other key still needs a modifier, and F13 and up are not keys here.
        foreach (var bad in new[] { "g", "f13", "f0", "ctrl-f99" })
        {
            values["find"] = bad;
            Assert.ThrowsExactly<InvalidDataException>(() => ShortcutSettings.Create(values), bad);
        }
    }
}
