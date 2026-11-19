using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class LayoutTests
{
    [TestMethod]
    public void AFileParsesAndSavesBackTheSameTree()
    {
        var json = """
            {"direction":"horizontal","split":0.95,"children":[
              {"pane":{"surfaces":[{"type":"terminal","name":"server","command":"npm run dev","cwd":"app","env":{"PORT":"3000"}},{"type":"browser"}]}},
              {"pane":{"surfaces":[{"type":"browser"}]}}]}
            """;
        using var document = JsonDocument.Parse(json);
        var layout = (LayoutSplit)Layouts.Parse(document.RootElement, "layout");
        Assert.AreEqual(0.9, layout.Split);
        var server = ((LayoutPane)layout.First).Surfaces.Single();
        Assert.AreEqual(("server", "npm run dev", "app", "3000"), (server.Name, server.Command, server.Cwd, server.Env!["PORT"]));
        // A pane left with only browser surfaces opens one terminal.
        Assert.AreEqual(new LayoutSurface(), ((LayoutPane)layout.Second).Surfaces.Single());
        using var again = JsonDocument.Parse(Layouts.Serialize(layout).ToJsonString());
        Assert.AreEqual("server", ((LayoutPane)((LayoutSplit)Layouts.Parse(again.RootElement, "layout")).First).Surfaces[0].Name);

        using var broken = JsonDocument.Parse("""{"pane":{}}""");
        Assert.AreEqual("missing key 'surfaces' in 'layout.pane'", Assert.ThrowsExactly<Layouts.LayoutException>(() => Layouts.Parse(broken.RootElement, "layout")).Message);
    }

    [TestMethod]
    public void DirectoriesResolveAgainstTheWorkspace()
    {
        Assert.AreEqual(@"C:\src\app", MainWindow.ResolveDirectory(@"C:\src\app", "."));
        Assert.AreEqual(@"C:\src\app\web", MainWindow.ResolveDirectory(@"C:\src\app", "web"));
        Assert.AreEqual(@"D:\other", MainWindow.ResolveDirectory(@"C:\src\app", @"D:\other"));
        Assert.AreEqual("web/client", MainWindow.RelativeDirectory(@"C:\src\app", @"C:\src\app\web\client"));
        Assert.IsNull(MainWindow.RelativeDirectory(@"C:\src\app", @"C:\src\app"));
        Assert.AreEqual(@"D:\other", MainWindow.RelativeDirectory(@"C:\src\app", @"D:\other"));
    }

    [TestMethod]
    public void SavedLayoutsAreListedRenamedAndDeleted()
    {
        var previous = Layouts.Folder;
        Layouts.Folder = Directory.CreateTempSubdirectory("programa-layouts-").FullName;
        try
        {
            var layout = new LayoutPane([new LayoutSurface(Name: "shell")]);
            Layouts.Save("dev", layout, force: false);
            Assert.AreEqual("already_exists", Assert.ThrowsExactly<Layouts.LayoutException>(() => Layouts.Save("dev", layout, force: false)).Code);
            Assert.AreEqual("invalid_name", Assert.ThrowsExactly<Layouts.LayoutException>(() => Layouts.Save("a/b", layout, force: false)).Code);
            File.WriteAllText(Path.Combine(Layouts.Folder, "broken.json"), "{");
            Layouts.Save("other", layout, force: false);
            Assert.AreEqual("already_exists", Assert.ThrowsExactly<Layouts.LayoutException>(() => Layouts.Rename("dev", "other")).Code);
            Layouts.Rename("dev", "renamed");
            Layouts.Delete("other");
            var all = Layouts.All();
            CollectionAssert.AreEqual(new[] { "broken", "renamed" }, all.Select(item => item.Name).ToArray());
            Assert.IsNotNull(all[0].Error);
            Assert.AreEqual("shell", ((LayoutPane)all[1].Layout!).Surfaces[0].Name);
        }
        finally
        {
            Directory.Delete(Layouts.Folder, recursive: true);
            Layouts.Folder = previous;
        }
    }
}

[TestClass]
public sealed class MarkdownPanelTests
{
    [TestMethod]
    public void GitHubFlavoredMarkdownRendersWithRelativeImagesFromTheFileFolder()
    {
        var html = MarkdownPanel.Html("# Plan\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n![shot](images/shot.png)\n", dark: true);
        StringAssert.Contains(html, "<h1 id=\"plan\">Plan</h1>");
        StringAssert.Contains(html, "<table>");
        StringAssert.Contains(html, "type=\"checkbox\"");
        StringAssert.Contains(html, "<base href=\"https://programa-markdown.local/\">");
        StringAssert.Contains(html, "src=\"images/shot.png\"");
    }
}
