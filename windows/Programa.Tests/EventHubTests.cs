using System.Collections.Concurrent;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class EventHubTests
{
    [TestMethod]
    public void OutputTailIsWhatWasAppended()
    {
        Assert.AreEqual("", EventHub.OutputTail("a\nb", "a\nb"));
        Assert.AreEqual("c\nd", EventHub.OutputTail("a\nb\n", "a\nb\nc\nd"), "grew in place");
        Assert.AreEqual("\nline 3", EventHub.OutputTail("line 1\nline 2", "line 2\nline 3"), "scrolled: found by the earlier end");
        Assert.AreEqual("fresh screen", EventHub.OutputTail("old", "fresh screen"), "no overlap sends the whole read");
    }

    [TestMethod]
    public async Task ASlowClientGetsTheNewestFramesAndADroppedCount()
    {
        var written = new ConcurrentQueue<string>();
        var subscription = new Subscription(["agent_state"], [], line => { written.Enqueue(line); return Task.CompletedTask; });
        for (var index = 0; index < 300; index++) subscription.Enqueue($$"""{"n":{{index}}}""");
        Assert.AreEqual(EventHub.MaxQueuedEvents, subscription.Queued);
        subscription.Close();
        subscription.Start();
        for (var attempt = 0; attempt < 100 && written.Count < 257; attempt++) await Task.Delay(20);
        var lines = written.ToArray();
        Assert.AreEqual("""{"event":"dropped","count":44}""", lines[0]);
        Assert.AreEqual("""{"n":44}""", lines[1], "the oldest went first");
        Assert.AreEqual("""{"n":299}""", lines[^1]);
    }

    [TestMethod]
    public async Task SubscribeValidatesAndDeliversItsClassesOnly()
    {
        var server = new ControlServer((_, _) => Task.FromResult<object?>(null));
        var written = new ConcurrentQueue<string>();
        var connection = new ControlServer.Connection(line => { written.Enqueue(line); return Task.CompletedTask; });

        StringAssert.Contains(await server.HandleLineAsync("""{"id":1,"method":"subscribe","params":{"classes":[]}}""", connection), "invalid_params");
        StringAssert.Contains(await server.HandleLineAsync("""{"id":2,"method":"subscribe","params":{"classes":["output"]}}""", connection), "surface_ids is required");
        StringAssert.Contains(await server.HandleLineAsync("""{"id":3,"method":"subscribe","params":{"classes":["telepathy"]}}""", connection), "Unknown event class");

        var answer = JsonDocument.Parse(await server.HandleLineAsync("""{"id":4,"method":"subscribe","params":{"classes":["needs_input"]}}""", connection)).RootElement;
        Assert.IsTrue(answer.GetProperty("ok").GetBoolean());
        Assert.AreEqual(256, answer.GetProperty("result").GetProperty("max_queued_events").GetInt32());
        connection.Subscription!.Start();
        EventHub.Publish("agent_state", "s", new { @event = "agent_state" });
        EventHub.Publish("needs_input", "s", new { @event = "needs_input", surface_id = "s" });
        for (var attempt = 0; attempt < 100 && written.IsEmpty; attempt++) await Task.Delay(20);
        CollectionAssert.AreEqual(new[] { """{"event":"needs_input","surface_id":"s"}""" }, written.ToArray());

        await server.HandleLineAsync("""{"id":5,"method":"unsubscribe"}""", connection);
        Assert.IsNull(connection.Subscription);
        Assert.IsFalse(EventHub.Wants("needs_input"));
    }
}
