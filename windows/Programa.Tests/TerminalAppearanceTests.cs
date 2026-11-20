using Microsoft.VisualStudio.TestTools.UnitTesting;
using Windows.UI;

namespace Programa.Tests;

[TestClass]
public sealed class TerminalAppearanceTests
{
    [TestMethod]
    public void WithoutConfigItIsGhosttysDefaultLook()
    {
        var appearance = TerminalAppearance.Load(dark: true, [], null, []);
        Assert.AreEqual("JetBrains Mono", appearance.FontFamily);
        Assert.AreEqual(13f, appearance.FontSize);
        Assert.AreEqual(Color.FromArgb(255, 0x28, 0x2C, 0x34), appearance.Background);
        Assert.AreEqual(Color.FromArgb(255, 0xFF, 0xFF, 0xFF), appearance.Foreground);
        Assert.IsNull(appearance.SelectionBackground);
        // The shape programa_terminal.dll parses: RGB number triples, not base64 bytes.
        StringAssert.Contains(System.Text.Json.JsonSerializer.Serialize(appearance.CoreColors), "\"background\":[40,44,52]");
    }

    [TestMethod]
    public void ThemeThenConfigThenSettingsJson()
    {
        var root = Directory.CreateTempSubdirectory("programa-appearance-").FullName;
        try
        {
            var themes = Directory.CreateDirectory(Path.Combine(root, "themes")).FullName;
            File.WriteAllText(Path.Combine(themes, "Night"), "background = #000000\nforeground = #eeeeee\npalette = 1=#ff0000\n");
            File.WriteAllText(Path.Combine(themes, "Day"), "background = #ffffff\n");
            var config = Path.Combine(root, "config");
            // The config's own background wins over its theme's, as in Ghostty.
            File.WriteAllText(config, "# comment\ntheme = light:Day,dark:Night\nforeground = #123456\nfont-family = Fira Code\nfont-family = Menlo\nfont-size = 15\n");

            var dark = TerminalAppearance.Load(dark: true, [config], null, [themes]);
            Assert.AreEqual(Color.FromArgb(255, 0, 0, 0), dark.Background);
            Assert.AreEqual(Color.FromArgb(255, 0x12, 0x34, 0x56), dark.Foreground);
            Assert.AreEqual(Color.FromArgb(255, 255, 0, 0), dark.Palette[1]);
            Assert.AreEqual("Fira Code", dark.FontFamily);
            Assert.AreEqual(15f, dark.FontSize);

            var light = TerminalAppearance.Load(dark: false, [config], null, [themes]);
            Assert.AreEqual(Color.FromArgb(255, 255, 255, 255), light.Background);

            const string Settings = """{ "app": { "terminalTheme": { "light": "Night", "dark": "Night" }, "terminalFont": { "family": "Consolas", "size": 11 } } }""";
            var managed = TerminalAppearance.Load(dark: false, [config], Settings, [themes]);
            Assert.AreEqual(Color.FromArgb(255, 0, 0, 0), managed.Background);
            Assert.AreEqual("Consolas", managed.FontFamily);
            Assert.AreEqual(11f, managed.FontSize);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [TestMethod]
    public void BundledThemesAndFontShipWithTheApp()
    {
        Assert.IsTrue(File.Exists(Path.Combine(AppContext.BaseDirectory, "themes", "Catppuccin Mocha")));
        Assert.IsTrue(File.Exists(Path.Combine(AppContext.BaseDirectory, "Fonts", "JetBrainsMono-Regular.ttf")));
        var appearance = TerminalAppearance.Load(dark: true, [], null, []);
        StringAssert.StartsWith(appearance.CanvasFontFamily(bold: true, italic: false), "file:///");
        StringAssert.EndsWith(appearance.CanvasFontFamily(bold: true, italic: false), "JetBrainsMono-Bold.ttf#JetBrains Mono");
    }
}
