using System.Text.Json;
using System.Threading.Channels;

namespace Programa;

/// <summary>Socket event subscriptions, as on macOS (docs/socket-api.md, Socket Event Subscriptions):
/// a connection that sent `subscribe` gets pushed frames for the classes it asked for. Producers
/// publish from any thread; each subscription drains its own bounded queue on its own task, so a slow
/// client never holds up the app.</summary>
internal static class EventHub
{
    internal const int MaxQueuedEvents = 256;
    internal static readonly string[] Classes = ["agent_state", "output", "workspace_lifecycle", "needs_input"];
    private static readonly JsonSerializerOptions Json = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    private static readonly List<Subscription> Subscriptions = [];

    /// <summary>Raised (on any thread) when a subscription comes or goes, so the output poll runs only when watched.</summary>
    internal static event Action? SubscriptionsChanged;

    internal static void Add(Subscription subscription)
    {
        lock (Subscriptions) Subscriptions.Add(subscription);
        SubscriptionsChanged?.Invoke();
    }

    internal static void Remove(Subscription subscription)
    {
        bool removed;
        lock (Subscriptions) removed = Subscriptions.Remove(subscription);
        subscription.Close();
        if (removed) SubscriptionsChanged?.Invoke();
    }

    /// <summary>The text appended between two reads of a terminal's last lines: what follows the
    /// earlier text, found by its end when the screen scrolled. "" when nothing new.</summary>
    internal static string OutputTail(string previous, string current)
    {
        if (current == previous || current.Length == 0) return string.Empty;
        if (current.StartsWith(previous, StringComparison.Ordinal)) return current[previous.Length..];
        // Scrolled: the earlier text's end is still on screen. The longest end that is found anchors
        // best, since a short one (a prompt) can repeat.
        var lastLine = previous.Length - previous.LastIndexOf('\n') - 1;
        foreach (var length in new[] { 200, 80, 30, lastLine }.Where(length => length > 0 && length <= previous.Length).Distinct())
        {
            var probe = previous[^length..];
            var at = current.LastIndexOf(probe, StringComparison.Ordinal);
            if (at >= 0) return current[(at + probe.Length)..];
        }
        // ponytail: no overlap (a full-screen redraw or a clear) sends the whole read; a shared
        // ring of the terminal's raw output would be exact, if a consumer ever needs that.
        return current;
    }

    internal static bool Wants(string eventClass)
    {
        lock (Subscriptions) return Subscriptions.Any(subscription => subscription.Classes.Contains(eventClass));
    }

    /// <summary>Every surface some subscription watches the output of.</summary>
    internal static HashSet<string> OutputSurfaces()
    {
        lock (Subscriptions)
            return Subscriptions.Where(subscription => subscription.Classes.Contains("output")).SelectMany(subscription => subscription.SurfaceIds).ToHashSet(StringComparer.Ordinal);
    }

    /// <summary>Sends a frame (an object with an `event` key) to every subscription of its class; an
    /// output frame only to those watching its surface.</summary>
    internal static void Publish(string eventClass, string? surfaceId, object frame)
    {
        List<Subscription> targets;
        lock (Subscriptions)
            targets = Subscriptions.Where(subscription => subscription.Classes.Contains(eventClass) && (eventClass != "output" || (surfaceId is not null && subscription.SurfaceIds.Contains(surfaceId)))).ToList();
        if (targets.Count == 0) return;
        var line = JsonSerializer.Serialize(frame, Json);
        foreach (var subscription in targets) subscription.Enqueue(line);
    }

    /// <summary>Seconds since the Unix epoch, the frames' `ts`.</summary>
    internal static double Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
}

/// <summary>One connection's subscription: a drop-oldest queue of <see cref="EventHub.MaxQueuedEvents"/>
/// frames written in order; after drops, a `{"event":"dropped","count":N}` frame goes first. The first
/// failed write (the client went away) ends it.</summary>
internal sealed class Subscription
{
    private readonly Channel<string> _queue;
    private readonly Func<string, Task> _write;
    private int _dropped;

    internal Subscription(IReadOnlyCollection<string> classes, IReadOnlyCollection<string> surfaceIds, Func<string, Task> write)
    {
        Classes = classes.ToHashSet(StringComparer.Ordinal);
        SurfaceIds = surfaceIds.ToHashSet(StringComparer.Ordinal);
        _write = write;
        _queue = Channel.CreateBounded<string>(new BoundedChannelOptions(EventHub.MaxQueuedEvents) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true },
            _ => Interlocked.Increment(ref _dropped));
    }

    internal string Id { get; } = "subscription-" + Guid.NewGuid().ToString("N");
    internal HashSet<string> Classes { get; }
    internal HashSet<string> SurfaceIds { get; }

    internal void Enqueue(string line) => _queue.Writer.TryWrite(line);

    private int _started;

    /// <summary>Starts writing queued frames once the subscribe answer is on the wire; later calls do nothing.</summary>
    internal void Start()
    {
        if (Interlocked.Exchange(ref _started, 1) == 0) _ = Task.Run(PumpAsync);
    }

    internal void Close() => _queue.Writer.TryComplete();

    private async Task PumpAsync()
    {
        try
        {
            await foreach (var line in _queue.Reader.ReadAllAsync())
            {
                var dropped = Interlocked.Exchange(ref _dropped, 0);
                if (dropped > 0) await _write($$"""{"event":"dropped","count":{{dropped}}}""");
                await _write(line);
            }
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException or OperationCanceledException or InvalidOperationException)
        {
            EventHub.Remove(this);
        }
    }

    /// <summary>For tests: how many frames are waiting.</summary>
    internal int Queued => _queue.Reader.Count;
}
