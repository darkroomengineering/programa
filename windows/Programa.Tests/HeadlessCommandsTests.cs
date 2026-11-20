using System.Text;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

/// <summary>The app's headless modes behind `programa config check` and `programa themes`, and the
/// agent event states behind `programa agent-event`.</summary>
[TestClass]
public sealed class HeadlessCommandsTests
{
    private string _folder = "";

    [TestInitialize]
    public void CreateFolder()
    {
        _folder = Path.Combine(Path.GetTempPath(), "programa-headless-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(_folder, "themes"));
        foreach (var theme in new[] { "Dracula", "Catppuccin Latte", "Catppuccin Mocha" })
            File.WriteAllText(Path.Combine(_folder, "themes", theme), "background = 000000");
    }

    [TestCleanup]
    public void RemoveFolder() => Directory.Delete(_folder, true);

    private string Settings => Path.Combine(_folder, "settings.json");

    private (int Code, string Output, string Error) Check(string? text, bool explicitPath = false)
    {
        if (text is not null) File.WriteAllText(Settings, text);
        var (output, error) = (new StringWriter(), new StringWriter());
        var code = SettingsCheck.Run(explicitPath ? Settings : null, Settings, output, error);
        return (code, output.ToString().ReplaceLineEndings("\n"), error.ToString().ReplaceLineEndings("\n"));
    }

    private (int Code, string Output, string Error) Themes(params string[] args)
    {
        var (output, error) = (new StringWriter(), new StringWriter());
        var code = ThemesCommand.Run(args, Settings, [Path.Combine(_folder, "themes"), Path.Combine(_folder, "missing")], output, error);
        return (code, output.ToString().ReplaceLineEndings("\n"), error.ToString().ReplaceLineEndings("\n"));
    }

    [TestMethod]
    public void AValidOrMissingFilePassesAndAMissingExplicitOneCannotBeChecked()
    {
        Assert.AreEqual((0, $"No settings.json at {Settings}; the defaults are in use\n", ""), Check(null));
        Assert.AreEqual((2, "", $"No settings file at {Settings}\n"), Check(null, explicitPath: true));
        Assert.AreEqual((0, "settings.json is valid\n", ""), Check("""
            {
              // comments and trailing commas are JSONC
              "app": { "appearance": "dark", "terminalTheme": null, },
            }
            """));
    }

    [TestMethod]
    public void ProblemsArePrintedByLineWithTheMacMessages()
    {
        var (code, output, _) = Check("""
            {
              "app": {
                "appearance": "dim",
                "terminalTheme": { "light": "", "dark": "Dracula" },
                "terminalFont": { "family": "Cascadia Mono" }
              },
              "customCommands": { "trustedDirectories": "C:\\code" }
            }
            """);
        Assert.AreEqual(1, code);
        Assert.AreEqual("""
            settings.json:3: app.appearance: expected one of "system", "light", "dark", "auto"
            settings.json:4: app.terminalTheme.light: expected a non-empty theme name or null
            settings.json:5: app.terminalFont: expected an object with a non-empty family and a size above 0, or null
            settings.json:7: customCommands.trustedDirectories: expected an array of strings

            """.ReplaceLineEndings("\n"), output);
        var broken = Check("{\n  \"app\": {\n    \"appearance\": \n  }\n}");
        Assert.AreEqual(1, broken.Code);
        StringAssert.StartsWith(broken.Output, "settings.json:4: ");
        Assert.AreEqual("settings.json:1: the top level is not a JSON object\n", Check("[1]").Output);
    }

    [TestMethod]
    public void ThemesSetWritesSettingsAndListMarksTheChoice()
    {
        File.WriteAllText(Settings, "{\n  // mine\n  \"app\": { \"appearance\": \"dark\" }\n}\n");
        Assert.AreEqual((0, $"OK light=Catppuccin Mocha dark=Catppuccin Mocha config={Settings} reload=requested\n", ""), Themes("set", "catppuccin", "mocha"));
        Assert.AreEqual(0, Themes("set", "--light", "dracula", "--font", "Cascadia Mono").Code);
        var text = File.ReadAllText(Settings);
        StringAssert.Contains(text, "// mine");
        var app = JsonNode.Parse(text, null, new() { CommentHandling = System.Text.Json.JsonCommentHandling.Skip })!["app"]!;
        Assert.AreEqual("Dracula", (string?)app["terminalTheme"]!["light"]);
        Assert.AreEqual("Catppuccin Mocha", (string?)app["terminalTheme"]!["dark"]);
        // A font always has a size, so the Mac reads it too.
        Assert.AreEqual(13, (double)app["terminalFont"]!["size"]!);

        var listed = Themes("list").Output;
        StringAssert.StartsWith(listed, "Current light: Dracula\nCurrent dark: Catppuccin Mocha\nOpacity: inherit\nBlur: inherit\nFont: Cascadia Mono 13.0\n");
        StringAssert.Contains(listed, "\nCatppuccin Latte\nCatppuccin Mocha  [dark]\nDracula  [light]\n");
        var json = JsonNode.Parse(Themes("--json").Output)!;
        Assert.AreEqual(true, (bool)json["themes"]![2]!["current_light"]!);

        Assert.AreEqual(0, Themes("clear").Code);
        StringAssert.StartsWith(Themes().Output, "Current light: inherit\nCurrent dark: inherit\n");
    }

    [TestMethod]
    public void ThemesRefusesWhatMacRefusesAndWhatWindowsCannotShow()
    {
        Assert.AreEqual((1, "", "Error: Unknown theme 'Catppuccin'. Did you mean: 'Catppuccin Latte', 'Catppuccin Mocha'? Run 'programa themes' to list available themes.\n"),
            Themes("set", "Catppuccin"));
        Assert.AreEqual("Error: themes set requires a theme name or at least one flag: --light, --dark, --opacity, --blur/--no-blur, --font, --font-size\n", Themes("set").Error);
        Assert.AreEqual("Error: themes set: cannot pass both --blur and --no-blur\n", Themes("set", "--blur", "--no-blur").Error);
        Assert.AreEqual("Error: themes set: --opacity, --blur and --no-blur are not supported on Windows\n", Themes("set", "--opacity", "0.8").Error);
        Assert.AreEqual("Error: themes set: --font-size must be a positive number\n", Themes("set", "--font-size", "0").Error);
        Assert.AreEqual("Error: Unknown themes subcommand '--x'. Run 'programa themes --help'.\n", Themes("--x").Error);
        StringAssert.StartsWith(Themes("set", "--bold").Error, "Error: themes set: unknown flag '--bold'.");
        Assert.IsFalse(File.Exists(Settings));
    }

    [TestMethod]
    public void AgentEventsMapToTheMacStates()
    {
        Assert.AreEqual(11, MainWindow.AgentEventStates.Count);
        Assert.AreEqual("working", MainWindow.AgentEventStates["turn.started"]);
        Assert.AreEqual("idle", MainWindow.AgentEventStates["turn.completed"]);
        Assert.AreEqual("blocked", MainWindow.AgentEventStates["user-input.requested"]);
        Assert.IsNull(MainWindow.AgentEventStates["session.exited"]);
    }
}
