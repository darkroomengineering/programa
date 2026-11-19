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
    public void EachBuildHasItsOwnPipe()
    {
        StringAssert.StartsWith(ControlServer.PipePath, @"\\.\pipe\programa-");
        StringAssert.EndsWith(ControlServer.PipePath, Environment.UserName);
    }
}
