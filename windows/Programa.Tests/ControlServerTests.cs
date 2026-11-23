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
    public void ATaggedDevBuildNamesItsPipeAndFilesApart()
    {
        const string dev = "programa 0.0.0-dev (build 0, commit local)";
        Assert.AreEqual("-dev", BuildIdentity.DevSuffixFor(dev, null));
        Assert.AreEqual("-dev-copy-mode", BuildIdentity.DevSuffixFor(dev, "Copy-Mode"));
        // A tag that could leave the folder or the pipe namespace is ignored.
        Assert.AreEqual("-dev", BuildIdentity.DevSuffixFor(dev, @"..\x"));
        Assert.AreEqual("-dev", BuildIdentity.DevSuffixFor(dev, new string('a', 33)));
        // The installed app never takes a tag.
        Assert.AreEqual("", BuildIdentity.DevSuffixFor("programa 0.7.0 (build 9, commit abc)", "x"));
    }

    [TestMethod]
    public void EachBuildHasItsOwnPipe()
    {
        StringAssert.StartsWith(ControlServer.PipePath, @"\\.\pipe\programa-");
        StringAssert.EndsWith(ControlServer.PipePath, Environment.UserName);
    }

    [TestMethod]
    public void EachSocketModeAdmitsWhoMacOSAdmits()
    {
        Assert.AreEqual(ControlServer.Access.Off, ControlServer.Decide("off", true));
        Assert.AreEqual(ControlServer.Access.Allowed, ControlServer.Decide("programaOnly", true));
        Assert.AreEqual(ControlServer.Access.Denied, ControlServer.Decide("programaOnly", false));
        Assert.AreEqual(ControlServer.Access.Allowed, ControlServer.Decide("automation", false));
        Assert.AreEqual(ControlServer.Access.Allowed, ControlServer.Decide("password", true));
        Assert.AreEqual(ControlServer.Access.NeedsLogin, ControlServer.Decide("password", false));
    }

    [TestMethod]
    public void AncestryMustReachTheAppOrHostWithoutAReusedPid()
    {
        // 30 (cli) <- 20 (claude) <- 10 (shell) <- 1000 (terminal host, started at 5)
        var table = new Dictionary<uint, (uint Parent, long Started, string Name)>
        {
            [30] = (20, 300, "programa.exe"), [20] = (10, 200, "claude.exe"), [10] = (1000, 100, "pwsh.exe"), [1000] = (1, 5, "programa-host.exe"),
            // 40's parent pid 50 now belongs to a process that started after it.
            [40] = (50, 150, "script.exe"), [50] = (1000, 400, "late.exe"),
            [60] = (70, 10, "outside.exe"), [70] = (1, 1, "explorer.exe"),
        };
        (uint, long, string)? Describe(uint pid) => table.TryGetValue(pid, out var row) ? row : null;
        var host = new Dictionary<uint, long> { [1000] = 5 };
        Assert.IsTrue(ControlServer.DescendsFrom(30, host, Describe));
        Assert.IsFalse(ControlServer.DescendsFrom(40, host, Describe));
        Assert.IsFalse(ControlServer.DescendsFrom(60, host, Describe));
        Assert.IsFalse(ControlServer.DescendsFrom(30, new Dictionary<uint, long> { [1000] = 6 }, Describe), "the host's pid was reused");
        Assert.IsFalse(ControlServer.DescendsFrom(99, host, Describe));
    }

    [TestMethod]
    public async Task RefusedConnectionsGetAV2ErrorAndPasswordModeNeedsALogin()
    {
        var now = new DateTime(2026, 11, 23, 12, 0, 0, DateTimeKind.Utc);
        using var server = new ControlServer((_, _) => Task.FromResult<object?>(new { pong = true })) { Password = () => "s3cret", Now = () => now };
        Task<string> Send(ControlServer.Connection connection, string method, string parameters = "{}") =>
            server.HandleLineAsync($$"""{"id":1,"method":"{{method}}","params":{{parameters}}}""", connection);
        ControlServer.Connection Connect(ControlServer.Access access) => new(_ => Task.CompletedTask) { Access = access };

        StringAssert.Contains(await Send(Connect(ControlServer.Access.Off), "system.ping"), "\"code\":\"unavailable\"");
        StringAssert.Contains(await Send(Connect(ControlServer.Access.Denied), "system.ping"), "\"code\":\"access_denied\"");

        var client = Connect(ControlServer.Access.NeedsLogin);
        StringAssert.Contains(await Send(client, "system.ping"), "\"code\":\"auth_required\"");
        StringAssert.Contains(await Send(client, "auth.login"), "\"code\":\"invalid_params\"");
        StringAssert.Contains(await Send(client, "auth.login", """{"password":"nope"}"""), "\"code\":\"auth_failed\"");
        Assert.AreEqual(1, client.Failures);
        Assert.AreEqual("""{"id":1,"ok":true,"result":{"authenticated":true}}""", await Send(client, "auth.login", """{"password":"s3cret"}"""));
        Assert.AreEqual("""{"id":1,"ok":true,"result":{"pong":true}}""", await Send(client, "system.ping"));

        // Five free failures across connections, then a lockout even for the right password.
        for (var attempt = 0; attempt < 6; attempt++) await Send(Connect(ControlServer.Access.NeedsLogin), "auth.login", """{"password":"nope"}""");
        StringAssert.Contains(await Send(Connect(ControlServer.Access.NeedsLogin), "auth.login", """{"password":"s3cret"}"""), "Too many failed attempts");
        now = now.AddSeconds(2);
        StringAssert.Contains(await Send(Connect(ControlServer.Access.NeedsLogin), "auth.login", """{"password":"s3cret"}"""), "\"authenticated\":true");

        using var unset = new ControlServer((_, _) => Task.FromResult<object?>(null)) { Password = () => null };
        StringAssert.Contains(await unset.HandleLineAsync("""{"id":1,"method":"auth.login","params":{"password":"x"}}""", Connect(ControlServer.Access.NeedsLogin)), "\"code\":\"auth_unconfigured\"");
    }
}
