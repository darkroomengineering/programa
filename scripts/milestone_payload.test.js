"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

// Public contract for scripts/milestone_payload.js:
//
//   createMilestoneManifest({ directory, build }) -> manifest
//   writeMilestoneManifest({ directory, build }) -> manifest
//   verifyMilestonePayload({ directory, build }) -> manifest
//
// The manifest is `{ schemaVersion: 2, build, files }`, where `files` is the
// deterministic list of exactly six milestone assets as
// `{ name, size, sha256 }`. The written filename is
// `programa-milestone-payload.json`. Verification requires exactly those six
// payloads plus that manifest, validates its exact JSON schema, and hashes the
// downloaded bytes rather than trusting metadata.
const {
  createMilestoneManifest,
  verifyMilestonePayload,
  writeMilestoneManifest,
} = require("./milestone_payload");

const BUILD = "900719925474099312345678901234567890";
const MANIFEST_NAME = "programa-milestone-payload.json";

function expectedNames(build = BUILD) {
  return [
    "appcast.xml",
    `programa-dSYMs-${build}.zip`,
    `programa-macos-${build}.dmg`,
    `programa-windows-${build}.exe`,
    "programa-macos.dmg",
    "programa-windows.exe",
  ];
}

function fixture(t, build = BUILD) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "programa-milestone-payload-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  for (const [index, name] of expectedNames(build).entries()) {
    fs.writeFileSync(path.join(directory, name), `payload-${index}-${name}\n`);
  }
  return directory;
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

test("manifest creation records the exact six milestone files and their bytes", (t) => {
  const directory = fixture(t);
  const manifest = createMilestoneManifest({ directory, build: BUILD });

  assert.deepEqual(Object.keys(manifest).sort(), ["build", "files", "schemaVersion"]);
  assert.equal(manifest.schemaVersion, 2);
  assert.equal(manifest.build, BUILD);
  assert.deepEqual(manifest.files.map((file) => file.name), expectedNames());
  for (const file of manifest.files) {
    const bytes = fs.readFileSync(path.join(directory, file.name));
    assert.deepEqual(Object.keys(file).sort(), ["name", "sha256", "size"]);
    assert.equal(file.size, bytes.length);
    assert.equal(file.sha256, sha256(bytes));
  }
});

test("a written manifest verifies an exact downloaded payload directory", (t) => {
  const directory = fixture(t);
  const written = writeMilestoneManifest({ directory, build: BUILD });
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, MANIFEST_NAME), "utf8")), written);
  assert.deepEqual(verifyMilestonePayload({ directory, build: BUILD }), written);
});

test("creation rejects incomplete, extra, empty, and wrong-build payload sets", async (t) => {
  await t.test("missing", (t) => {
    const directory = fixture(t);
    fs.rmSync(path.join(directory, expectedNames()[0]));
    assert.throws(() => createMilestoneManifest({ directory, build: BUILD }), /missing|exactly|payload/i);
  });
  await t.test("extra", (t) => {
    const directory = fixture(t);
    fs.writeFileSync(path.join(directory, "unexpected.bin"), "extra");
    assert.throws(() => createMilestoneManifest({ directory, build: BUILD }), /extra|unexpected|exactly/i);
  });
  await t.test("empty", (t) => {
    const directory = fixture(t);
    fs.writeFileSync(path.join(directory, expectedNames()[2]), "");
    assert.throws(() => createMilestoneManifest({ directory, build: BUILD }), /empty|size|positive/i);
  });
  await t.test("wrong build", (t) => {
    const directory = fixture(t);
    assert.throws(() => createMilestoneManifest({ directory, build: "41" }), /build|missing|unexpected/i);
  });
});

test("verification rejects missing, extra, tampered, and wrong-build downloads", async (t) => {
  await t.test("missing payload", (t) => {
    const directory = fixture(t);
    writeMilestoneManifest({ directory, build: BUILD });
    fs.rmSync(path.join(directory, expectedNames()[1]));
    assert.throws(() => verifyMilestonePayload({ directory, build: BUILD }), /missing|payload/i);
  });
  await t.test("extra payload", (t) => {
    const directory = fixture(t);
    writeMilestoneManifest({ directory, build: BUILD });
    fs.writeFileSync(path.join(directory, "extra"), "extra");
    assert.throws(() => verifyMilestonePayload({ directory, build: BUILD }), /extra|unexpected|exactly/i);
  });
  await t.test("tampered bytes", (t) => {
    const directory = fixture(t);
    writeMilestoneManifest({ directory, build: BUILD });
    fs.appendFileSync(path.join(directory, expectedNames()[3]), "tampered");
    assert.throws(() => verifyMilestonePayload({ directory, build: BUILD }), /sha|hash|size|tamper|bytes/i);
  });
  await t.test("wrong requested build", (t) => {
    const directory = fixture(t);
    writeMilestoneManifest({ directory, build: BUILD });
    assert.throws(
      () => verifyMilestonePayload({ directory, build: "41" }),
      /build|manifest|missing|unexpected/i,
    );
  });
});

test("verification rejects unsafe names and unknown manifest fields", async (t) => {
  for (const [name, mutate] of [
    ["unsafe path", (manifest) => { manifest.files[0].name = "../appcast.xml"; }],
    ["unknown root field", (manifest) => { manifest.unexpected = true; }],
    ["unknown file field", (manifest) => { manifest.files[0].unexpected = true; }],
    ["wrong manifest build", (manifest) => { manifest.build = "41"; }],
  ]) {
    await t.test(name, (t) => {
      const directory = fixture(t);
      writeMilestoneManifest({ directory, build: BUILD });
      const manifestPath = path.join(directory, MANIFEST_NAME);
      const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
      mutate(manifest);
      fs.writeFileSync(manifestPath, `${JSON.stringify(manifest)}\n`);
      assert.throws(
        () => verifyMilestonePayload({ directory, build: BUILD }),
        /field|schema|name|path|unsafe|build|manifest/i,
      );
    });
  }
});
