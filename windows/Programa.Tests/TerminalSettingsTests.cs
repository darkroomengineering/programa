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
            var settings = TerminalSettings.Parse(text);
            Assert.IsNull(settings.Shell, text);
            Assert.IsNull(settings.StartingDirectory, text);
            Assert.IsNull(settings.Command, text);
        }
    }

    [TestMethod]
    public void TheShellBecomesAQuotedCommand()
    {
        var settings = TerminalSettings.Parse("""
            {
              // comments and trailing commas, as in the rest of the file
              "windows": {
                "shell": "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
                "startingDirectory": "C:\\Projects\\programa",
              },
            }
            """);
        Assert.AreEqual(@"""C:\Program Files\PowerShell\7\pwsh.exe""", settings.Command);
        Assert.AreEqual(@"C:\Projects\programa", settings.StartingDirectory);
    }

    [TestMethod]
    public void InvalidValuesAreRefused()
    {
        foreach (var windows in new[]
        {
            """{ "shell": "pwsh.exe" }""",
            """{ "shell": "C:\\Tools\\script.ps1" }""",
            """{ "shell": "\"C:\\Tools\\a.exe\"" }""",
            """{ "shell": "" }""",
            """{ "shell": 3 }""",
            """{ "startingDirectory": "projects" }""",
        })
            Assert.ThrowsExactly<InvalidDataException>(() => TerminalSettings.Parse($$"""{ "windows": {{windows}} }"""), windows);
        Assert.ThrowsExactly<InvalidDataException>(() => TerminalSettings.Parse("""{ "windows": [] }"""));
    }
}
