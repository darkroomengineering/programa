using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Programa;

/// <summary>One rate-limit window. Kind is "session" (Claude's 5 hour window), "window" (a Codex window
/// shorter than a week), "weekly", or "duration" (named by <see cref="Minutes"/>).</summary>
internal sealed record UsageWindow(string Id, string Kind, int Minutes, int UsedPercent, DateTimeOffset ResetsAt);

/// <summary>Codex's plan and credits; Unlimited and Balance are set only when the account has credits.</summary>
internal sealed record UsageSummary(string? Plan, bool Unlimited, string? Balance, int? ResetCredits);

/// <summary>State is "available", "unavailable" (left out of the popover) or "failed" with Error:
/// claudeInvalid, claudeRead, codexInvalid or codexRead.</summary>
internal sealed record UsageResult(string Provider, string State, IReadOnlyList<UsageWindow> Windows, UsageSummary? Summary = null, string? Error = null)
{
    internal static UsageResult Unavailable(string provider) => new(provider, "unavailable", []);

    internal static UsageResult Failed(string provider, string error) => new(provider, "failed", [], null, error);
}

/// <summary>Provider usage as on macOS (Sources/ClaudeQuotaMonitor.swift): Claude from the statusline's
/// ~/.claude/tmp/rate-limits.json when `claude auth status` says signed in, OpenAI from `codex app-server`'s
/// account and rate-limit RPCs. Read on demand, each with a 5 second limit.</summary>
internal static class ProviderUsage
{
    private static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>NSDate.distantFuture, the latest reset time a countdown is shown for.</summary>
    private const double LatestSeconds = 64_092_211_200;

    internal static async Task<List<UsageResult>> FetchAllAsync(CancellationToken token)
    {
        var timeout = TimeSpan.FromSeconds(5);
        var claude = Task.Run(() => FetchClaudeAsync(Find("claude"), Path.Combine(Home, ".claude", "tmp", "rate-limits.json"), timeout, DateTimeOffset.UtcNow, token), token);
        var codex = Task.Run(() => Find("codex") is { } codexPath ? FetchCodexAsync(codexPath, ["app-server"], timeout, token) : Task.FromResult(UsageResult.Unavailable("codex")), token);
        return [.. await Task.WhenAll(claude, codex)];
    }

    /// <summary>PATH first, then where the Claude and npm installers put tools.</summary>
    private static string? Find(string name) =>
        Storage.FindTool(name) ?? new[]
        {
            Path.Combine(Home, ".local", "bin", name + ".exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", name + ".cmd"),
            Path.Combine(Home, ".bun", "bin", name + ".exe"),
        }.FirstOrDefault(File.Exists);

    // Claude

    internal static async Task<UsageResult> FetchClaudeAsync(string? executable, string cachePath, TimeSpan timeout, DateTimeOffset now, CancellationToken token)
    {
        // Only some setups write the cache; without it there is nothing to show, and nothing is run.
        if (executable is null || !File.Exists(cachePath)) return UsageResult.Unavailable("claude");
        switch (await SignedInAsync(executable, timeout, token))
        {
            case null: return UsageResult.Failed("claude", "claudeRead");
            case false: return UsageResult.Unavailable("claude");
        }
        if (ReadCache(cachePath) is not { } text || ParseClaude(text) is not { } parsed
            || parsed.UpdatedAt > now.AddSeconds(60) || now - parsed.UpdatedAt > TimeSpan.FromHours(1))
            return UsageResult.Unavailable("claude");
        return parsed.Result;
    }

