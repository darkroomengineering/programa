"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// This asserts the *structure* of .github/workflows/release.yml's build-windows job (step
// names, guards, and ordering), the same way release_asset_guard.test.js and
// release_build_identity.test.js assert the behavior of their modules — here there is no
// standalone module, so the workflow file itself is the contract under test. It is a text
// assertion, not a YAML-semantic one: it exists to catch accidental reordering or an
// unguarded signing step, not to replace running the workflow.

const releaseWorkflowPath = path.join(__dirname, "..", ".github", "workflows", "release.yml");
const ciWorkflowPath = path.join(__dirname, "..", ".github", "workflows", "ci.yml");

function readWorkflow(workflowPath) {
  return fs.readFileSync(workflowPath, "utf8");
}

function extractJob(workflowText, jobName) {
  const jobHeader = new RegExp(`^  ${jobName}:\\n`, "m");
  const start = workflowText.search(jobHeader);
  assert.notEqual(start, -1, `expected to find job '${jobName}' in the workflow`);
  const rest = workflowText.slice(start + jobHeader.exec(workflowText.slice(start))[0].length);
  const nextJobMatch = rest.match(/^  [A-Za-z0-9_-]+:\n/m);
  return nextJobMatch ? rest.slice(0, nextJobMatch.index) : rest;
}

test("release.yml build-windows job signs before the byte-identical copies are verified, guarded by TRUSTED_SIGNING_ACCOUNT", () => {
  const job = extractJob(readWorkflow(releaseWorkflowPath), "build-windows");

  const stepOrder = [
    "Azure login for Windows executable signing",
    "Prepare Windows executable signing script",
    "Build Windows executable",
    "Attest Windows release payloads",
    "Upload Windows release payload",
  ];
  const positions = stepOrder.map((name) => {
    const index = job.indexOf(`name: ${name}`);
    assert.notEqual(index, -1, `expected step '${name}' in the build-windows job`);
    return index;
  });
  for (let i = 1; i < positions.length; i += 1) {
    assert.ok(
      positions[i] > positions[i - 1],
      `expected '${stepOrder[i]}' to come after '${stepOrder[i - 1]}' in build-windows`,
    );
  }

  // Both signing-preparation steps must be guarded, so the lane keeps shipping unsigned
  // until the Azure setup in docs/windows-signing.md is done.
  const guard = "if: ${{ vars.TRUSTED_SIGNING_ACCOUNT != '' }}";
  for (const name of ["Azure login for Windows executable signing", "Prepare Windows executable signing script"]) {
    const stepStart = job.indexOf(`name: ${name}`);
    const nextStepStart = job.indexOf("- name:", stepStart + 1);
    const stepBody = job.slice(stepStart, nextStepStart === -1 ? undefined : nextStepStart);
    assert.ok(stepBody.includes(guard), `expected '${name}' to be guarded by ${guard}`);
  }

  // The signing script must be handed to build-windows.ps1 before it runs, not after.
  const signScriptEnvIndex = job.indexOf("PROGRAMA_WINDOWS_SIGN_SCRIPT=");
  const buildStepIndex = job.indexOf("name: Build Windows executable");
  assert.notEqual(signScriptEnvIndex, -1, "expected PROGRAMA_WINDOWS_SIGN_SCRIPT to be exported");
  assert.ok(signScriptEnvIndex < buildStepIndex, "expected the signing script to be prepared before the build step runs");

  // id-token is required for azure/login's OIDC federated auth; contents stays read-only.
  assert.match(job, /permissions:\s*\n(?:\s+\S.*\n)*?\s+id-token: write/);
  assert.match(job, /permissions:\s*\n(?:\s+\S.*\n)*?\s+contents: read/);
});

test("build-windows.ps1 exposes the signing hook release.yml relies on", () => {
  const script = fs.readFileSync(path.join(__dirname, "build-windows.ps1"), "utf8");

  assert.match(script, /function Invoke-ProgramaWindowsSigning/);
  assert.match(script, /\$env:PROGRAMA_WINDOWS_SIGN_SCRIPT/);

  // The signing call and its ordering relative to the byte-identical copies.
  const signCallIndex = script.indexOf("Invoke-ProgramaWindowsSigning -ExecutablePath");
  const rollingCopyIndex = script.indexOf("Copy-Item -LiteralPath $BuiltExecutable -Destination $RollingExecutable");
  assert.notEqual(signCallIndex, -1, "expected build-windows.ps1 to call Invoke-ProgramaWindowsSigning");
  assert.notEqual(rollingCopyIndex, -1, "expected build-windows.ps1 to copy the built exe to the rolling name");
  assert.ok(signCallIndex < rollingCopyIndex, "signing must run before the rolling/archived copies are written");

  // Skipped, not failed, when unsigned.
  assert.match(script, /Unsigned build: no signing script configured/);
  assert.match(script, /Unsigned build: skipping Authenticode verification/);
  assert.match(script, /Get-AuthenticodeSignature/);

  // Regression: Invoke-ProgramaWindowsSigning's body must not use Write-Output. In
  // PowerShell, unsuppressed pipeline output inside a function is appended to that
  // function's return value, so a Write-Output call before `return $false` turns
  // `$SigningPerformed = Invoke-ProgramaWindowsSigning ...` into a truthy 2-element array
  // even on the unsigned path — this broke ci.yml's windows-build job, which always
  // takes the unsigned path, by running (and failing) the post-copy signature check.
  const functionStart = script.indexOf("function Invoke-ProgramaWindowsSigning");
  const functionEnd = script.indexOf("\ntry {", functionStart);
  assert.notEqual(functionStart, -1);
  assert.notEqual(functionEnd, -1);
  const functionBody = script.slice(functionStart, functionEnd);
  const functionCodeLines = functionBody.split("\n").filter((line) => !line.trim().startsWith("#"));
  assert.ok(
    !functionCodeLines.some((line) => line.includes("Write-Output")),
    "Invoke-ProgramaWindowsSigning must use Write-Host, not Write-Output, for its messages",
  );
});

test("ci.yml windows-build job does not sign (PR builds must not sign)", () => {
  const job = extractJob(readWorkflow(ciWorkflowPath), "windows-build");
  assert.ok(!job.includes("azure/login"), "ci.yml windows-build must not attempt Azure auth");
  assert.ok(!job.includes("TRUSTED_SIGNING"), "ci.yml windows-build must not reference Trusted Signing configuration");
});
