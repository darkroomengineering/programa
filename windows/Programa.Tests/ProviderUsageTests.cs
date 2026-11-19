using System.Diagnostics;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class ProviderUsageTests
{
    private static string Claude(string fiveHour = "17", string fiveReset = "\"1785171600\"", string sevenDay = "3", string updated = "1785168986314") =>
        $$"""{"five_hour":{"used_percentage":{{fiveHour}},"resets_at":{{fiveReset}}},"seven_day":{"used_percentage":{{sevenDay}},"resets_at":"1785664800"},"updated_at":{{updated}}}""";

    [TestMethod]
    public void TheClaudeCacheParsesWithItsMixedUnits()
    {
        var (result, updated) = ProviderUsage.ParseClaude(Claude())!.Value;
        CollectionAssert.AreEqual(new[] { "session", "weekly" }, result.Windows.Select(window => window.Kind).ToArray());
        Assert.AreEqual(17, result.Windows[0].UsedPercent);
        // resets_at is epoch seconds in a string, updated_at epoch milliseconds in a number.
        Assert.AreEqual(1_785_171_600, result.Windows[0].ResetsAt.ToUnixTimeSeconds());
        Assert.AreEqual(1_785_168_986, updated.ToUnixTimeSeconds());
        Assert.AreEqual(100, ProviderUsage.ParseClaude(Claude(fiveHour: "140"))!.Value.Result.Windows[0].UsedPercent);
        Assert.AreEqual("claude.seven_day", ProviderUsage.ParseClaude("""{"seven_day":{"used_percentage":3,"resets_at":"1785664800"},"updated_at":1}""")!.Value.Result.Windows.Single().Id);

        foreach (var broken in new[] { "{not json", "", """{"updated_at":1}""", Claude(fiveHour: "\"17\""), Claude(fiveReset: "\"soon\""), Claude(fiveReset: "1785171600"), Claude(fiveReset: "\"1e300\""), Claude(updated: "\"x\"") })
            Assert.IsNull(ProviderUsage.ParseClaude(broken), broken);
    }

    private string _root = string.Empty;

    [TestInitialize]
    public void Setup() => _root = Directory.CreateTempSubdirectory("programa-usage-").FullName;

    [TestCleanup]
    public void Cleanup() => Directory.Delete(_root, recursive: true);

    /// <summary>A stand-in `claude` whose `auth status --json` prints <paramref name="body"/>.</summary>
    private string FakeClaude(string body)
    {
        var path = Path.Combine(_root, "claude.cmd");
        File.WriteAllText(path, "@echo off\r\n" + body + "\r\n");
        return path;
    }

    private string Cache(string text)
    {
        var path = Path.Combine(_root, "rate-limits.json");
        File.WriteAllText(path, text);
        return path;
    }

    [TestMethod]
    public async Task ClaudeShowsOnlyWhenSignedInWithAFreshCache()
    {
        var now = DateTimeOffset.FromUnixTimeMilliseconds(1_785_168_986_314 + 60_000);
        var fresh = Cache(Claude());
        var timeout = TimeSpan.FromSeconds(10);
        Assert.AreEqual("available", (await ProviderUsage.FetchClaudeAsync(FakeClaude("""echo {"loggedIn": true, "email": "a@b.c"}"""), fresh, timeout, now, default)).State);
        // Signed out exits non-zero but still answers: the provider is left out, not failed.
        Assert.AreEqual("unavailable", (await ProviderUsage.FetchClaudeAsync(FakeClaude("echo {\"loggedIn\": false}\r\nexit /b 1"), fresh, timeout, now, default)).State);
        var garbage = await ProviderUsage.FetchClaudeAsync(FakeClaude("echo nope"), fresh, timeout, now, default);
        Assert.AreEqual(("failed", "claudeRead"), (garbage.State, garbage.Error));
        Assert.AreEqual("unavailable", (await ProviderUsage.FetchClaudeAsync(FakeClaude("""echo {"loggedIn": true}"""), fresh, timeout, now.AddHours(2), default)).State, "a stale cache");
        Assert.AreEqual("unavailable", (await ProviderUsage.FetchClaudeAsync(FakeClaude("""echo {"loggedIn": true}"""), Path.Combine(_root, "none.json"), timeout, now, default)).State);
        Assert.AreEqual("unavailable", (await ProviderUsage.FetchClaudeAsync(null, fresh, timeout, now, default)).State);

        var clock = Stopwatch.StartNew();
        var hung = await ProviderUsage.FetchClaudeAsync(FakeClaude("ping -n 30 127.0.0.1 >nul"), fresh, TimeSpan.FromSeconds(1), now, default);
        Assert.AreEqual("failed", hung.State);
        Assert.IsLessThan(10, clock.Elapsed.TotalSeconds, "the time limit holds");
    }

    private const string Account = """{"id":1,"result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"pro"},"requiresOpenaiAuth":true}}""";

    private static string Rate(string result) => $$"""{"id":2,"result":{{result}}}""";

    [TestMethod]
    public void CodexUsesTheUnifiedWindowsAndItsPlan()
    {
        var result = ProviderUsage.ParseCodex(Account, Rate("""
            {"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":-4,"windowDurationMins":300,"resetsAt":1785171600},
              "secondary":{"usedPercent":124,"windowDurationMins":10080,"resetsAt":1785664800},"credits":{"hasCredits":true,"balance":"12.50","unlimited":false}},
             "rateLimitsByLimitId":{"codex_bengalfox":{"primary":{"usedPercent":77,"windowDurationMins":300,"resetsAt":1785175200}}},
             "rateLimitResetCredits":{"availableCount":3,"credits":[]}}
            """));
        Assert.AreEqual("available", result.State);
        Assert.AreEqual(("window", 0, "weekly", 100), (result.Windows[0].Kind, result.Windows[0].UsedPercent, result.Windows[1].Kind, result.Windows[1].UsedPercent));
        Assert.AreEqual(new UsageSummary("pro", false, "12.50", 3), result.Summary);
        Assert.AreEqual(("duration", 43_200), (ProviderUsage.ParseCodex(Account, Rate("""{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":43200,"resetsAt":1}}}""")).Windows[0].Kind, 43_200));

        // With no unified aggregate, the "codex" bucket is used, never a model-specific one.
        var bucket = """{"primary":{"usedPercent":11,"windowDurationMins":300,"resetsAt":1785171600}}""";
        Assert.AreEqual(11, ProviderUsage.ParseCodex(Account, Rate("""{"rateLimits":null,"rateLimitsByLimitId":{"codex":""" + bucket + ""","other":{"primary":{"usedPercent":77,"windowDurationMins":300,"resetsAt":1}}}}""")).Windows.Single().UsedPercent);
        Assert.AreEqual(11, ProviderUsage.ParseCodex(Account, Rate("""{"rateLimitsByLimitId":{"codex":""" + bucket + "}}")).Windows.Single().UsedPercent);

        Assert.AreEqual("unavailable", ProviderUsage.ParseCodex("""{"id":1,"result":{"account":null}}""", Rate("""{"rateLimits":null,"rateLimitsByLimitId":{}}""")).State, "signed out");
        Assert.AreEqual("unavailable", ProviderUsage.ParseCodex(Account, Rate("""{"rateLimits":{"primary":null,"secondary":null}}""")).State, "no windows");
        foreach (var broken in new[]
        {
            ("{not json", Rate("""{"rateLimits":null}""")),
            (Account, Rate("""{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}""")),
            (Account, Rate("""{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1e100}}}""")),
            (Account, """{"id":2,"error":{"message":"x"}}"""),
        })
            Assert.AreEqual(("failed", "codexInvalid"), (ProviderUsage.ParseCodex(broken.Item1, broken.Item2).State, ProviderUsage.ParseCodex(broken.Item1, broken.Item2).Error), broken.Item2);
    }

    private static string PowerShell => Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");

    [TestMethod]
    public async Task TheAppServerIsAskedForUsageOnlyAfterItInitializes()
    {
        // Answers initialize, then expects exactly initialized, account/read and account/rateLimits/read.
        var server = """
            $first = [Console]::In.ReadLine()
            if ($first -notmatch '"method":"initialize"') { exit 3 }
            [Console]::Out.WriteLine('{"id":0,"result":{"userAgent":"x"}}'); [Console]::Out.Flush()
            $methods = 1..3 | ForEach-Object { ([Console]::In.ReadLine() | ConvertFrom-Json).method }
            if (($methods -join ',') -ne 'initialized,account/read,account/rateLimits/read') { exit 4 }
            [Console]::Out.WriteLine('{"jsonrpc":"2.0","method":"note","params":{}}')
            [Console]::Out.WriteLine('{"id":1,"result":{"account":{"type":"chatgpt","email":"person@example.com"}}}')
            [Console]::Out.WriteLine('{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":24,"windowDurationMins":300,"resetsAt":1785171600},"secondary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":1785664800}}}}')
            [Console]::Out.Flush()
            Start-Sleep -Seconds 30
            """;
        var clock = Stopwatch.StartNew();
        var result = await ProviderUsage.FetchCodexAsync(PowerShell, ["-NoProfile", "-NonInteractive", "-Command", server], TimeSpan.FromSeconds(20), default);
        Assert.AreEqual("available", result.State, result.Error);
        CollectionAssert.AreEqual(new[] { 76, 69 }, result.Windows.Select(window => 100 - window.UsedPercent).ToArray());
        Assert.IsLessThan(15, clock.Elapsed.TotalSeconds, "a server that stays up is stopped once both answers arrive");

        clock.Restart();
        var refused = await ProviderUsage.FetchCodexAsync(PowerShell, ["-NoProfile", "-NonInteractive", "-Command",
            """$null = [Console]::In.ReadLine(); [Console]::Out.WriteLine('{"id":0,"error":{"message":"no"}}'); [Console]::Out.Flush(); Start-Sleep -Seconds 30"""], TimeSpan.FromSeconds(20), default);
        Assert.AreEqual(("failed", "codexRead"), (refused.State, refused.Error));
        Assert.IsLessThan(15, clock.Elapsed.TotalSeconds, "an initialize error ends the read without waiting out the limit");
    }
}
