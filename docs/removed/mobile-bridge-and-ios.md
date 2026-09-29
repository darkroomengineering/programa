# Mobile Bridge and iOS companion

Removed 2026-09-02. Last present at commit 903027ccef. Restore with:
`git checkout 903027ccef -- Sources/MobileBridge ios tools/mobile-spike vendor/CmuxIrohTransport vendor/CMUXMobileCore .github/workflows/ios-build.yml .github/workflows/ios-testflight.yml scripts/build-ios-testflight.sh docs/ios-testflight-setup.md programaTests/MobileBridgeConnectionRegistryTests.swift`

The pbxproj entries, `Package.resolved` pin, and the edits listed below would
also need to be reapplied by hand; they are not a clean `git checkout`.

## What it did

Programa could pair with a companion iPhone app (`ProgramaSpike`) over a
private peer-to-peer connection built on Iroh, Apple's QUIC-based relay/hole
punching library. A Settings > Phone tab let the user turn on "Mobile
Companion" (off by default), start a single-use 5-minute pairing window, and
scan a QR code or paste a pairing code from the iPhone app. Paired phones
could see workspace/agent state and get "an agent needs you" push
notifications (via CloudKit) when a paired Mac and iPhone shared the same
iCloud account. A small allow-listed method surface (`MobileBridgeMethodAllowList`)
limited what a paired phone could ask the Mac to do, independent of the Unix
control socket's own auth. Devices could be revoked from the Paired Devices
list.

## How it was wired

- Settings key: `MobileBridgeSettings.appStorageKey`, default `.off`
  (`MobileBridgeSettings.defaultMode`).
- Settings UI: a `.phone` case on `SettingsTab` (`Sources/SettingsModels.swift`)
  and a `phoneSection` view in `Sources/SettingsView.swift` (mode picker,
  pairing button, QR code render via CoreImage, paired-device list with
  revoke).
- Start/stop hook: `ProgramaApp.swift` called `updateMobileBridgeController()`
  on launch and on `mobileBridgeMode` change, which started/stopped
  `MobileBridgeListener.shared`. `AppDelegate.applicationWillTerminate` also
  stopped it.
- Telemetry push: `Workspace+SidebarTelemetry.swift` called
  `MobileBridgePush.shared.noteAgentStateChanged(...)` on every agent state
  change/clear/reset so a paired phone got near-real-time updates.
- Socket layer: `TerminalController.SocketConnectionSource` had a
  `.mobileBridge` case with its own `mobileBridgeRequestPolicy()` (no password
  auth, since the Mobile Bridge allow-list was the gate instead).
- iOS app: `ios/ProgramaSpike` (33 files), a SwiftUI/SwiftData app with
  `BridgeConnection` (QUIC client), `PairingStore`/`SecretKeyStore` (identity),
  `CloudKitPush` (push subscription), `PathClassifier` (relay vs. direct path
  reporting), Live Activities.
- Vendored transport: `vendor/CmuxIrohTransport` and `vendor/CMUXMobileCore`,
  one-time source copies from the upstream cmux fork (see their now-deleted
  `PROVENANCE.md`), linked into the iOS project and `tools/mobile-spike` but,
  in practice never imported by that code (only `IrohLib` was).
- SPM package: `iroh-ffi` (`MOBB1001` remote package reference, `MOBB1002`
  `IrohLib` product, `MOBB1003` build file) was linked into the macOS
  `programa` target for `MobileBridgeListener`'s QUIC listener.
- CI/build: `.github/workflows/ios-build.yml`, `.github/workflows/ios-testflight.yml`,
  `scripts/build-ios-testflight.sh`, and `docs/ios-testflight-setup.md`
  (TestFlight signing/shipping for the iOS app, gated on Apple secrets that
  were never added to the repo — the lane always skipped).
- `scripts/sign-release-app.sh` re-signed a prebuilt `Iroh.framework` inside
  the macOS app bundle (the xcframework carried its own upstream signature).