    /// <summary>`claude auth status --json`'s loggedIn, or null when it cannot be read. Signed out exits
    /// non-zero while still printing the answer, which wins over the exit code.</summary>
    private static async Task<bool?> SignedInAsync(string executable, TimeSpan timeout, CancellationToken token)
    {
        using var process = Start(executable, ["auth", "status", "--json"], input: false);
        if (process is null) return null;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(timeout);
        try
        {
            var output = await process.StandardOutput.ReadToEndAsync(deadline.Token);
            await process.WaitForExitAsync(deadline.Token);
            if (output.Length > 65_536) return null;
            using var document = JsonDocument.Parse(output);
            return document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty("loggedIn", out var loggedIn)
                && loggedIn.ValueKind is JsonValueKind.True or JsonValueKind.False ? loggedIn.GetBoolean() : null;
        }
        catch (Exception error) when (error is OperationCanceledException or JsonException or IOException or InvalidOperationException) { return null; }
        finally { Kill(process); }
    }

    /// <summary>The cache when it is a plain file (not a link) of at most 1 MB.</summary>
    private static string? ReadCache(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint) || info.Length > 1_048_576) return null;
            return File.ReadAllText(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>{"five_hour":{"used_percentage":17,"resets_at":"1785171600"},"seven_day":{…},"updated_at":1785168986314}:
    /// resets_at is a string of epoch seconds, updated_at a number of epoch milliseconds. Either window may be
    /// missing, not both; anything malformed is null, never a partial result.</summary>
    internal static (UsageResult Result, DateTimeOffset UpdatedAt)? ParseClaude(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var windows = new List<UsageWindow>();
            foreach (var (key, id, kind) in new[] { ("five_hour", "claude.five_hour", "session"), ("seven_day", "claude.seven_day", "weekly") })
            {
                if (!root.TryGetProperty(key, out var window) || window.ValueKind == JsonValueKind.Null) continue;
                if (window.ValueKind != JsonValueKind.Object
                    || !window.TryGetProperty("used_percentage", out var used) || used.ValueKind != JsonValueKind.Number || !used.TryGetInt64(out var percent)
                    || !window.TryGetProperty("resets_at", out var resets) || resets.ValueKind != JsonValueKind.String
                    || !double.TryParse(resets.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds)
                    || !double.IsFinite(seconds) || seconds < 0 || seconds > LatestSeconds)
                    return null;
                windows.Add(new UsageWindow(id, kind, 0, (int)Math.Clamp(percent, 0, 100), DateTimeOffset.UnixEpoch.AddSeconds(seconds)));
            }
            if (windows.Count == 0 || !root.TryGetProperty("updated_at", out var updated) || updated.ValueKind != JsonValueKind.Number || !updated.TryGetInt64(out var millis))
                return null;
            return (new UsageResult("claude", "available", windows), DateTimeOffset.UnixEpoch.AddMilliseconds(millis));
        }
        catch (Exception error) when (error is JsonException or ArgumentOutOfRangeException) { return null; }
    }

    // Codex

    /// <summary>Starts the app server, waits for its initialize answer, then asks for the account and the
    /// rate limits, all within <paramref name="timeout"/>. Only the account's signed-in state is kept.</summary>
    internal static async Task<UsageResult> FetchCodexAsync(string executable, string[] arguments, TimeSpan timeout, CancellationToken token)
    {
        using var process = Start(executable, arguments, input: true);
        if (process is null) return UsageResult.Failed("codex", "codexRead");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(timeout);
        string? account = null, rateLimits = null;
        try
        {
            var version = BuildIdentity.Version;
            await Send(process, new { jsonrpc = "2.0", id = 0, method = "initialize", @params = new { clientInfo = new { name = "programa", title = "Programa", version }, capabilities = new { } } });
            var initialized = false;
            var received = 0;
            while (account is null || rateLimits is null)
            {
                var line = await process.StandardOutput.ReadLineAsync(deadline.Token);
                if (line is null) break;
                received += line.Length + 1;
                if (received > 1_048_576) return UsageResult.Failed("codex", "codexRead");
                switch (ResponseId(line, out var isError, out var hasResult))
                {
                    case 0 when !initialized:
                        if (isError || !hasResult) return UsageResult.Failed("codex", "codexRead");
                        initialized = true;
                        await Send(process, new { jsonrpc = "2.0", method = "initialized", @params = new { } });
                        await Send(process, new { jsonrpc = "2.0", id = 1, method = "account/read", @params = new { refreshToken = false } });
                        await Send(process, new { jsonrpc = "2.0", id = 2, method = "account/rateLimits/read", @params = new { } });
                        break;
                    case 1 when initialized: account = AccountMarker(line); break;
                    case 2 when initialized: rateLimits = line; break;
                }
            }
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or InvalidOperationException) { }
        finally { Kill(process); }
        return account is null || rateLimits is null ? UsageResult.Failed("codex", "codexRead") : ParseCodex(account, rateLimits);
    }

    private static async Task Send(Process process, object message)
    {
        await process.StandardInput.WriteAsync(JsonSerializer.Serialize(message) + "\n");
        await process.StandardInput.FlushAsync();
    }

    private static int? ResponseId(string line, out bool isError, out bool hasResult)
    {
        isError = hasResult = false;
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("id", out var id)) return null;
            isError = root.TryGetProperty("error", out _);
            hasResult = root.TryGetProperty("result", out var result) && result.ValueKind == JsonValueKind.Object;
            return id.ValueKind switch
            {
                JsonValueKind.Number when id.TryGetInt32(out var number) => number,
                JsonValueKind.String when int.TryParse(id.GetString(), out var number) => number,
                _ => null,
            };
        }
        catch (JsonException) { return null; }
    }

    /// <summary>The account answer reduced to whether it is signed in, so its email never goes further.</summary>
    private static string AccountMarker(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.TryGetProperty("error", out _)) return """{"error":{}}""";
            if (!root.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("account", out var account)) return "{}";
            return account.ValueKind switch
            {
                JsonValueKind.Null => """{"result":{"account":null}}""",
                JsonValueKind.Object => """{"result":{"account":{}}}""",
                _ => """{"result":{"account":"invalid"}}""",
            };
        }
        catch (JsonException) { return "{}"; }
    }

    /// <summary>The account must be signed in; the windows are the unified rateLimits (or rateLimitsByLimitId.codex
    /// when it is null or missing), never model-specific buckets.</summary>
    internal static UsageResult ParseCodex(string accountLine, string rateLimitsLine)
    {
        var invalid = UsageResult.Failed("codex", "codexInvalid");
        try
        {
            using var accountDocument = JsonDocument.Parse(accountLine);
            var accountEnvelope = accountDocument.RootElement;
            if (accountEnvelope.ValueKind != JsonValueKind.Object || accountEnvelope.TryGetProperty("error", out _)
                || !accountEnvelope.TryGetProperty("result", out var accountResult) || accountResult.ValueKind != JsonValueKind.Object
                || !accountResult.TryGetProperty("account", out var account))
                return invalid;
            if (account.ValueKind == JsonValueKind.Null) return UsageResult.Unavailable("codex");
            if (account.ValueKind != JsonValueKind.Object) return invalid;

            using var rateDocument = JsonDocument.Parse(rateLimitsLine);
            var rateEnvelope = rateDocument.RootElement;
            if (rateEnvelope.ValueKind != JsonValueKind.Object || rateEnvelope.TryGetProperty("error", out _)
                || !rateEnvelope.TryGetProperty("result", out var rate) || rate.ValueKind != JsonValueKind.Object
                || !(rate.TryGetProperty("rateLimits", out _) || rate.TryGetProperty("rateLimitsByLimitId", out _)))
                return invalid;

            JsonElement aggregate;
            if (rate.TryGetProperty("rateLimits", out var unified) && unified.ValueKind != JsonValueKind.Null)
            {
                if (unified.ValueKind != JsonValueKind.Object) return invalid;
                aggregate = unified;
            }
            else
            {
                if (!rate.TryGetProperty("rateLimitsByLimitId", out var byLimit) || byLimit.ValueKind == JsonValueKind.Null) return UsageResult.Unavailable("codex");
                if (byLimit.ValueKind != JsonValueKind.Object) return invalid;
                if (!byLimit.TryGetProperty("codex", out var codex)) return UsageResult.Unavailable("codex");
                if (codex.ValueKind != JsonValueKind.Object) return invalid;
                aggregate = codex;
            }

            var windows = new List<UsageWindow>();
            foreach (var name in new[] { "primary", "secondary" })
            {
                if (!aggregate.TryGetProperty(name, out var raw) || raw.ValueKind == JsonValueKind.Null) continue;
                if (raw.ValueKind != JsonValueKind.Object || CodexWindow(raw, "codex." + name) is not { } window) return invalid;
                windows.Add(window);
            }
            if (windows.Count == 0) return UsageResult.Unavailable("codex");
            return new UsageResult("codex", "available", windows, Summary(aggregate, rate));
        }
        catch (JsonException) { return invalid; }
    }

    private static UsageWindow? CodexWindow(JsonElement raw, string id)
    {
        if (Number(raw, "usedPercent") is not { } used || Number(raw, "windowDurationMins") is not { } duration || Number(raw, "resetsAt") is not { } resets) return null;
        if (duration <= 0 || duration >= long.MaxValue || resets < 0 || resets > LatestSeconds) return null;
        var minutes = (int)Math.Min(int.MaxValue, Math.Round(duration, MidpointRounding.AwayFromZero));
        if (minutes <= 0) return null;
        var kind = minutes < 10_080 ? "window" : minutes == 10_080 ? "weekly" : "duration";
        return new UsageWindow(id, kind, minutes, (int)Math.Round(Math.Clamp(used, 0, 100), MidpointRounding.AwayFromZero), DateTimeOffset.UnixEpoch.AddSeconds(resets));
    }

    private static UsageSummary? Summary(JsonElement aggregate, JsonElement rate)
    {
        var plan = NonEmpty(aggregate, "planType");
        var unlimited = false;
        string? balance = null;
        if (aggregate.TryGetProperty("credits", out var credits) && credits.ValueKind == JsonValueKind.Object)
        {
            var has = credits.TryGetProperty("hasCredits", out var hasCredits) && hasCredits.ValueKind == JsonValueKind.True;
            unlimited = credits.TryGetProperty("unlimited", out var isUnlimited) && isUnlimited.ValueKind == JsonValueKind.True;
            if (has || unlimited) balance = NonEmpty(credits, "balance");
        }
        int? resetCredits = rate.TryGetProperty("rateLimitResetCredits", out var reset) && reset.ValueKind == JsonValueKind.Object
            && Number(reset, "availableCount") is { } count && count > 0 && count < int.MaxValue
            ? (int)Math.Round(count, MidpointRounding.AwayFromZero) : null;
        return plan is null && !unlimited && balance is null && resetCredits is null ? null : new UsageSummary(plan, unlimited, balance, resetCredits);
    }

    private static double? Number(JsonElement item, string key) =>
        item.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number) ? number : null;

    private static string? NonEmpty(JsonElement item, string key) =>
        item.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && value.GetString()!.Trim() is { Length: > 0 } text ? text : null;

    // Processes

    private static Process? Start(string executable, IEnumerable<string> arguments, bool input)
    {
        var script = executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || executable.EndsWith(".bat", StringComparison.OrdinalIgnoreCase);
        var start = new ProcessStartInfo(script ? Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe" : executable)
        {
            WorkingDirectory = Home, CreateNoWindow = true, UseShellExecute = false,
            RedirectStandardOutput = true, RedirectStandardInput = input, StandardOutputEncoding = Encoding.UTF8,
        };
        if (script) foreach (var argument in new[] { "/d", "/c", executable }) start.ArgumentList.Add(argument);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        try { return Process.Start(start); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { return null; }
    }

    private static void Kill(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }
}
