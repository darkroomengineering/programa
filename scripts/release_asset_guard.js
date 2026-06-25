"use strict";

const IMMUTABLE_RELEASE_ASSETS = [
  "programa-macos.dmg",
  "appcast.xml",
  "programad-remote-darwin-arm64",
  "programad-remote-darwin-amd64",
  "programad-remote-linux-arm64",
  "programad-remote-linux-amd64",
  "programad-remote-checksums.txt",
  "programad-remote-manifest.json",
];
const RELEASE_ASSET_GUARD_STATE = Object.freeze({
  CLEAR: "clear",
  PARTIAL: "partial",
  COMPLETE: "complete",
});

function evaluateReleaseAssetGuard({ existingAssetNames, immutableAssetNames = IMMUTABLE_RELEASE_ASSETS }) {
  const immutableAssets = immutableAssetNames || IMMUTABLE_RELEASE_ASSETS;
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
  evaluateReleaseAssetGuard,
};