- Test: `programaTests/MobileBridgeConnectionRegistryTests.swift`, plus two
  tests in `TerminalControllerSocketSecurityTests.swift` that exercised the
  `.mobileBridge` socket source directly.
- 21 Localizable.xcstrings keys (`settings.phone.*`, `settings.section.phone`,
  `settings.tab.phone`).

## Files removed and files edited

Removed:
- `Sources/MobileBridge/` (MobileBridgeSettings, MobileBridgeListener, MobileBridgePush, MobileBridgePairingCode, MobileBridgeSession, MobileBridgeStreamSupport)
- `ios/` (ProgramaSpike app, 33 files)
- `tools/mobile-spike/`
- `vendor/CmuxIrohTransport/`, `vendor/CMUXMobileCore/`
- `.github/workflows/ios-build.yml`, `.github/workflows/ios-testflight.yml`
- `scripts/build-ios-testflight.sh`
- `docs/ios-testflight-setup.md`
- `programaTests/MobileBridgeConnectionRegistryTests.swift`

Edited:
- `GhosttyTabs.xcodeproj/project.pbxproj`: removed all `MOBB0001`-`MOBB0012`
  build-file/file-reference entries, the `MOBB1001`/`MOBB1002`/`MOBB1003`
  iroh-ffi package reference/product/build-file entries, and the
  `MobileBridgeConnectionRegistryTests.swift` build-file/file-reference/group
  entries.
- `GhosttyTabs.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`:
  removed the `iroh-ffi` pin.
- `Sources/SettingsModels.swift`: removed the `.phone` case and its `title`
  branch from `SettingsTab`.
- `Sources/SettingsView.swift`: removed the `mobileBridgeMode` app-storage
  property, seven `@State` mobile-bridge-pairing properties, the `.phone`
  tab-switch case, the `refreshMobileBridgePairedDevices()` `onAppear` call,
  and the whole `phoneSection` view plus its seven private helper
  functions/computed properties.
- `Sources/ProgramaApp.swift`: removed the `mobileBridgeMode` app-storage
  property, the `updateMobileBridgeController()` call on appear and its
  `onChange(of: mobileBridgeMode)` handler, the function itself, and
  generalized the `SIGPIPE` ignore comment (the ignore itself stays — other
  sockets need it too).
- `Sources/AppDelegate.swift`: removed the `MobileBridgeListener.shared.stop()`
  call from `applicationWillTerminate`.
- `Sources/Workspace+SidebarTelemetry.swift`: removed the three
  `MobileBridgePush.shared.noteAgentStateChanged(...)` calls.
- `Sources/TerminalController.swift`: removed the `.mobileBridge` case from
  `SocketConnectionSource`, the `mobileBridgeRequestPolicy()` function, and
  the corresponding switch arm in the connection handler.
- `programaTests/TerminalControllerSocketSecurityTests.swift`: removed the two
  Mobile Bridge socket-policy tests and their `sendPingThroughMobileBridgeHandler`
  helper; the rest of the file (Unix socket auth/rotation tests) is untouched.
- `scripts/sign-release-app.sh`: removed the `Iroh.framework` re-sign step and
  its comment (the framework is no longer embedded).
- `Resources/Localizable.xcstrings`: removed 21 `settings.phone.*` /
  `settings.section.phone` / `settings.tab.phone` keys.

## What we learned

From `CHANGELOG.md` (Unreleased): the mobile bridge shipped with real
security work already landed — device-only Keychain credentials, bounded
newline framing, cancellation-safe request/pairing deadlines, settled path
selection, server-reconciled CloudKit subscriptions, a generation-owned
reconnect loop, and revoking a device also closed its active session. That
work is gone with the feature; a reimplementation should not start from
scratch on those points, it should re-port them.

Review findings from before the removal:

