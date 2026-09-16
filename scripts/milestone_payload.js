"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const { validateReleasePayloadReferences } = require("./rolling_release_state");

const MANIFEST_NAME = "programa-milestone-payload.json";
const CANONICAL_BUILD = /^[1-9][0-9]*$/;
const SHA256 = /^[0-9a-f]{64}$/;
const MAX_SAFE_SIZE = BigInt(Number.MAX_SAFE_INTEGER);

function assertBuild(build) {
  if (typeof build !== "string" || !CANONICAL_BUILD.test(build)) {
    throw new TypeError("milestone build must be a canonical positive decimal string");
  }
}

function payloadNames(build) {
  assertBuild(build);
  return [
    "appcast.xml",
    `programa-dSYMs-${build}.zip`,
    `programa-macos-${build}.dmg`,
    `programa-windows-${build}.exe`,
    "programa-macos.dmg",
    "programa-windows.exe",
  ];
}

function assertExactFields(value, expected, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${label} must be an object`);
  }
  const keys = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (keys.length !== wanted.length || keys.some((key, index) => key !== wanted[index])) {
    throw new TypeError(`${label} fields must be exactly: ${expected.join(", ")}`);
  }
}

function resolveDirectory(directory) {
  if (typeof directory !== "string" || directory === "") {
    throw new TypeError("milestone payload directory is required");
  }
  const resolved = path.resolve(directory);
  const stat = fs.lstatSync(resolved);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new TypeError("milestone payload path must be a real directory");
  }
  return resolved;
}

function assertExactDirectory(directory, expectedNames) {
  const actual = fs.readdirSync(directory).sort();
  const expected = [...expectedNames].sort();
  if (actual.length !== expected.length || actual.some((name, index) => name !== expected[index])) {
    const extra = actual.filter((name) => !expected.includes(name));
    const missing = expected.filter((name) => !actual.includes(name));
    throw new TypeError(
      `milestone payload directory must contain exactly the expected files; ` +
        `missing: ${missing.join(", ") || "none"}; unexpected: ${extra.join(", ") || "none"}`,
    );
  }
}

function inspectFile(directory, name) {
  if (path.basename(name) !== name || name === "." || name === "..") {
    throw new TypeError(`milestone payload name is unsafe: ${name}`);
  }
  const filePath = path.join(directory, name);
  const stat = fs.lstatSync(filePath, { bigint: true });
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new TypeError(`milestone payload must be a regular file: ${name}`);
  }
  if (stat.size <= 0n) throw new TypeError(`milestone payload must be nonempty: ${name}`);
  if (stat.size > MAX_SAFE_SIZE) {
    throw new TypeError(`milestone payload size exceeds the safe integer range: ${name}`);
  }
  const bytes = fs.readFileSync(filePath);
  return {
    name,
    size: Number(stat.size),
    sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
  };
}

function createMilestoneManifest({ directory, build }) {
  const names = payloadNames(build);
  const resolved = resolveDirectory(directory);
  assertExactDirectory(resolved, names);
  return {
    schemaVersion: 2,
    build,
    files: names.map((name) => inspectFile(resolved, name)),
  };
}

function writeMilestoneManifest({ directory, build }) {
  const resolved = resolveDirectory(directory);
  const manifest = createMilestoneManifest({ directory: resolved, build });
  fs.writeFileSync(
    path.join(resolved, MANIFEST_NAME),
    `${JSON.stringify(manifest)}\n`,
    { mode: 0o600 },
  );
  return manifest;
}

function verifyMilestonePayload({ directory, build }) {
  const names = payloadNames(build);
  const resolved = resolveDirectory(directory);
  assertExactDirectory(resolved, [...names, MANIFEST_NAME]);

  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(path.join(resolved, MANIFEST_NAME), "utf8"));
  } catch (error) {
    throw new TypeError("milestone payload manifest is not valid JSON", { cause: error });
  }
  assertExactFields(manifest, ["schemaVersion", "build", "files"], "milestone manifest");
  if (manifest.schemaVersion !== 2) throw new TypeError("milestone manifest schemaVersion must be 2");
  if (manifest.build !== build) throw new TypeError("milestone manifest build does not match");
  if (!Array.isArray(manifest.files) || manifest.files.length !== names.length) {
    throw new TypeError("milestone manifest must contain exactly six files");
  }

  const normalizedFiles = manifest.files.map((file, index) => {
    assertExactFields(file, ["name", "size", "sha256"], `milestone manifest file ${index}`);
    if (file.name !== names[index] || path.basename(file.name) !== file.name) {
      throw new TypeError(`milestone manifest file ${index} has an unsafe or unexpected name`);
    }
    if (!Number.isSafeInteger(file.size) || file.size <= 0) {
      throw new TypeError(`milestone manifest file ${file.name} has an invalid size`);
    }
    if (typeof file.sha256 !== "string" || !SHA256.test(file.sha256)) {
      throw new TypeError(`milestone manifest file ${file.name} has an invalid sha256`);
    }
    const observed = inspectFile(resolved, file.name);
    if (observed.size !== file.size || observed.sha256 !== file.sha256) {
      throw new TypeError(`milestone payload bytes do not match manifest: ${file.name}`);
    }
    return observed;
  });

  return { schemaVersion: 2, build, files: normalizedFiles };
}

function validateMilestonePayloadReferences({ directory, build, repository, tag, version }) {
  const payload = verifyMilestonePayload({ directory, build });
  if (typeof version !== "string" || tag !== `v${version}`) {
    throw new TypeError("milestone version must exactly match its destination tag");
  }
  const assets = payload.files.map((file) => ({
    ...file,
    role:
      file.name === "appcast.xml"
        ? "appcast"
        : file.name === "programa-macos.dmg" || file.name === "programa-windows.exe"
          ? "stable-alias"
          : "immutable",
  }));
  return validateReleasePayloadReferences({
    appcastXml: fs.readFileSync(path.join(directory, "appcast.xml"), "utf8"),
    repository,
    tag,
    manifest: {
      schemaVersion: 2,
      sealed: true,
      targetSha: "0".repeat(40),
      version,
      build,
      assets,
    },
  });
}

module.exports = {
  createMilestoneManifest,
  validateMilestonePayloadReferences,
  verifyMilestonePayload,
  writeMilestoneManifest,
};
