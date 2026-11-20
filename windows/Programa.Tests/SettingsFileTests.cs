using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class SettingsFileTests
{
    private static string Patch(string text, string section, string key, string json) =>
        Encoding.UTF8.GetString(ShortcutSettings.PatchValue(Encoding.UTF8.GetBytes(text), section, key, json));

    private static JsonNode Parse(string text) =>
        JsonNode.Parse(text, null, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true })!;

    [TestMethod]
    public void AnEmptyFileGetsTheSection()
    {
        var result = Parse(Patch("", "app", "appearance", "\"dark\""));
        Assert.AreEqual("dark", (string?)result["app"]!["appearance"]);
    }

    [TestMethod]
    public void OnlyTheValueChangesAndTheMacSettingsAndCommentsStay()
    {
        const string original = """
            {
              // shared with the Mac
              "app": {
                "appearance": "system", // keep me
                "minimalMode": true,
              },
              "notifications": { "showInMenuBar": true }
            }
            """;
        var result = Patch(original, "app", "appearance", "\"light\"");
        result = Patch(result, "app", "terminalFont", """{"family":"Cascadia Mono","size":14}""");
        result = Patch(result, "notifications", "sound", "\"none\"");
        result = Patch(result, "worktrees", "autoRemoveMerged", "false");
        StringAssert.Contains(result, "// shared with the Mac");
        StringAssert.Contains(result, "// keep me");
        var json = Parse(result);
        Assert.AreEqual("light", (string?)json["app"]!["appearance"]);
        Assert.IsTrue((bool)json["app"]!["minimalMode"]!);
        Assert.AreEqual(14, (int)json["app"]!["terminalFont"]!["size"]!);
        Assert.IsTrue((bool)json["notifications"]!["showInMenuBar"]!);
        Assert.AreEqual("none", (string?)json["notifications"]!["sound"]);
        Assert.IsFalse((bool)json["worktrees"]!["autoRemoveMerged"]!);
    }

    [TestMethod]
    public void ASectionThatIsNotAnObjectIsReplaced()
    {
        var json = Parse(Patch("""{ "app": null }""", "app", "warnBeforeQuit", "false"));
        Assert.IsFalse((bool)json["app"]!["warnBeforeQuit"]!);
    }
}