- the repo simultaneously called the iOS app "a spike," auto-shipped
  it to TestFlight, linked an unused transport package (`CmuxIrohTransport`),
  and kept a second executable spike (`tools/mobile-spike`) as reference code.
  The review's direction was to promote one implementation or drop
  auto-shipping — this removal takes the "drop it" branch instead of
  resolving the ambiguity.
- `BridgeConnection.withRequestTimeout` raced the operation against a
  timeout inside a structured task group, but cancelling the child neither
  removed nor resumed its `pending` continuation, and teardown only ran after
  the timeout helper returned — a silent, authenticated peer could leave the
  app on "Connecting" indefinitely.
- `BridgeConnection.nextBufferedLine` (iOS) appended unbounded 64 KiB
  chunks and rescanned from the start every time — O(n^2) and unbounded
  memory for a peer that never sends `\n`. The Mac-side
  `MobileBridgeStreamSupport` had an 8 MiB cap and incremental cursor that the
  iOS side never got ported to.
- the shipped mobile identity was explicitly labeled "spike-grade" in
  its own source comments — `SecretKeyStore` kept the Iroh private key in
  UserDefaults, and `PairingStore` did the same for the pairing ticket,
  instead of Keychain with a device-only accessibility class.
- iOS reported the first non-unavailable network path as final instead
  of waiting for Iroh's relay-first settlement to resolve to a direct/private
  path, so users could see "connected" over a slow relay hop that would soon
  upgrade.
- `build-ios-testflight.sh` replaced the entire keychain search list
  with a fixed `ios-build.keychain` and had no EXIT trap, so a local
  (non-CI) run could leave a developer's normal keychains undiscoverable.
- both the iOS project and `tools/mobile-spike` declared a link
  dependency on `CmuxIrohTransport` but their source only imported `IrohLib`
  directly — the vendored package was dead weight, and the hand-copied
  implementations had already drifted from it on path settlement and line
  bounds.

`vendor/CmuxIrohTransport/PROVENANCE.md` and `vendor/CMUXMobileCore/PROVENANCE.md`
recorded these as one-time source copies from the upstream cmux fork
(`Packages/Shared/CmuxIrohTransport` and `Packages/Shared/CMUXMobileCore` at
commit `34cc2ba5110adf45c27607e865be5867fbcad8a9`), with no live tracking
after extraction, citing a 4,706-commit divergence from upstream and a risk
that upstream commits would reintroduce account/broker coupling this fork
deliberately removed. `tools/mobile-spike/README.md` said the completed
executable spike and its direct `iroh-ffi` dependency had already been
removed once before, with the framer kept only as reference — the production
transport had moved to `ios/ProgramaSpike`.

`docs/ios-testflight-setup.md` (read before deletion) documented that the
TestFlight CI lane was fully written and verified but permanently skipping
every run because none of the seven required Apple signing secrets were ever
added to the repo. Setup required careful ordering (iCloud container and Push
capability before minting provisioning profiles, since a profile bakes in
capabilities at creation time) and named three App IDs that must never be
deleted if the feature returns: `com.darkroom.programa`,
`com.darkroom.programa.spike`, `com.darkroom.programa.spike.widgets`.

## Why removed and what a future version should do differently

The feature was off by default, had zero consumers in the terminal/workspace/
browser core, and the review findings above show it
never graduated past spike quality on security or reliability despite
auto-shipping to TestFlight. Keeping an unfinished second client surface (iOS)
plus a vendored, partially-unused transport dependency (Iroh/CmuxIrohTransport)
added real build and review surface for a feature nobody outside the review was
using.

A future version should pick one implementation up front instead of running
spike and "production" copies in parallel: port `MobileBridgeStreamSupport`'s
bounded reader and the Mac-side pairing/registry logic into the iOS client
rather than re-deriving it, put the Iroh identity and pairing ticket in
Keychain from the start, fix request-timeout cancellation before any pairing
flow ships, and treat TestFlight auto-shipping as a deliberate go-live
decision — not a default CI lane that silently skips for months because
secrets were never added.
