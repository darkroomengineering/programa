using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class NotificationCenterTests
{
    private static NotificationCenter Center(out AppNotification a1, out AppNotification a2, out AppNotification b1)
    {
        var center = new NotificationCenter();
        a1 = center.Post("ws-a", "s1", "first", "", toast: false);
        b1 = center.Post("ws-b", "s3", "other", "", toast: false);
        a2 = center.Post("ws-a", "s2", "second", "", toast: false);
        return center;
    }

    [TestMethod]
    public void OneMarkedUnreadMovesToTheTopAndBecomesTheLatestUnread()
    {
        var center = Center(out var a1, out var a2, out _);
        center.MarkAllRead();
        Assert.IsFalse(center.HasUnread);

        center.SetRead(a1.Id, read: false);
        Assert.AreEqual(a1.Id, center.Items[0].Id);
        Assert.AreEqual(a1.Id, center.LatestUnread?.Id);

        // Marking it read again keeps its place.
        center.SetRead(a1.Id, read: true);
        Assert.AreEqual(a1.Id, center.Items[0].Id);
        Assert.IsFalse(center.HasUnread);
        Assert.AreEqual(a2.Id, center.Items[1].Id);
    }

    [TestMethod]
    public void WorkspaceMarkUnreadTouchesOnlyThatWorkspacesReadOnes()
    {
        var center = Center(out var a1, out var a2, out var b1);
        center.MarkAllRead();
        Assert.IsTrue(center.HasReadIn("ws-a"));

        center.MarkUnread("ws-a");
        Assert.AreEqual(2, center.UnreadCount("ws-a"));
        Assert.AreEqual(0, center.UnreadCount("ws-b"));
        Assert.IsFalse(center.HasReadIn("ws-a"));
        // Both move above ws-b's, keeping their order.
        CollectionAssert.AreEqual(new[] { a2.Id, a1.Id, b1.Id }, center.Items.Select(item => item.Id).ToArray());
    }

    [TestMethod]
    public void ClearLatestAndRemoveTakeOneEntry()
    {
        var center = Center(out var a1, out var a2, out var b1);
        var changes = 0;
        center.Changed += () => changes++;

        center.ClearLatest("ws-a");
        CollectionAssert.AreEqual(new[] { b1.Id, a1.Id }, center.Items.Select(item => item.Id).ToArray());
        center.Remove(b1.Id);
        CollectionAssert.AreEqual(new[] { a1.Id }, center.Items.Select(item => item.Id).ToArray());
        Assert.AreEqual(2, changes);

        // Nothing left to change: no event.
        center.Remove(a2.Id);
        center.ClearLatest("ws-b");
        center.SetRead(a1.Id, read: false);
        Assert.AreEqual(2, changes);
        Assert.IsFalse(center.HasAnyIn("ws-b"));
    }

    [TestMethod]
    public void GhosttySettingsOpensTheConfigTheTerminalReads()
    {
        var root = Directory.CreateTempSubdirectory("programa-ghostty-").FullName;
        try
        {
            Assert.AreEqual(Path.Combine(root, "config.ghostty"), TerminalAppearance.ConfigFileToEdit(root));
            File.WriteAllText(Path.Combine(root, "config"), "font-size = 14\n");
            Assert.AreEqual(Path.Combine(root, "config"), TerminalAppearance.ConfigFileToEdit(root));
            File.WriteAllText(Path.Combine(root, "config.ghostty"), "");
            Assert.AreEqual(Path.Combine(root, "config.ghostty"), TerminalAppearance.ConfigFileToEdit(root));
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
