using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class RoutesTests
{
    private static (List<RouteDefinition> Routes, List<RouteIssue> Issues) Parse(string json) =>
        Routes.Parse(JsonNode.Parse(json, null, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true }));

    [TestMethod]
    public void TheDocumentedExampleLoads()
    {
        var (routes, issues) = Parse("""
            [
              { "name": "blocked-question", "on": "agent/+/needs_input/question", "throttleMs": "5m",
                "notify": { "title": "Agent needs you", "body": "{{body}}" } },
              { "name": "tests-on-idle", "on": "agent/+/state/idle",
                "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": "true" },
                "debounceMs": 2000, "run": { "command": "npm test" } },
              { "name": "review-on-idle", "on": "agent/+/state/idle",
                "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": "true" },
                "debounceMs": 2000, "review": {} },
            ]
            """);
        Assert.AreEqual(0, issues.Count, string.Join("; ", issues.Select(issue => issue.Message)));
        Assert.AreEqual(300_000, routes[0].ThrottleMs);
        Assert.AreEqual(600_000, ((RunAction)routes[1].Action).TimeoutMs);
        Assert.AreEqual("uncommitted", ((ReviewAction)routes[2].Action).Mode);
    }

    [TestMethod]
    public void ABadRouteIsAnIssueAndTheOthersStillLoad()
    {
        var (routes, issues) = Parse("""
            [
              { "on": "agent/#", "notify": { "title": "x" } },
              { "name": "ok", "on": "agent/#", "notify": { "title": "x" } },
              { "name": "ok", "on": "agent/#", "notify": { "title": "x" } },
              { "name": "hash", "on": "agent/#/x", "notify": { "title": "x" } },
              { "name": "mixed", "on": "agent/a+/state", "notify": { "title": "x" } },
              { "name": "output", "on": "surface/+/output", "notify": { "title": "x" } },
              { "name": "free", "on": "agent/+/state/idle", "throttleMs": 60000, "send": { "text": "{{body}}" } },
              { "name": "fast", "on": "agent/+/state/idle", "prompt": { "text": "go" } },
              { "name": "stopped", "on": "agent/+/needs_input/+", "throttleMs": "1m", "prompt": { "text": "go" } },
              { "name": "templated", "on": "agent/+/state/idle", "run": { "command": "cd {{cwd}}" } },
              { "name": "operator", "on": "agent/#", "when": { "state": { "like": "x" } }, "notify": { "title": "x" } },
              { "name": "slow", "on": "agent/#", "when": { "body": { "regex": "(a+)+" } }, "notify": { "title": "x" } },
              { "name": "two", "on": "agent/#", "notify": { "title": "x" }, "review": {} },
              { "name": "unknown", "on": "agent/#", "notify": { "title": "{{nope}}" } },
            ]
            """);
        CollectionAssert.AreEqual(new[] { "ok" }, routes.Select(route => route.Name).ToArray());
        string Issue(string? name) => issues.Single(issue => issue.Name == name).Message;
        StringAssert.Contains(issues.Single(issue => issue.Index == 0).Message, "'name' is required");
        StringAssert.Contains(issues.Single(issue => issue.Index == 2).Message, "used by an earlier route");
        StringAssert.Contains(Issue("hash"), "'#' only as the last level");
        StringAssert.Contains(Issue("mixed"), "cannot mix a wildcard");
        StringAssert.Contains(Issue("output"), "Terminal output is not a route event");
        StringAssert.Contains(Issue("free"), "free text");
        StringAssert.Contains(Issue("fast"), "at least 60000");
        StringAssert.Contains(Issue("stopped"), "needs_input topics only");
        StringAssert.Contains(Issue("templated"), "PROGRAMA_ROUTE_CWD");
        StringAssert.Contains(Issue("operator"), "unknown operator");
        StringAssert.Contains(Issue("slow"), "exponential");
        StringAssert.Contains(Issue("two"), "exactly one action");
        StringAssert.Contains(Issue("unknown"), "not an event field");
        Assert.AreEqual("'routes' must be an array.", Parse("""{"a":1}""").Issues.Single().Message);
    }

    [TestMethod]
    public void TopicsMatchLikeMqtt()
    {
        string[] P(string on) => Routes.ParseTopic(on);
        Assert.IsTrue(Routes.TopicMatches(P("agent/#"), "agent"), "# matches nothing too");
        Assert.IsTrue(Routes.TopicMatches(P("agent/#"), "agent/s1/state/idle"));
        Assert.IsTrue(Routes.TopicMatches(P("agent/+/state/idle"), "agent/s1/state/idle"));
        Assert.IsFalse(Routes.TopicMatches(P("agent/+/state/idle"), "agent/s1/state/working"));
        Assert.IsFalse(Routes.TopicMatches(P("agent/+"), "agent/s1/state/idle"), "+ is exactly one level");
        Assert.IsTrue(Routes.TopicMatches(P("+/+/created"), "workspace/w1/created"));
    }

    [TestMethod]
    public void WhenConditionsAllHold()
    {
        var route = Parse("""
            [{ "name": "r", "on": "agent/#", "notify": { "title": "{{state}}" },
               "when": { "worktree": true, "previous_state": { "in": ["working", "blocked"] }, "source": { "ne": "inferred" },
                         "git_branch": { "exists": false }, "cwd": { "regex": "^c:\\\\work(\\\\|$)", "flags": "i" } } }]
            """).Routes.Single();
        var fields = new Dictionary<string, string> { ["worktree"] = "true", ["previous_state"] = "working", ["source"] = "hooks", ["cwd"] = @"C:\Work\app" };
        Assert.IsTrue(Routes.Holds(route, fields, Stopwatch.StartNew(), out _));
        Assert.IsFalse(Routes.Holds(route, new Dictionary<string, string>(fields) { ["source"] = "inferred" }, Stopwatch.StartNew(), out _));
        Assert.IsFalse(Routes.Holds(route, new Dictionary<string, string>(fields) { ["git_branch"] = "main" }, Stopwatch.StartNew(), out _));
        Assert.IsFalse(Routes.Holds(route, new Dictionary<string, string>(fields) { ["cwd"] = @"C:\work-old" }, Stopwatch.StartNew(), out _));
        // A spent regex budget counts as unmet and says so.
        var spent = Stopwatch.StartNew();
        Thread.Sleep(60);
        Assert.IsFalse(Routes.Holds(route, fields, spent, out var error));
        StringAssert.Contains(error, "when.cwd: the regex ran longer than 50 ms");
    }

    [TestMethod]
    public void DurationsTemplatesAndEnvironmentNames()
    {
        Assert.AreEqual(250, Routes.Duration(JsonValue.Create("250ms"), "d"));
        Assert.AreEqual(90_000, Routes.Duration(JsonValue.Create("1.5m"), "d"));
        Assert.AreEqual(3_600_000, Routes.Duration(JsonValue.Create("1h"), "d"));
        Assert.AreEqual(4000, Routes.Duration(JsonValue.Create(4000), "d"));
        Assert.ThrowsExactly<FormatException>(() => Routes.Duration(JsonValue.Create(-1), "d"));
        var fields = new Dictionary<string, string> { ["topic"] = "agent/s/state/idle" };
        Assert.AreEqual("agent/s/state/idle:", Routes.Render("{{topic}}:{{surface_id}}", fields));
        Assert.AreEqual("agent/s/state/idle:{{surface_id}}", Routes.Render("{{topic}}:{{surface_id}}", fields, keepMissing: true));
        Assert.AreEqual("PROGRAMA_ROUTE_PROGRAM_STATUS_STATE", Routes.EnvironmentName("program_status.state"));
    }
}
