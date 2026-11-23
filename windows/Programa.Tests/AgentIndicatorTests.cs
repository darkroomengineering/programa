using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class AgentIndicatorTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 17, 12, 0, 0, TimeSpan.Zero);

    private static (ProgramStatusRecord, DateTimeOffset) Report(string state, double minutesAgo, string? app = "claude-code") =>
        (new ProgramStatusRecord(state, null, null, app, null, null), Now.AddMinutes(-minutesAgo));

    [TestMethod]
    public void NoReportsMeansNoIndicator() => Assert.IsNull(AgentIndicator.From([], Now));

    [TestMethod]
    public void WorstStateWinsThenTheFreshestReport()
    {
        var indicator = AgentIndicator.From([Report("idle", 1), Report("working", 3), Report("blocked", 5)], Now)!;
        Assert.AreEqual("blocked", indicator.State);
        Assert.AreEqual("AgentNeedsInput", indicator.LabelKey);

        // Resting states tie; the most recent one shows.
        Assert.AreEqual("done", AgentIndicator.From([Report("idle", 4), Report("done", 1)], Now)!.State);
    }

    [TestMethod]
    public void OnlyActiveStatesGoStaleAfterTenMinutes()
    {
        Assert.IsFalse(AgentIndicator.From([Report("working", 9)], Now)!.IsStale);
        var stale = AgentIndicator.From([Report("working", 11)], Now)!;
        Assert.IsTrue(stale.IsStale);
        Assert.AreEqual("AgentWorkingStale", stale.LabelKey);
        Assert.IsFalse(AgentIndicator.From([Report("idle", 60)], Now)!.IsStale);
    }

    [TestMethod]
    public void EveryKnownAgentHasItsMacOSLogo()
    {
        foreach (var (agent, asset) in new[]
        {
            ("claude-code", "AgentIconClaudeCode"), ("Claude", "AgentIconClaudeCode"), ("codex", "AgentIconCodex"),
            ("copilot-cli", "AgentIconCopilot"), ("github-copilot", "AgentIconCopilot"), ("cursor-agent", "AgentIconCursor"),
            ("gemini-cli", "AgentIconGeminiCLI"), ("gemini", "AgentIconGeminiCLI"), (" opencode ", "AgentIconOpenCode"),
        })
        {
            Assert.AreEqual(asset, AgentIndicator.LogoAsset(agent), agent);
            Assert.IsTrue(System.Text.Encoding.UTF8.GetString(AgentIndicator.LogoSvg(asset, dark: false)).StartsWith("<svg", StringComparison.Ordinal), asset);
        }
        Assert.IsNull(AgentIndicator.LogoAsset("aider"));
        Assert.IsNull(AgentIndicator.LogoAsset(null));
        // The monochrome logos have a white file for dark mode; the colored ones are the same in both.
        Assert.IsTrue(System.Text.Encoding.UTF8.GetString(AgentIndicator.LogoSvg("AgentIconCursor", dark: true)).Contains("#FFFFFF", StringComparison.Ordinal));
        Assert.IsTrue(System.Text.Encoding.UTF8.GetString(AgentIndicator.LogoSvg("AgentIconCursor", dark: false)).Contains("#000000", StringComparison.Ordinal));
        CollectionAssert.AreEqual(AgentIndicator.LogoSvg("AgentIconCodex", dark: false), AgentIndicator.LogoSvg("AgentIconCodex", dark: true));
    }

    [TestMethod]
    public void ElapsedUsesTheLargestWholeUnit()
    {
        Assert.IsNull(AgentIndicator.Elapsed(TimeSpan.FromSeconds(40)));
        Assert.AreEqual(("ElapsedMinutes", 3L), AgentIndicator.Elapsed(TimeSpan.FromMinutes(3.5)));
        Assert.AreEqual(("ElapsedHours", 2L), AgentIndicator.Elapsed(TimeSpan.FromMinutes(150)));
        Assert.AreEqual(("ElapsedDays", 4L), AgentIndicator.Elapsed(TimeSpan.FromDays(4.2)));
    }
}
