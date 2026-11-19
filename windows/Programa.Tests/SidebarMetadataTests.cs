using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class SidebarMetadataTests
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 19, 12, 0, 0, TimeSpan.Zero);

    [TestInitialize]
    public void Setup() => SidebarMetadata.Clear();

    private static JsonNode Call(string method, object parameters, DateTimeOffset? at = null, string workspace = "ws-1") =>
        JsonNode.Parse(JsonSerializer.Serialize(SidebarMetadata.FromControl(method, workspace, JsonSerializer.SerializeToElement(parameters), at ?? T0)))!;

    private static string Error(string method, object parameters) =>
        Assert.ThrowsExactly<ControlException>(() => Call(method, parameters)).Message;

    private static string[] Keys(JsonNode result, string list) => result[list]!.AsArray().Select(item => (string)item!["key"]!).ToArray();

    [TestMethod]
    public void StatusEntriesSortByPriorityThenNewestAndKeepTheirPlaceWhenRepeated()
    {
        var changes = 0;
        SidebarMetadata.Changed += Count;
        try
        {
            Call("workspace.set_status", new { key = "build", value = "ok" }, T0);
            Call("workspace.set_status", new { key = "tests", value = "42 passed", color = "#00ff00", url = "https://ci.example/run/1", format = "md" }, T0.AddSeconds(1));
            Call("workspace.set_status", new { key = "deploy", value = "queued", priority = 50000 }, T0.AddSeconds(2));
            // The same entry again is not news: no change, and it stays behind the newer one.
            Call("workspace.set_status", new { key = "build", value = "ok" }, T0.AddSeconds(3));
            Assert.AreEqual(3, changes);
            var listed = Call("workspace.list_status", new { });
            CollectionAssert.AreEqual(new[] { "deploy", "tests", "build" }, Keys(listed, "entries"));
            var tests = listed["entries"]![1]!;
            Assert.AreEqual(("markdown", "https://ci.example/run/1", "#00ff00"), ((string?)tests["format"], (string?)tests["url"], (string?)tests["color"]));
            Assert.AreEqual(9999, (int)listed["entries"]![0]!["priority"]!);

            Call("workspace.clear_status", new { key = "deploy" });
            CollectionAssert.AreEqual(new[] { "tests", "build" }, Keys(Call("workspace.list_status", new { }), "entries"));
        }
        finally
        {
            SidebarMetadata.Changed -= Count;
        }
        void Count(string workspaceId) => changes++;
    }

    [TestMethod]
    public void BadStatusParametersAreRefusedWithTheMacOSMessages()
    {
        Assert.AreEqual("Missing key", Error("workspace.set_status", new { value = "x" }));
        Assert.AreEqual("Missing value", Error("workspace.set_status", new { key = "k" }));
        Assert.AreEqual("Invalid format — use: plain, markdown", Error("workspace.set_status", new { key = "k", value = "v", format = "html" }));
        Assert.AreEqual("Invalid url — expected http(s) URL", Error("workspace.set_status", new { key = "k", value = "v", url = "file:///c:/x" }));
        Assert.AreEqual("Invalid priority — must be an integer", Error("workspace.set_status", new { key = "k", value = "v", priority = "high" }));
        Assert.AreEqual("key exceeds the UTF-8 limit of 512 bytes", Error("workspace.set_status", new { key = new string('é', 257), value = "v" }));
        // An empty value is allowed: the row then shows the key.
        Assert.AreEqual("", (string?)Call("workspace.set_status", new { key = "k", value = "" })["value"]);
    }

    [TestMethod]
    public void TheOldestStatusEntryMakesRoomPastTheLimit()
    {
        for (var index = 0; index < SidebarMetadata.MaxStatusEntries + 1; index++)
            Call("workspace.set_status", new { key = $"k{index}", value = "v" }, T0.AddSeconds(index));
        var keys = Keys(Call("workspace.list_status", new { }), "entries");
        Assert.AreEqual(SidebarMetadata.MaxStatusEntries, keys.Length);
        CollectionAssert.DoesNotContain(keys, "k0");
        CollectionAssert.Contains(keys, $"k{SidebarMetadata.MaxStatusEntries}");
    }

    [TestMethod]
    public void TheLogKeepsTheLatestFiftyAndListsTheLastN()
    {
        for (var index = 1; index <= 55; index++) Call("workspace.log", new { message = $"line {index}" }, T0.AddSeconds(index));
        var reply = Call("workspace.log", new { message = "failed", level = "error", source = "ci" }, T0.AddMinutes(5));
        Assert.AreEqual(("error", "ci"), ((string?)reply["level"], (string?)reply["source"]));
        var all = Call("workspace.list_log", new { })["entries"]!.AsArray();
        Assert.AreEqual(SidebarMetadata.MaxLogEntries, all.Count);
        Assert.AreEqual("line 7", (string?)all[0]!["message"]);
        var last = Call("workspace.list_log", new { limit = 2 })["entries"]!.AsArray();
        CollectionAssert.AreEqual(new[] { "line 55", "failed" }, last.Select(entry => (string)entry!["message"]!).ToArray());
        Assert.AreEqual(T0.AddMinutes(5).ToUnixTimeSeconds(), (double)last[1]!["timestamp"]!);

        Assert.AreEqual("Missing message", Error("workspace.log", new { message = "" }));
        Assert.AreEqual("Unknown log level — use: info, progress, success, warning, error", Error("workspace.log", new { message = "x", level = "debug" }));
        Assert.AreEqual("Invalid limit — must be >= 0", Error("workspace.list_log", new { limit = -1 }));
        Call("workspace.clear_log", new { });
        Assert.AreEqual(0, Call("workspace.list_log", new { })["entries"]!.AsArray().Count);
    }

    [TestMethod]
    public void ProgressClampsAndMetaBlocksTurnLiteralEscapesIntoLines()
    {
        Assert.AreEqual(1.0, (double)Call("workspace.set_progress", new { value = 1.7, label = "Done" })["value"]!);
        Assert.AreEqual(new SidebarProgress(1, "Done"), SidebarMetadata.Of("ws-1")!.Progress);
        Assert.AreEqual("Invalid progress value — must be 0.0 to 1.0", Error("workspace.set_progress", new { value = "half" }));
        Call("workspace.clear_progress", new { });
        Assert.IsNull(SidebarMetadata.Of("ws-1")!.Progress);

        var block = Call("workspace.report_meta_block", new { key = "notes", markdown = "# Plan\\n- one\\r\\n- two", priority = -3 });
        Assert.AreEqual("# Plan\n- one\n- two", (string?)block["markdown"]);
        Call("workspace.report_meta_block", new { key = "summary", markdown = "**done**" }, T0.AddSeconds(1));
        CollectionAssert.AreEqual(new[] { "summary", "notes" }, Keys(Call("workspace.list_meta_blocks", new { }), "blocks"));
        Assert.AreEqual("Missing markdown", Error("workspace.report_meta_block", new { key = "x", markdown = "\\n " }));
        Assert.IsTrue((bool)Call("workspace.clear_meta_block", new { key = "notes" })["found"]!);
        Assert.IsFalse((bool)Call("workspace.clear_meta_block", new { key = "notes" })["found"]!);
    }

    [TestMethod]
    public void ASessionKeepsTheLogAndProgressButNotStatusEntries()
    {
        Call("workspace.set_status", new { key = "claude_code", value = "Running" });
        Call("workspace.log", new { message = "built", level = "success" });
        Call("workspace.set_progress", new { value = 0.25, label = "Tests" });
        var saved = SidebarMetadata.Saved("ws-1")!;
        // Through the session file's own serializer settings.
        var session = new SavedSession(SessionStore.CurrentVersion, JsonSerializer.SerializeToElement(new { }), true, 240, null, [], Sidebar: new() { ["ws-1"] = saved });
        var path = Path.Combine(Path.GetTempPath(), $"programa-sidebar-{Guid.NewGuid():N}.json");
        try
        {
            SessionStore.Save(session, path);
            var loaded = SessionStore.Load(path)!.Sidebar!["ws-1"];
            SidebarMetadata.Clear();
            SidebarMetadata.Restore("ws-2", loaded);
        }
        finally
        {
            File.Delete(path);
        }
        var restored = SidebarMetadata.Of("ws-2")!;
        Assert.AreEqual(0, restored.Status.Count);
        Assert.AreEqual(("built", "success", T0), (restored.Log.Single().Message, restored.Log.Single().Level, restored.Log.Single().At));
        Assert.AreEqual(new SidebarProgress(0.25, "Tests"), restored.Progress);
        Assert.IsNull(SidebarMetadata.Saved("ws-3"));

        SidebarMetadata.Retain(["ws-9"]);
        Assert.IsNull(SidebarMetadata.Of("ws-2"));
    }
}
