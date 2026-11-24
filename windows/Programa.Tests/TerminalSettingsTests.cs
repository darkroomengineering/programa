using System.Text;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class TerminalSettingsTests
{
    [TestMethod]
    public void MissingKeysMeanTheDefaults()
    {
        foreach (var text in new[] { "", "{}", """{ "windows": null }""", """{ "windows": { "shortcuts": {} } }""" })
        {
            var (settings, problems) = TerminalSettings.Parse(text);
            Assert.IsNull(settings.Shell, text);
            Assert.IsNull(settings.StartingDirectory, text);
            Assert.IsNull(settings.Command, text);
            Assert.AreEqual(0, problems.Count, text);
        }
    }

    [TestMethod]
    public void TheShellBecomesAQuotedCommand()
    {
        var (settings, problems) = TerminalSettings.Parse("""
            {
              // comments and trailing commas, as in the rest of the file
              "windows": {
                "shell": "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
                "startingDirectory": "C:\\Projects\\programa",
              },
            }
            """);
        Assert.AreEqual(0, problems.Count);
        Assert.AreEqual(@"""C:\Program Files\PowerShell\7\pwsh.exe""", settings.Command);
        Assert.AreEqual(@"C:\Projects\programa", settings.StartingDirectory);
    }

    [TestMethod]
    public void InvalidValuesAreReportedAndLeftUnset()
    {
        foreach (var (windows, key) in new[]
        {
            ("""{ "shell": "pwsh.exe" }""", "windows.shell"),
            ("""{ "shell": "C:\\Tools\\script.ps1" }""", "windows.shell"),
            ("""{ "shell": "\"C:\\Tools\\a.exe\"" }""", "windows.shell"),
            ("""{ "shell": "" }""", "windows.shell"),
            ("""{ "shell": 3 }""", "windows.shell"),
            ("""{ "startingDirectory": "projects" }""", "windows.startingDirectory"),
            ("""[]""", "windows"),
        })
        {
            var (settings, problems) = TerminalSettings.Parse($$"""{ "windows": {{windows}} }""");
            Assert.IsNull(settings.Shell, windows);
            Assert.IsNull(settings.StartingDirectory, windows);
            Assert.AreEqual(key, problems.Single().Path, windows);
        }
    }

    [TestMethod]
    public void ABadKeyLeavesTheOtherInUse()
    {
        var (settings, problems) = TerminalSettings.Parse("""
            { "windows": { "shell": "C:\\Windows\\System32\\cmd.exe", "startingDirectory": "projects" } }
            """);
        Assert.AreEqual(@"""C:\Windows\System32\cmd.exe""", settings.Command);
        Assert.IsNull(settings.StartingDirectory);
        Assert.AreEqual("windows.startingDirectory", problems.Single().Path);
    }

    [TestMethod]
    public void ConfigCheckReportsTheSameProblems()
    {
        var problems = SettingsCheck.Problems(Encoding.UTF8.GetBytes("""
            {
              "windows": {
                "shell": 3
              }
            }
            """));
        Assert.AreEqual("settings.json:3: windows.shell: expected a non-empty, unquoted path or null", problems.Single().Format("settings.json"));
    }
}
