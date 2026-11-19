using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class HelpersTests
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 19, 12, 0, 0, TimeSpan.Zero);

    [TestInitialize]
    public void Setup() => Helpers.Reset();

    private static JsonNode Call(string method, object parameters, DateTimeOffset? at = null) =>
        JsonNode.Parse(JsonSerializer.Serialize(Helpers.FromControl(method, JsonSerializer.SerializeToElement(parameters),
            id => id.StartsWith("workspace-", StringComparison.Ordinal), (workspace, surface) => surface == "surface-1", at ?? T0)))!;

    private static string Code(Action call) => Assert.ThrowsExactly<ControlException>(call).Code;

    [TestMethod]
    public void AHelperStartsRunsAndFinishesWithItsReport()
    {
        var started = Call("agent.task.start", new { agent_id = "H1", workspace_id = "workspace-a", surface_id = "surface-1", host = "claude", session = "s1", task = "Find the flaky test", role = "Explore" })["agent"]!;
        Assert.AreEqual("working", (string?)started["state"]);
        Assert.AreEqual("runs_with_parent", (string?)started["output_location"]);
        Assert.AreEqual("2026-11-19T12:00:00.000Z", (string?)started["started_at"]);
        Assert.IsNull(started["ended_at"]);
        // The same id twice is refused, as on macOS; the hook then updates it instead.
        Assert.AreEqual("invalid_params", Code(() => Call("agent.task.start", new { agent_id = "H1", workspace_id = "workspace-a", host = "claude" })));
        Assert.AreEqual("blocked", (string?)Call("agent.task.update", new { agent_id = "H1", state = "blocked" })["agent"]!["state"]);

        var finished = Call("agent.task.finish", new { agent_id = "H1", summary = "It was the clock." }, T0.AddSeconds(95))["agent"]!;
        Assert.AreEqual(("completed", "It was the clock.", "2026-11-19T12:01:35.000Z"), ((string?)finished["state"], (string?)finished["summary"], (string?)finished["ended_at"]));
        Assert.AreEqual("Find the flaky test", (string?)finished["task"], "a finish without a task keeps it");
        Assert.AreEqual("invalid_params", Code(() => Call("agent.task.update", new { agent_id = "H1", state = "working" })), "a finished helper stays finished");
        Assert.AreEqual("invalid_params", Code(() => Call("agent.task.finish", new { agent_id = "H1", state = "working" })));
        Assert.AreEqual("not_found", Code(() => Call("agent.task.finish", new { agent_id = "nope" })));
    }

    [TestMethod]
    public void IdsAndPlacesAreChecked()
    {
        Assert.AreEqual("not_found", Code(() => Call("agent.task.start", new { workspace_id = "gone", host = "claude" })));
        Assert.AreEqual("not_found", Code(() => Call("agent.task.start", new { workspace_id = "workspace-a", surface_id = "surface-9", host = "claude" })));
        Assert.AreEqual("not_found", Code(() => Call("agent.task.start", new { workspace_id = "workspace-a", host = "claude", parent_id = "nobody" })));
        Assert.AreEqual("invalid_params", Code(() => Call("agent.task.start", new { workspace_id = "workspace-a" })), "host is required");
        Assert.AreEqual("invalid_params", Code(() => Call("agent.task.start", new { workspace_id = "workspace-a", host = "claude", state = "asleep" })));
        Assert.AreEqual("invalid_params", Code(() => Call("agent.task.start", new { workspace_id = "workspace-a", host = "claude", task = new string('x', 2_049) })));
        // Without an id one is made up.
        Assert.AreEqual(36, ((string?)Call("agent.task.start", new { workspace_id = "workspace-a", host = "codex" })["agent"]!["id"])!.Length);
    }

    [TestMethod]
    public void SessionsEndTheirHelpersAndListsFilter()
    {
        Call("agent.task.start", new { agent_id = "A", workspace_id = "workspace-a", host = "claude", session = "s1" });
        Call("agent.task.start", new { agent_id = "B", workspace_id = "workspace-a", host = "claude", session = "s1", parent_id = "A" });
        Call("agent.task.start", new { agent_id = "C", workspace_id = "workspace-b", host = "claude", session = "s2" });
        Call("agent.task.start", new { agent_id = "D", workspace_id = "workspace-a", host = "claude", session = "s1", placement = "nested_workspace" });
        var ended = Call("agent.task.finish_session", new { host = "claude", session = "s1" });
        Assert.AreEqual(3, (int)ended["count"]!);
        Assert.IsTrue(ended["agents"]!.AsArray().All(agent => (string?)agent!["state"] == "cancelled"));
        Assert.AreEqual(1, (int)Call("agent.task.list", new { parent_id = "A" })["count"]!);
        Assert.AreEqual(0, (int)Call("agent.task.list", new { workspace_id = "workspace-a", include_finished = false })["count"]!);
        Assert.AreEqual(1, (int)Call("agent.task.list", new { include_finished = false })["count"]!);
        // The popover shows only the helpers that run with their parent.
        Assert.AreEqual(2, Helpers.Of("workspace-a").Count);
        Helpers.ClearFinished("workspace-a");
        Assert.AreEqual(0, Helpers.Of("workspace-a").Count);
        Helpers.Retain(["workspace-a"]);
        Assert.IsNull(Helpers.Find("C"), "a closed workspace's helpers go with it");
    }

    [TestMethod]
    public void TheOldestFinishedHelperMakesRoom()
    {
        for (var index = 0; index < Helpers.Capacity; index++)
            Call("agent.task.start", new { agent_id = $"H{index}", workspace_id = "workspace-a", host = "claude" }, T0.AddSeconds(index));
        Assert.AreEqual("invalid_params", Code(() => Call("agent.task.start", new { agent_id = "full", workspace_id = "workspace-a", host = "claude" })), "all are running");
        Call("agent.task.finish", new { agent_id = "H7" }, T0.AddMinutes(10));
        Call("agent.task.finish", new { agent_id = "H3" }, T0.AddMinutes(11));
        Call("agent.task.start", new { agent_id = "next", workspace_id = "workspace-a", host = "claude" });
        Assert.IsNull(Helpers.Find("H7"));
        Assert.IsNotNull(Helpers.Find("H3"));
    }

    [TestMethod]
    public void AReportFileIsNamedAfterItsTitle()
    {
        Assert.AreEqual("Find the flaky test.md", MainWindow.ReportFileName("Find the flaky test!", "Helper report"));
        Assert.AreEqual("one two three four five six seven eight.md", MainWindow.ReportFileName("one two three four five six seven eight nine", "x"));
        Assert.AreEqual("Helper report.md", MainWindow.ReportFileName("???", "Helper report"));
    }
}
