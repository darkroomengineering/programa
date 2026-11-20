using System.Text;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Windows.System;

namespace Programa.Tests;

[TestClass]
public sealed class NamedKeysTests
{
    /// <summary>The bytes surface.send_key writes outside application cursor and kitty modes.</summary>
    private static string Bytes(string name)
    {
        var key = NamedKeys.Parse(name) ?? throw new AssertFailedException($"{name} did not parse");
        var bytes = key.Character is { } character && !key.Ctrl && !key.Alt
            ? Encoding.UTF8.GetBytes((key.Shift ? char.ToUpperInvariant(character) : character).ToString())
            : TerminalView.EncodeKey(key.Key, key.Ctrl, key.Alt, key.Shift, appCursor: false);
        return Encoding.ASCII.GetString(bytes ?? throw new AssertFailedException($"{name} has no encoding"));
    }

    [TestMethod]
    public void TheMacOSKeyNamesTypeWhatTheKeyboardWould()
    {
        Assert.AreEqual("\r", Bytes("Enter"));
        Assert.AreEqual("\r", Bytes("return"));
        Assert.AreEqual("\x03", Bytes("ctrl+c"));
        Assert.AreEqual("\x03", Bytes("sigint"));
        Assert.AreEqual("\x04", Bytes("eof"));
        Assert.AreEqual("\x1a", Bytes("ctrl-z"));
        Assert.AreEqual("\x1c", Bytes("sigquit"));
        Assert.AreEqual("\x1b", Bytes("esc"));
        Assert.AreEqual("\x7f", Bytes("backspace"));
        Assert.AreEqual("\x1b[Z", Bytes("shift-tab"));
        Assert.AreEqual("\x1b[A", Bytes("arrow_up"));
        Assert.AreEqual("\x1b[1;5D", Bytes("ctrl+left"));
        Assert.AreEqual("\x1b[3~", Bytes("forward_delete"));
        Assert.AreEqual("\x1b[6~", Bytes("page_down"));
        Assert.AreEqual("\x1b" + "b", Bytes("alt+b"));
        Assert.AreEqual("\x01", Bytes("control-a"));
        Assert.AreEqual("q", Bytes("q"));
        Assert.AreEqual("Q", Bytes("shift+q"));
        Assert.AreEqual(" ", Bytes("space"));
        Assert.AreEqual("\0", Bytes("ctrl+space"));
    }

    [TestMethod]
    public void UnknownNamesAndTheCommandKeyAreRefused()
    {
        foreach (var name in new[] { "", "f13", "hyper+a", "cmd+k", "super+c", "ctrl+", "ab" })
            Assert.IsNull(NamedKeys.Parse(name), name);
    }

    [TestMethod]
    public void TheFingerprintIsTheMacOSSha256OfTheText()
    {
        Assert.AreEqual("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", MainWindow.Fingerprint(string.Empty));
        Assert.AreEqual("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", MainWindow.Fingerprint("hello"));
    }

    [TestMethod]
    public void CopyModeKeysTakeCountsAndTwoKeyCommandsAsOnMacOS()
    {
        var keys = new CopyModeKeys();
        (CopyAction, int) Press(string key, bool visual = false) => keys.Resolve(key, visual);

        // A count prefix, 0 only after another digit; it applies to the next motion.
        Assert.AreEqual((CopyAction.None, 1), Press("1"));
        Assert.AreEqual((CopyAction.None, 1), Press("0"));
        Assert.AreEqual((CopyAction.Down, 10), Press("j"));
        Assert.AreEqual((CopyAction.LineStart, 1), Press("0"));
        // yy and 3Y copy lines; gg goes to the top and G to the bottom.
        Assert.AreEqual((CopyAction.None, 1), Press("y"));
        Assert.AreEqual((CopyAction.CopyLines, 1), Press("y"));
        Press("3");
        Assert.AreEqual((CopyAction.CopyLines, 3), Press("Y"));
        Press("g");
        Assert.AreEqual((CopyAction.Top, 1), Press("g"));
        Assert.AreEqual((CopyAction.Bottom, 1), Press("G"));
        // A started yy or gg gives way to the next key, which runs as itself.
        Press("g");
        Assert.AreEqual((CopyAction.Up, 1), Press("k"));
        // In visual mode y copies the selection at once; v ends it.
        Assert.AreEqual((CopyAction.Copy, 1), Press("y", visual: true));
        Assert.AreEqual((CopyAction.ToggleVisual, 1), Press("v", visual: true));
        // Named keys and Ctrl chords; Escape always leaves and drops a pending count.
        Press("5");
        Assert.AreEqual((CopyAction.Exit, 1), Press("esc"));
        Assert.AreEqual((CopyAction.HalfPageUp, 1), Press("ctrl-u"));
        Assert.AreEqual((CopyAction.PageDown, 1), Press("pagedown"));
        Assert.AreEqual((CopyAction.SearchPrevious, 1), Press("N"));
        Assert.AreEqual((CopyAction.Exit, 1), Press("q"));
        Assert.AreEqual((CopyAction.None, 1), Press("ctrl-c"));
        Assert.AreEqual((CopyAction.None, 1), Press("{"));
    }
}
