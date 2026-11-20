using System.Text;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class MarkdownPanelTests
{
    private static readonly MarkdownLabels Labels = new("Before", "After", "Too big", "File unavailable", "Moved or deleted");

    private static MarkdownBody Render(string markdown) => MarkdownPanel.Render(markdown, Labels);

    [TestMethod]
    public void GitHubFlavoredMarkdownRendersWithRelativeImages()
    {
        var html = Render("# Plan\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n![shot](images/shot.png)\n").Html;
        StringAssert.Contains(html, "<h1 id=\"plan\">Plan</h1>");
        StringAssert.Contains(html, "<table>");
        StringAssert.Contains(html, "type=\"checkbox\"");
        StringAssert.Contains(html, "src=\"images/shot.png\"");
    }

    [TestMethod]
    public void MermaidFencesInAnyCaseBecomeEscapedDiagramSources()
    {
        var diagram = Render("Intro\n\n```Mermaid\ngraph TD; A-->B<img src=x>\n```\n");
        Assert.IsTrue(diagram.HasMermaid);
        StringAssert.Contains(diagram.Html, "<pre class=\"mermaid\">graph TD; A--");
        StringAssert.Contains(diagram.Html, "&lt;img");
        Assert.IsFalse(diagram.Html.Contains("<img src=x>"));

        var code = Render("```js\nconst a = 1;\n```\n");
        Assert.IsFalse(code.HasMermaid);
        StringAssert.Contains(code.Html, "class=\"language-js\"");
        Assert.IsFalse(Render("Just `mermaid` text.").HasMermaid);
    }

    [TestMethod]
    public void CompareBlocksTakeTheirSidesFromLabelsThenOrder()
    {
        var labeled = Render(":::compare\n```swift after\nlet a = 2\n```\nignored text\n```swift before\nlet a = 1\n```\n:::\n").Html;
        StringAssert.Contains(labeled, "<div class=\"side before\"><div class=\"side-title\">Before <span class=\"language\">(swift)</span></div><pre><code>let a = 1</code></pre></div>");
        StringAssert.Contains(labeled, "<div class=\"side after\"><div class=\"side-title\">After <span class=\"language\">(swift)</span></div><pre><code>let a = 2</code></pre></div>");
        Assert.IsFalse(labeled.Contains("ignored text"));

        var ordered = Render(":::Compare\n```\n<old>\n```\n```py\nnew\n```\n:::\n");
        StringAssert.Contains(ordered.Html, "<div class=\"side before\"><div class=\"side-title\">Before <span class=\"language\">(py)</span></div><pre><code>&lt;old&gt;</code></pre>");
        StringAssert.Contains(ordered.Html, "<pre><code>new</code></pre>");
    }

    [TestMethod]
    public void MalformedCompareBlocksRenderAsOrdinaryMarkdown()
    {
        var unclosed = Render(":::compare\n```a\n1\n```\n```b\n2\n```\n").Html;
        Assert.IsFalse(unclosed.Contains("class=\"side"));
        StringAssert.Contains(unclosed, "class=\"language-a\"");

        var three = Render(":::compare\n```a\n1\n```\n```a\n2\n```\n```a\n3\n```\n:::\n").Html;
        Assert.IsFalse(three.Contains("class=\"side"));

        // Mermaid inside a compare block is code to compare, not a diagram.
        Assert.IsFalse(Render(":::compare\n```mermaid\ngraph TD; A-->B\n```\n```mermaid\ngraph TD; A-->C\n```\n:::\n").HasMermaid);
    }

    [TestMethod]
    public void GitHubAlertsBecomeCallouts()
    {
        var html = Render("> [!WARNING]\n> Mind the *gap*\n").Html;
        StringAssert.Contains(html, "markdown-alert-warning");
        StringAssert.Contains(html, "Warning</p>");
        StringAssert.Contains(html, "<em>gap</em>");
    }

    [TestMethod]
    public void TheBaseAndLinksMapBetweenTheFileHostAndTheDisk()
    {
        var file = @"C:\repo\my docs\plan.md";
        var baseHref = MarkdownPanel.BaseHref(file);
        Assert.AreEqual("https://programa-markdown.local/repo/my%20docs/", baseHref);
        Assert.AreEqual(@"C:\repo\README.md", MarkdownPanel.LocalPath(file, new Uri(new Uri(baseHref), "../README.md#usage")));
        Assert.AreEqual(@"C:\repo\my docs\sub dir\a.md", MarkdownPanel.LocalPath(file, new Uri(new Uri(baseHref), "sub%20dir/a.md")));
        Assert.IsNull(MarkdownPanel.LocalPath(file, new Uri("https://example.com/a.md")));
        Assert.AreEqual("https://programa-markdown.local/", MarkdownPanel.BaseHref(@"D:\notes.md"));
    }

    [TestMethod]
    public void FilesReadAsMacOSReadsThem()
    {
        var folder = Directory.CreateTempSubdirectory("programa-markdown-").FullName;
        try
        {
            string Write(string name, byte[] bytes) { var path = Path.Combine(folder, name); File.WriteAllBytes(path, bytes); return path; }

            // A cut inside "é" (C3 A9) drops the partial character instead of falling back to Latin-1.
            var cut = MarkdownPanel.Read(Write("cut.md", Encoding.UTF8.GetBytes("abcé")), maxBytes: 4);
            Assert.AreEqual(("abc", true), cut);
            Assert.AreEqual(("caf" + (char)0xE9, false), MarkdownPanel.Read(Write("latin.md", [0x63, 0x61, 0x66, 0xE9])));
            Assert.AreEqual(("# Title", false), MarkdownPanel.Read(Write("bom.md", [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes("# Title")])));
            Assert.AreEqual(("# 見出し", false), MarkdownPanel.Read(Write("utf16.md", [0xFF, 0xFE, .. Encoding.Unicode.GetBytes("# 見出し")])));
            Assert.IsNull(MarkdownPanel.Read(Path.Combine(folder, "missing.md")));
        }
        finally { Directory.Delete(folder, recursive: true); }
    }

    [TestMethod]
    public void TheBodyShowsThePathTheTruncationOrTheUnavailableFile()
    {
        var folder = Directory.CreateTempSubdirectory("programa-markdown-").FullName;
        try
        {
            var path = Path.Combine(folder, "big.md");
            File.WriteAllText(path, "# Big\n" + new string('x', MarkdownPanel.MaxDisplayBytes));
            var big = MarkdownPanel.Body(path, Labels).Html;
            StringAssert.Contains(big, $"<div class=\"file-path\">{path}</div>");
            StringAssert.Contains(big, "Too big");
            StringAssert.Contains(big, "<h1 id=\"big\">Big</h1>");

            File.Delete(path);
            var gone = MarkdownPanel.Body(path, Labels);
            StringAssert.Contains(gone.Html, "File unavailable");
            StringAssert.Contains(gone.Html, "Moved or deleted");
            StringAssert.Contains(gone.Html, path);
            Assert.IsFalse(gone.Html.Contains("file-path"));
        }
        finally { Directory.Delete(folder, recursive: true); }
    }
}
