# Signing the Windows build

Today `programa-windows.exe` ships unsigned, so Windows SmartScreen shows "Windows
protected your PC" / "Unknown publisher" the first time someone runs it. Signing it with
a Microsoft-issued certificate removes that warning (SmartScreen still needs a period of
real downloads on the signed certificate before its reputation score fully clears — see
"SmartScreen reputation" below).

We sign with **Azure Trusted Signing**. Microsoft renamed this service **Azure Artifact
Signing** in January 2026 — same product, same portal blade, new name — so the Azure
portal and current docs say "Artifact Signing." This doc keeps saying "Trusted Signing"
for the GitHub variable names, since that's what the team already agreed on.

The signing step in CI is guarded: it only runs once the account below exists and the six
values are set as repository variables. Until then, `main` keeps shipping unsigned exactly
as it does today — nothing breaks by merging this.

## One-time Azure setup

Do this once, in the Azure Portal, as someone with Owner/Contributor on the subscription:

1. **Register the resource provider** (first time only): in the portal, go to
   Subscriptions → your subscription → Resource providers, search for
   `Microsoft.CodeSigning`, and select Register.
2. **Create a Trusted Signing (Artifact Signing) account.** Portal search: "Trusted
   Signing" or "Artifact Signing". Pick a region that's currently supported for account
   creation — the quickstart lists the supported regions (East US, East US 2, West US,
   West US 2, West US 3, South Central US as of the September 2026 doc). Note the
   **endpoint URL** the portal shows after creation, e.g.
   `https://eus.codesigning.azure.net/` — that's `TRUSTED_SIGNING_ENDPOINT` below.
3. **Complete identity validation for Darkroom Engineering.** On the account, go to
   Identity validation → Add identity validation → Organization. This needs a D-U-N-S
   number (or Microsoft will help you get one) and generally takes a few business days.
   You can create the certificate profile before this finishes, but nothing can be signed
   until validation completes.
4. **Create a certificate profile of type Public Trust**, tied to the validated
   organization identity. Note its name — that's `TRUSTED_SIGNING_PROFILE` below.
5. **Create an Entra app registration** for GitHub Actions to authenticate as (Entra ID →
   App registrations → New registration; no client secret needed, we use OIDC). Note its
   **Application (client) ID** and your **Directory (tenant) ID** from the app's Overview
   page.
6. **Add a federated credential** on that app registration (Certificates & secrets →
   Federated credentials → Add credential → GitHub Actions deploying Azure resources):
   - Organization: `darkroomengineering`, Repository: `programa`
   - Entity type: **Branch**, value `main` (this is what lets only pushes that land on
     `main` — i.e. real ships — authenticate; a fork or a PR branch can't get a token)
   - If the release job runs under a GitHub Environment, add a second federated
     credential with Entity type **Environment** for that environment name instead of, or
     in addition to, the branch one.
7. **Assign the app the "Trusted Signing Certificate Profile Signer" role** on the Trusted
   Signing account (account → Access control (IAM) → Add role assignment → search for that
   role → assign to the app registration by name).
8. **Note your subscription ID** (Subscriptions blade, or the app registration's overview
   won't show it — copy it from the subscription itself).

## GitHub repository variables

Set these as **repository variables** (Settings → Secrets and variables → Actions →
Variables), not secrets — none of them are secret material, since OIDC means no client
secret ever leaves Azure:

| Variable | Value |
|---|---|
| `AZURE_TENANT_ID` | Directory (tenant) ID from step 5 |
| `AZURE_CLIENT_ID` | Application (client) ID from step 5 |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID from step 8 |
| `TRUSTED_SIGNING_ENDPOINT` | Account endpoint URL from step 2 |
| `TRUSTED_SIGNING_ACCOUNT` | Trusted Signing account name from step 2 |
| `TRUSTED_SIGNING_PROFILE` | Certificate profile name from step 4 |

The release workflow checks `vars.TRUSTED_SIGNING_ACCOUNT` to decide whether to sign at
all, so setting all six is what turns signing on. Leave any of them unset and the build
stays unsigned with no error.

## Cost

Trusted/Artifact Signing bills per signing certificate issued, not per build. As of this
writing the Basic tier is about $9.99/month per identity and covers a generous number of
signs (low thousands) per month, which is far more than our release cadence needs — see
the pricing page linked below for current numbers before budgeting, since Azure pricing
changes independently of this doc.

## SmartScreen reputation after signing

Signing removes the "Unknown publisher" line and shows Darkroom Engineering's validated
name instead, but SmartScreen's own reputation score for a *specific file* still needs
real-world download and execution telemetry before it stops showing any interstitial at
all — this can take some number of signed releases with real downloads before it fully
clears, and each new build gets a new short-lived certificate (that's how Trusted/Artifact
Signing works), so reputation is closer to "per publisher" than "per exact file" and
should improve steadily as we keep shipping signed builds, not reset to zero every ship.

## What we sign with, and why not the marketplace GitHub Action

Microsoft publishes `azure/trusted-signing-action` (now deprecated in favor of
`azure/artifact-signing-action`) as a `uses:` step for this. We don't use it here: it's a
composite action, so it can only run as its own workflow step, signing files that already
exist on disk. Our build script (`scripts/build-windows.ps1`) produces the release exe and
then makes two byte-identical copies of it (`programa-windows.exe` and
`programa-windows-<build>.exe`) that a later step verifies are identical via SHA-256. Each
Trusted/Artifact Signing call issues a fresh short-lived certificate and RFC 3161
timestamp, so signing the two copies separately — which is what a post-copy `uses:` step
would do — makes them diverge and fails that check.

Instead we sign the single published exe *before* the copy happens, from inside
`build-windows.ps1` itself, using Microsoft's official [`dotnet sign` CLI]
(https://github.com/dotnet/sign) (`sign code artifact-signing`), authenticated against the
`az` CLI session that `azure/login` establishes via OIDC in the same job. This is the same
signing backend the marketplace action wraps, just invoked at the one point in the
pipeline where signing-then-copying is possible instead of copying-then-signing-twice.

## Sources read for this doc

- [Quickstart: Set up Trusted Signing](https://learn.microsoft.com/en-us/azure/trusted-signing/quickstart) (Microsoft Learn)
- [What is Artifact Signing?](https://learn.microsoft.com/en-us/azure/artifact-signing/overview) and its [Quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart) (the renamed service, Jan 2026)
- [Artifact Signing FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq)
- [`azure/artifact-signing-action`](https://github.com/Azure/artifact-signing-action) `action.yml` (successor to `azure/trusted-signing-action`) — read directly from the pinned commit to confirm every input name
- [`azure/login`](https://github.com/Azure/login) usage with `client-id`/`tenant-id`/`subscription-id` OIDC federated auth
- [`dotnet/sign`](https://github.com/dotnet/sign) — `docs/artifact-signing-integration.md`, `docs/gh-build-and-sign.yml`, and `src/Sign.Cli/ArtifactSigningCommand.cs`/`CodeCommand.cs`/`AzureCredentialOptions.cs` for the exact `sign code artifact-signing` flags and the `--azure-credential-type azure-cli` OIDC-via-az-CLI path
