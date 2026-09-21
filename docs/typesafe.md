# TypeSafe Jev credentials

Programa can discover and store a Jev API key without putting the key in `settings.json`. This credential-only phase does not call TypeSafe, send network requests, or run inference.

On macOS, open **Settings → Automation** and use the Jev API Key controls in the **Agents** section. Programa does not read the Keychain when Settings opens; choose **Check Credential Source** when you want to check, which may ask for Keychain access. On Windows, open **Settings** and use the **TypeSafe Jev** block. Programa stores saved keys in the current user's macOS Keychain or Windows Credential Manager. Debug builds use a separate credential identity, so they do not replace the release app's key.

When no saved key exists, Programa can use `TYPESAFE_API_KEY` inherited from its launch environment. Environment discovery is enabled by default and can be disabled in Settings. Programa does not source shell configuration files or search the home directory for credentials.

Credential precedence is:

1. Saved key
2. Inherited `TYPESAFE_API_KEY`, when environment discovery is enabled
3. Not configured

If secure storage cannot be read, Programa reports that storage is unavailable and does not fall back to the environment. Removing a saved key may reactivate an inherited `TYPESAFE_API_KEY`.

Programa only validates the key's local shape before saving it. The status in Settings describes where a usable credential was found; it does not claim that the key has been accepted by TypeSafe.
