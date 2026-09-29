# Releasing Programa

Every commit on `main` that passes the `CI` workflow ships automatically. There is no
nightly or beta channel. If something ships broken, fix it forward on `main`; the next green
CI run ships the fix.

## How a ship works

`.github/workflows/release.yml` runs when `CI` completes successfully on `main`
(`workflow_run`, `conclusion: success`). It builds, signs, notarizes and publishes the macOS
app.

- **Version.** The user-visible version is the committed major.minor with the patch replaced
  by the workflow run number, for example `0.4.213`. Every ship is distinguishable in the
  About box and on the releases page.
- **Build number.** The build number (`CFBundleVersion`) is derived from the GitHub run id
  by `scripts/release_build_identity.js`. This gives one strictly increasing sequence for the
  Sparkle feed. The `CURRENT_PROJECT_VERSION` committed in the Xcode project is a local
  development default only. Shipping ignores it.
- **Injection.** Both values are written into `Info.plist` at build time and never committed.
- **The `rolling` release.** Each ship overwrites a single GitHub release named `rolling`
  (titled with the effective version) and marks it "latest". The releases page shows exactly
  one entry, and `releases/latest/download/*` always resolves to the newest green build.
- **Candidates.** Each ship also seals a `rolling-candidate-<build>` **draft** release that
  holds the versioned DMG and EXE and the dSYMs. Drafts are invisible on the public releases
  page and to `releases/latest`, so they never add a second entry. After the candidate's
  assets are promoted into `rolling`, the reconciler deletes every older candidate draft and
  keeps only the newest as a private rollback archive. Download it with
  `gh release download rolling-candidate-<build> --repo darkroomengineering/programa`
  (collaborator access required, because it is a draft).

## macOS and Windows

macOS ships independently of the Windows build. The macOS release does not wait for Windows.
The Windows executable, `programa-windows.exe`, is attached to `rolling` when its build
passes. Windows signing is described in [windows-signing.md](windows-signing.md) and the
Windows smoke test in [windows-testing.md](windows-testing.md).

## What `rolling` carries

- `appcast.xml`
- `programa-macos.dmg`
- `programa-windows.exe` (when the Windows build passes)
- Sparkle enclosures `programa-macos-<build>.dmg` for the newest builds. The retention window
  is set in `scripts/sparkle_enclosure.js`; older enclosures are pruned after each promotion.

The appcast must point at `rolling`, not at a candidate. GitHub serves no assets from a draft,
so a candidate URL returns 404 for every auto-updating client. dSYMs and the versioned EXE
live only on the candidate draft.

The README download button points at `releases/latest/download/programa-macos.dmg`.

## Required GitHub secrets

| Secret | Used for |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | Developer ID certificate (base64) |
| `APPLE_CERTIFICATE_PASSWORD` | Password for that certificate |
| `APPLE_SIGNING_IDENTITY` | Signing identity name |
| `APPLE_ID` | Apple account for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
| `APPLE_TEAM_ID` | Apple team id |
| `SPARKLE_PRIVATE_KEY` | Signs the appcast and enclosures; the workflow derives the public key embedded in the app from it. The release fails without it |
| `APPLE_PROVISION_PROFILE_BASE64` | Provisioning profile embedded in the app. Required: the app declares restricted entitlements (CloudKit), and without an embedded profile macOS kills it at launch even though signing and notarization succeed. The profile verification step fails the build when the secret is missing |

## Milestone version bumps

A milestone bump (for example `0.15.0` to `0.16.0`) changes the committed major.minor. It
does not create a GitHub release. Bump, update the changelog, and let the next ship pick up
the new major.minor:

```bash
./scripts/bump-version.sh          # bump minor (0.15.0 -> 0.16.0)
./scripts/bump-version.sh patch    # bump patch (0.15.0 -> 0.15.1)
./scripts/bump-version.sh major    # bump major (0.15.0 -> 1.0.0)
./scripts/bump-version.sh 1.0.0    # set a specific version
```

The script updates `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project.
Only the marketing version matters for shipping (its major.minor part). Then update
`CHANGELOG.md`, which is the source of truth for the changelog, commit, and optionally tag:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

The tag is a marker in `git log` and `git tag`. It does not trigger a build or a release.
Bump the minor version for milestone tags unless asked otherwise.

## Dry runs

Running `release.yml` with `workflow_dispatch` performs a dry-run build that uploads an
artifact instead of publishing.
