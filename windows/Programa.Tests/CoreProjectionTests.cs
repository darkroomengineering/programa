using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class CoreProjectionTests
{
    [TestMethod]
    public void NativeCoreDispatchPreservesTerminalSessionAcrossReorder()
    {
        using var core = new CoreClient();
        var created = core.Dispatch(new { command = "create_workspace", workspace_id = "w", pane_id = "p", surface_id = "s1", session_id = "session-1" });
        var second = core.Dispatch(new { command = "create_surface", workspace_id = "w", pane_id = "p", surface_id = "s2", session_id = "session-2" });
        var reordered = core.Dispatch(new { command = "reorder_surface", workspace_id = "w", pane_id = "p", surface_id = "s2", before_surface_id = "s1" });

        Assert.AreEqual(1UL, created.Revision);
        Assert.AreEqual(2UL, second.Revision);
        Assert.AreEqual(3UL, reordered.Revision);
        CollectionAssert.AreEqual(new[] { "s2", "s1" }, reordered.Workspaces[0].Panes[0].Surfaces.Select(surface => surface.Id).ToArray());
        Assert.AreEqual("session-2", reordered.Workspaces[0].Panes[0].Surfaces[0].SessionId);
    }

    [TestMethod]
    public void RecursiveLayoutAndSessionIdentityDeserializeFromCoreSnapshot()
    {
        const string json = """
        {"abi_version":1,"revision":9,"selected_workspace_id":"w","workspaces":[{"id":"w","selected_pane_id":"p2","panes":[{"id":"p1","selected_surface_id":"s1","surfaces":[{"id":"s1","session_id":"session-1","is_pinned":false}]},{"id":"p2","selected_surface_id":"s2","surfaces":[{"id":"s2","session_id":"session-2","is_pinned":true}]}],"layout":{"type":"split","id":"x","direction":"vertical","ratio":0.4,"first":{"type":"pane","pane_id":"p1"},"second":{"type":"pane","pane_id":"p2"}}}]}
        """;
        var snapshot = JsonSerializer.Deserialize<CoreSnapshot>(json);

        Assert.IsNotNull(snapshot);
        Assert.AreEqual(9UL, snapshot.Revision);
        Assert.AreEqual("session-2", snapshot.Workspaces[0].SelectedPane!.SelectedSurface!.SessionId);
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
}
