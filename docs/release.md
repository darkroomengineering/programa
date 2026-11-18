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
  (titled `Programa <effective version>`, for example `Programa 0.7.573`) and marks it
  "latest". Its notes are the CHANGELOG.md section for the current major.minor above the
  generated list of merged PRs. The releases page shows exactly
  one entry, and `releases/latest/download/*` always resolves to the newest green build.
- **Candidates.** Each ship also seals a `rolling-candidate-<build>` **draft** release that
  holds the versioned DMG and EXE and the dSYMs. Drafts are invisible on the public releases
  page and to `releases/latest`, so they never add a second entry. After the candidate's
  assets are promoted into `rolling`, the reconciler keeps the five newest candidate drafts
  (`CANDIDATE_KEEP_COUNT` in `scripts/publish_rolling_release.sh`) as private rollback
  archives and deletes the older ones. Download it with
  `gh release download rolling-candidate-<build> --repo darkroomengineering/programa`
  (collaborator access required, because it is a draft).

## macOS and Windows

macOS ships independently of the Windows build. The macOS release does not wait for Windows.
The Windows executable, `programa-windows.exe`, is attached to `rolling` when its build
passes. Windows signing is described in [windows-signing.md](windows-signing.md) and the
Windows smoke test in [windows-testing.md](windows-testing.md).

## ship (shipit)

`ship.json` at the repository root describes Programa for
[shipit](https://github.com/darkroomengineering/shipit), Darkroom's release tool.

- **Programa macOS dry run in shipit.** Run the workflow from shipit's Actions tab. It
  checks out Programa's current `main` and runs `ship ci mac` without publishing.
- **`.github/workflows/ship-windows.yml`.** Builds the Windows app as a Velopack installer
  (`Programa-x64-setup.exe`) with an update feed (`releases.win.json`) from Programa's
  checkout. It runs by hand from the Actions tab (tick `dry-run` to build and pack without
  uploading) or when `ship beta windows` dispatches it. The Velopack lane builds unsigned
  and requires signing support in the lane before enabling `windows.signing`.

`ship.json` carries the same feed URL and Sparkle public key as the app; never change
either. Until shipit covers the rest, these checks stay only in `release.yml` and the
publish scripts: the run-number patch version, the CLI version memory guard, the embedded
Sparkle version and provisioning profile checks, dSYMs, build attestations, the sealed
candidate drafts and the reconciler's high-water and CI-provenance checks.

## What `rolling` carries

- `appcast.xml`
- `programa-macos.dmg`
- `programa-windows.exe` (when the Windows build passes)
- Sparkle enclosures `programa-macos-<build>.dmg` for the newest builds. The retention window
  is set in `scripts/sparkle_enclosure.js`; older enclosures are pruned after each promotion.

The appcast must point at `rolling`, not at a candidate. GitHub serves no assets from a draft,
so a candidate URL returns 404 for every auto-updating client. dSYMs and the versioned EXE
live only on the candidate draft.

The app sets `SURequireSignedFeed`, and `generate_appcast` signs the whole `appcast.xml` with
`SPARKLE_PRIVATE_KEY`. Never edit a published appcast by hand: any change breaks the feed
signature and installed apps stop updating. Regenerate it with
`scripts/sparkle_generate_appcast.sh` instead.

The README download button points at `releases/latest/download/programa-macos.dmg`.

## Required GitHub secrets

These live in the `release` environment (Settings > Environments > release), not as
repository secrets, so only the release job can read them. Add or rotate them there; a
repository secret with the same name is ignored by the release job.

| Secret | Used for |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | Developer ID certificate (base64) |
| `APPLE_CERTIFICATE_PASSWORD` | Password for that certificate |
| `APPLE_SIGNING_IDENTITY` | Signing identity name |
| `APPLE_ID` | Apple account for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
| `APPLE_TEAM_ID` | Apple team id |
| `SPARKLE_PRIVATE_KEY` | Signs the appcast and enclosures; the workflow derives the public key embedded in the app from it. The release fails without it |
| `APPLE_PROVISION_PROFILE_BASE64` | Provisioning profile embedded in the app. Kept as a safety net: no entitlement in `programa.entitlements` is Apple-restricted, so the app launches without a profile and an embedded one is harmless. If a restricted `com.apple.developer.*` entitlement is added, the profile is required, because macOS kills the app at launch without it even though signing and notarization succeed. The workflow step still fails the build when the secret is missing. Candidate for removal once a release is confirmed to launch without it |

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
