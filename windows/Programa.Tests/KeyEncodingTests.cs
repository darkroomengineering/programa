using System.Text;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Windows.System;

namespace Programa.Tests;

[TestClass]
public sealed class KeyEncodingTests
{
    private static string Encode(VirtualKey key, bool ctrl = false, bool alt = false, bool shift = false, bool kitty = false) =>
        Encoding.ASCII.GetString(TerminalView.EncodeKey(key, ctrl, alt, shift, appCursor: false, kitty) ?? []);

    [TestMethod]
    public void LegacyModeKeepsXtermBytes()
    {
        Assert.AreEqual("\r", Encode(VirtualKey.Enter, shift: true));
        Assert.AreEqual("\x03", Encode(VirtualKey.C, ctrl: true));
        Assert.AreEqual("\x1b", Encode(VirtualKey.Escape));
        Assert.AreEqual("\x1b[Z", Encode(VirtualKey.Tab, shift: true));
    }

    [TestMethod]
    public void KittyDisambiguateUsesCsiU()
    {
        // Shift+Enter must stay distinct from Enter: agents insert a newline instead of submitting.
        Assert.AreEqual("\x1b[13;2u", Encode(VirtualKey.Enter, shift: true, kitty: true));
        Assert.AreEqual("\r", Encode(VirtualKey.Enter, kitty: true));
        Assert.AreEqual("\x1b[27u", Encode(VirtualKey.Escape, kitty: true));
        Assert.AreEqual("\x1b[99;5u", Encode(VirtualKey.C, ctrl: true, kitty: true));
        Assert.AreEqual("\x1b[97;6u", Encode(VirtualKey.A, ctrl: true, shift: true, kitty: true));
        Assert.AreEqual("\x1b[98;3u", Encode(VirtualKey.B, alt: true, kitty: true));
        Assert.AreEqual("\x1b[9;2u", Encode(VirtualKey.Tab, shift: true, kitty: true));
        Assert.AreEqual("\x1b[127;5u", Encode(VirtualKey.Back, ctrl: true, kitty: true));
        // Arrows keep their legacy CSI form; plain text is left to the text box.
        Assert.AreEqual("\x1b[1;5A", Encode(VirtualKey.Up, ctrl: true, kitty: true));
        Assert.AreEqual("", Encode(VirtualKey.A, kitty: true));
    }
}

[TestClass]
public sealed class LinkTests
{
    [TestMethod]
    public void UrlsAreFoundUnderTheClickWithoutTrailingPunctuation()
    {
        const string text = "See https://example.com/a?b=1. Or (https://en.wikipedia.org/wiki/Rust_(language)) now";
        Assert.AreEqual((4, 28, "https://example.com/a?b=1"), TerminalView.UrlAt(text, 10));
        Assert.AreEqual((4, 28, "https://example.com/a?b=1"), TerminalView.UrlAt(text, 28));
        Assert.IsNull(TerminalView.UrlAt(text, 29));
        Assert.AreEqual("https://en.wikipedia.org/wiki/Rust_(language)", TerminalView.UrlAt(text, 40)?.Uri);
        Assert.IsNull(TerminalView.UrlAt(text, 0));
        Assert.IsNull(TerminalView.UrlAt("no links here", 3));
    }
}
