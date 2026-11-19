using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class ControlServerTests
{
    [TestMethod]
    public async Task RequestsAreAnsweredInTheV2Envelope()
    {
        using var server = new ControlServer((method, _) => method == "system.ping"
            ? Task.FromResult<object?>(new { pong = true })
            : throw new ControlException("method_not_found", $"{method} is not available."));

        // The id comes back verbatim, whatever its type.
        Assert.AreEqual("""{"id":7,"ok":true,"result":{"pong":true}}""", await server.HandleLineAsync("""{"id":7,"method":"system.ping"}"""));
        Assert.AreEqual("""{"id":"a","ok":false,"error":{"code":"method_not_found","message":"x.y is not available."}}""",
            await server.HandleLineAsync("""{"id":"a","method":"x.y","params":{}}"""));
        StringAssert.Contains(await server.HandleLineAsync("not json"), "\"code\":\"invalid_request\"");
        StringAssert.Contains(await server.HandleLineAsync("""{"id":1}"""), "\"code\":\"invalid_request\"");
    }

    [TestMethod]
    public async Task BannerClaimsBelongToTheirConnectionAndABadCallKeepsTheOldOne()
    {
        using var server = new ControlServer((_, _) => Task.FromResult<object?>(null));
        var first = new ControlServer.Connection(_ => Task.CompletedTask);
        var second = new ControlServer.Connection(_ => Task.CompletedTask);
        Task<string> Claim(ControlServer.Connection connection, string kinds) =>
            server.HandleLineAsync("""{"id":1,"method":"notification.claim_banners","params":{"kinds":""" + kinds + "}}", connection);

        Assert.AreEqual("""{"id":1,"ok":true,"result":{"claimed":["needs_input"]}}""", await Claim(first, """["needs_input","needs_input"]"""));
        await Claim(second, """["needs_input"]""");
        StringAssert.Contains(await Claim(first, """["sounds"]"""), "Unknown notification kind 'sounds' -- use: needs_input");
        StringAssert.Contains(await Claim(first, "null"), "kinds must be an array of: needs_input");
        Assert.AreEqual("""{"id":1,"ok":true,"result":{"claimed":[]}}""", await Claim(second, "[]"));
        // The bad calls left the first connection's claim alone.
        Assert.IsTrue(ControlServer.BannerClaimed("needs_input"));
        await Claim(first, "[]");
        Assert.IsFalse(ControlServer.BannerClaimed("needs_input"));
    }

    [TestMethod]
    public void BrowsersAreKnownByTheProgramTheirRegistrationRuns()
    {
        Assert.AreEqual(@"C:\Program Files\Google\Chrome\Application\chrome.exe", Browsers.ExePath(@"""C:\Program Files\Google\Chrome\Application\chrome.exe"" --single-argument %1"));
        Assert.AreEqual(@"C:\Tools\firefox.exe", Browsers.ExePath(@"C:\Tools\firefox.exe -osint -url %1"));
        Assert.IsNull(Browsers.ExePath(" "));
        Assert.AreEqual("chrome", Browsers.Match(@"C:\Program Files\Google\Chrome\Application\chrome.exe")?.Key);
        Assert.AreEqual("chromium", Browsers.Match(@"C:\Users\me\AppData\Local\Chromium\Application\chrome.exe")?.Key);
        Assert.AreEqual("opera-gx", Browsers.Match(@"C:\Users\me\AppData\Local\Programs\Opera GX\opera.exe")?.Key);
        Assert.AreEqual("opera", Browsers.Match(@"C:\Users\me\AppData\Local\Programs\Opera\opera.exe")?.Key);
        Assert.AreEqual("edge", Browsers.Match(@"C:\Program Files (x86)\Microsoft\Edge\Application\MSEDGE.EXE")?.Key);
        Assert.IsNull(Browsers.Match(@"C:\Tools\notepad.exe"));
    }

    [TestMethod]
    public void EachBuildHasItsOwnPipe()
    {
        StringAssert.StartsWith(ControlServer.PipePath, @"\\.\pipe\programa-");
        StringAssert.EndsWith(ControlServer.PipePath, Environment.UserName);
    }
}
