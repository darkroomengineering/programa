# Proxy Support

How proxy behavior works for cmux browser automation.

**Related**: [commands.md](commands.md), [SKILL.md](../SKILL.md)

## Contents

- [User-Configured Proxy (browser.proxy)](#user-configured-proxy-browserproxy)
- [Remote Relay Proxy (precedence)](#remote-relay-proxy-precedence)
- [What Is Not Exposed via CLI](#what-is-not-exposed-via-cli)
- [Verification](#verification)

## User-Configured Proxy (browser.proxy)

Add a `browser.proxy` block to `~/.config/cmux/settings.json` (or the path shown in Settings > General) to route all embedded WebView traffic through a proxy:

```json
{
  "browser": {
    "proxy": {
      "host": "127.0.0.1",
      "port": 1080,
      "type": "socks5"
    }
  }
}
```

### Properties

| Key    | Type    | Required | Description |
|--------|---------|----------|-------------|
| `host` | string  | yes      | Proxy host name or IP address. |
| `port` | integer | yes      | Port number (1–65535). |
| `type` | string  | no       | `"socks5"` (default) or `"httpConnect"`. |

- `"socks5"` — SOCKSv5 proxy (`ProxyConfiguration(socksv5Proxy:)`).
- `"httpConnect"` — HTTP CONNECT tunneling (`ProxyConfiguration(httpCONNECTProxy:)`).

Config-file only this release; no Settings UI panel.

### Relay Precedence

When a remote workspace relay endpoint is active, the relay proxy always wins — the user-configured proxy is ignored until the relay disconnects. This preserves SSH-relay browser routing for remote workspaces.

## Remote Relay Proxy (precedence)

Remote browser panels use an SSH relay. When the relay endpoint is set via `setRemoteProxyEndpoint(_:)`, `WKWebsiteDataStore.proxyConfigurations` is populated with both SOCKSv5 and HTTP CONNECT entries pointing at the relay. The user proxy is not applied while the relay is active.

When the relay endpoint is cleared, the user proxy (if configured) is applied; otherwise `proxyConfigurations` is reset to `[]`.

## What Is Not Exposed via CLI

There is no first-class `cmux browser proxy ...` socket command for per-surface proxy routing. `browser.proxy` is config-file only.

## Verification

```bash
cmux browser open https://httpbin.org/ip --json
cmux browser surface:7 get text body
```

Compare the returned IP against your expected proxy egress address.
