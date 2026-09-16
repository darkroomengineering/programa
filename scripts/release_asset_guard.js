"use strict";

const IMMUTABLE_RELEASE_ASSETS = [
  "programa-macos.dmg",
  "programa-windows.exe",
  "appcast.xml",
];
const RELEASE_ASSET_GUARD_STATE = Object.freeze({
  CLEAR: "clear",
  PARTIAL: "partial",
  COMPLETE: "complete",
});

// The Sparkle enclosure asset name embeds the build number, so it cannot live in the
// static list above — but it IS immutable, and a release whose appcast points at a DMG
// that was never uploaded is a broken release that a rerun would otherwise declare
// "complete" and skip. Read the required name out of the published appcast instead.
function enclosureAssetFromAppcast(appcastXml) {
  if (typeof appcastXml !== "string") return null;
  // Anchored to the <enclosure> element: a bare url= match would also accept a
  // <link>/<sparkle:releaseNotesLink> that happens to name a dmg, letting a malformed
  // appcast pass the guard while its actual enclosure is unversioned or missing.
  const match = appcastXml.match(/<enclosure\b[^>]*?\burl="[^"]*?\/(programa-macos-\d+\.dmg)"/);
  return match ? match[1] : null;
}

function evaluateReleaseAssetGuard({
  existingAssetNames,
  immutableAssetNames = IMMUTABLE_RELEASE_ASSETS,
  appcastXml = null,
}) {
  const baseAssets = immutableAssetNames || IMMUTABLE_RELEASE_ASSETS;
  const requiredEnclosure = enclosureAssetFromAppcast(appcastXml);
  const immutableAssets =
    requiredEnclosure && !baseAssets.includes(requiredEnclosure)
      ? [...baseAssets, requiredEnclosure]
      : baseAssets;
  const existing = new Set(existingAssetNames || []);
  const conflicts = immutableAssets.filter((assetName) => existing.has(assetName));
  const missingImmutableAssets = immutableAssets.filter((assetName) => !existing.has(assetName));

  let guardState = RELEASE_ASSET_GUARD_STATE.CLEAR;
  if (conflicts.length === immutableAssets.length && immutableAssets.length > 0) {
    guardState = RELEASE_ASSET_GUARD_STATE.COMPLETE;
  } else if (conflicts.length > 0) {
    guardState = RELEASE_ASSET_GUARD_STATE.PARTIAL;
  }

  return {
    conflicts,
    missingImmutableAssets,
    guardState,
    hasPartialConflict: guardState === RELEASE_ASSET_GUARD_STATE.PARTIAL,
    shouldSkipBuildAndUpload: guardState === RELEASE_ASSET_GUARD_STATE.COMPLETE,
    shouldSkipUpload: guardState === RELEASE_ASSET_GUARD_STATE.COMPLETE,
  };
}

module.exports = {
  IMMUTABLE_RELEASE_ASSETS,
  RELEASE_ASSET_GUARD_STATE,
  enclosureAssetFromAppcast,
  evaluateReleaseAssetGuard,
};
