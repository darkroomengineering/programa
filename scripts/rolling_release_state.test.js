"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

// Public contract for scripts/rolling_release_state.js:
//
//   validateCandidateManifest(manifest) -> normalizedManifest
//   selectPromotionCandidate(candidates) -> normalizedManifest | null
//   derivePublicHighWater(state) -> canonical build string | null
//   assertCandidateMayPromote(candidate, highWater) -> "repair" | "promote"
//   getPromotionOrder(manifest) -> asset[]
//   createCandidateManifest(input) -> normalizedManifest
//
// A manifest is a JSON-derived plain object with this exact shape:
//
//   {
//     schemaVersion: 2,
//     sealed: boolean,
//     targetSha: <40 lowercase hexadecimal characters>,
//     version: <canonical major.minor.patch>,
//     build: <canonical positive decimal string>,
//     assets: [{ name, role, size, sha256 }]
//   }
//
// `role` is exactly "immutable", "appcast", or "stable-alias". Asset names
// are safe basenames. A sealed manifest contains the complete rolling payload:
// one build-suffixed enclosure DMG, one dSYM archive, one build-suffixed Windows
// executable, appcast.xml, and the stable macOS and Windows aliases. Asset size
// is a positive safe integer and sha256 is 64
// lowercase hexadecimal characters. Marketing `version` and monotonic `build`
// are independent canonical identifiers. Every immutable filename suffix still
// agrees with `build`.
//
// Candidate selection accepts manifest-like JSON values. It ignores unsealed
// drafts, validates every sealed candidate, and returns the sealed manifest with
// the greatest build. Public state has `{ rollingAssetNames,
// rollingAppcastXml, publishedMilestoneAppcastXmls }`; null/absent appcasts are
// allowed, but every advertised milestone appcast must be supplied and any
// non-null malformed appcast fails closed. Every valid enclosure contributes
// to the maximum alongside versioned asset names.
// Build comparisons use BigInt internally and returned builds remain strings.
const {
  assertCandidateMayPromote,
  createCandidateManifest,
  derivePublicHighWater,
  getPromotionOrder,
  selectPromotionCandidate,
  validateCandidateManifest,
  validateReleasePayloadReferences,
} = require("./rolling_release_state");

const TARGET_SHA = "1".repeat(40);
const ASSET_SHA = "a".repeat(64);
const VALID_ED25519_SIGNATURE = Buffer.alloc(64, 1).toString("base64");

function versionFor() {
  return "0.64.73";
}

function requiredAssets(build) {
  const assets = [
    `programa-macos-${build}.dmg`,
    `programa-dSYMs-${build}.zip`,
    `programa-windows-${build}.exe`,
  ].map((name, index) => ({
    name,
    role: "immutable",
    size: index + 1,
    sha256: String(index + 1).padStart(64, "0"),
  }));
  assets[0].size = 902;
  assets[0].sha256 = "c".repeat(64);
  assets[2].size = 903;
  assets[2].sha256 = "d".repeat(64);
  return assets;
}

function manifestFor(build = "900719925474099312345678901234567890", overrides = {}) {
  const manifest = {
    schemaVersion: 2,
    sealed: true,
    targetSha: TARGET_SHA,
    version: versionFor(build),
    build,
    assets: [
      ...requiredAssets(build),
      { name: "appcast.xml", role: "appcast", size: 901, sha256: "b".repeat(64) },
      { name: "programa-macos.dmg", role: "stable-alias", size: 902, sha256: "c".repeat(64) },
      { name: "programa-windows.exe", role: "stable-alias", size: 903, sha256: "d".repeat(64) },
    ],
  };

  return { ...manifest, ...overrides };
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function appcast(build, enclosureBuild = build, length = 902, signature = VALID_ED25519_SIGNATURE, tag = "rolling") {
  return `<?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
      <channel><item>
        <sparkle:version>${build}</sparkle:version>
        <enclosure url="https://github.com/darkroomengineering/programa/releases/download/${tag}/programa-macos-${enclosureBuild}.dmg" length="${length}" sparkle:edSignature="${signature}" />
      </item></channel>
    </rss>`;
}

function legacyAppcast(build, length = 902, signature = VALID_ED25519_SIGNATURE) {
  return `<?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
      <channel><item>
        <sparkle:version>${build}</sparkle:version>
        <enclosure url="https://github.com/darkroomengineering/programa/releases/download/v0.1.0/programa-macos.dmg" length="${length}" sparkle:edSignature="${signature}" />
      </item></channel>
    </rss>`;
}

function legacyAttributeAppcast(build, enclosureBuild = build) {
  return `<?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
      <channel><item>
        <enclosure url="https://github.com/darkroomengineering/programa/releases/download/v0.1.0/programa-macos-${enclosureBuild}.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" sparkle:version="${build}" />
      </item></channel>
    </rss>`;
}

function validateReferences(manifest, appcastXml, tag = "rolling") {
  return validateReleasePayloadReferences({
    appcastXml,
    repository: "darkroomengineering/programa",
    tag,
    manifest,
  });
}

test("a complete sealed manifest preserves arbitrary-precision canonical build values", () => {
  const input = clone(manifestFor());
  const validated = validateCandidateManifest(input);

  assert.deepEqual(validated, input);
  assert.equal(typeof validated.build, "string");
  assert.equal(validated.build, "900719925474099312345678901234567890");
});

test("the candidate schema rejects unknown, missing, or non-JSON field values", async (t) => {
  const cases = [
    ["unknown root field", { ...manifestFor("41"), unexpected: true }],
    ["unknown asset field", (() => {
      const value = manifestFor("41");
      value.assets[0].unexpected = true;
      return value;
    })()],
    ["missing target SHA", (() => {
      const value = manifestFor("41");
      delete value.targetSha;
      return value;
    })()],
    ["wrong schema version", manifestFor("41", { schemaVersion: 3 })],
    ["non-array assets", manifestFor("41", { assets: {} })],
    ["numeric build", manifestFor("41", { build: 41 })],
    ["non-JSON build", manifestFor("41", { build: 41n })],
  ];

  for (const [name, value] of cases) {
    await t.test(name, () => {
      assert.throws(() => validateCandidateManifest(value), /manifest|schema|field|build|asset|json/i);
    });
  }
});

test("builds must be canonical positive decimal strings", async (t) => {
  for (const build of ["0", "00", "01", "+1", "-1", "1.0", "1e3", " 1", "1 ", ""] ) {
    await t.test(JSON.stringify(build), () => {
      assert.throws(
        () => validateCandidateManifest(manifestFor("41", { build })),
        /build|canonical|decimal|positive/i,
      );
    });
  }
});

test("target SHA and marketing version are independently canonical", async (t) => {
  const cases = [
    ["uppercase target SHA", { targetSha: TARGET_SHA.toUpperCase().replaceAll("1", "A") }],
    ["short target SHA", { targetSha: "1".repeat(39) }],
    ["incomplete marketing version", { version: "0.64" }],
    ["noncanonical marketing version", { version: "0.64.073" }],
  ];

  for (const [name, override] of cases) {
    await t.test(name, () => {
      assert.throws(() => validateCandidateManifest(manifestFor("41", override)), /sha|version|build|target/i);
    });
  }
});

test("marketing version does not have to contain the monotonic build", () => {
  const build = "900719925474099312345678901234567890";
  const value = manifestFor(build, { version: "0.64.73" });

  assert.deepEqual(validateCandidateManifest(clone(value)), value);
});

test("asset names are safe unique basenames and roles are exact", async (t) => {
  const mutations = [
    ["parent traversal", (asset) => { asset.name = "../appcast.xml"; }],
    ["nested path", (asset) => { asset.name = "nested/appcast.xml"; }],
    ["Windows path", (asset) => { asset.name = "nested\\appcast.xml"; }],
    ["empty name", (asset) => { asset.name = ""; }],
    ["unknown role", (asset) => { asset.role = "alias"; }],
  ];

  for (const [name, mutate] of mutations) {
    await t.test(name, () => {
      const value = manifestFor("41");
      mutate(value.assets[2]);
      assert.throws(() => validateCandidateManifest(value), /asset|name|basename|path|role/i);
    });
  }

  await t.test("duplicate name", () => {
    const value = manifestFor("41");
    value.assets[3].name = value.assets[2].name;
    assert.throws(() => validateCandidateManifest(value), /duplicate|asset|name/i);
  });
});

test("mutable aliases cannot masquerade as immutable payloads", async (t) => {
  for (const alias of ["appcast.xml", "programa-macos.dmg", "programa-windows.exe"]) {
    await t.test(alias, () => {
      const value = manifestFor("41");
      value.assets.find((asset) => asset.name === alias).role = "immutable";
      assert.throws(() => validateCandidateManifest(value), /alias|role|immutable|appcast/i);
    });
  }
});

test("a sealed candidate has exactly one appcast and two stable aliases", async (t) => {
  const cases = [
    ["missing appcast", (assets) => assets.filter((asset) => asset.role !== "appcast")],
    ["missing stable alias", (assets) => assets.filter((asset) => asset.name !== "programa-windows.exe")],
    ["second appcast", (assets) => [...assets, { name: "feed.xml", role: "appcast", size: 1, sha256: ASSET_SHA }]],
    ["second stable alias", (assets) => [...assets, { name: "latest.dmg", role: "stable-alias", size: 1, sha256: ASSET_SHA }]],
  ];

  for (const [name, mutate] of cases) {
    await t.test(name, () => {
      const value = manifestFor("41");
      value.assets = mutate(value.assets);
      assert.throws(() => validateCandidateManifest(value), /appcast|stable|alias|exactly|asset/i);
    });
  }
});

test("a sealed candidate requires every build-specific immutable payload", async (t) => {
  for (const required of requiredAssets("41").map((asset) => asset.name)) {
    await t.test(required, () => {
      const value = manifestFor("41");
      value.assets = value.assets.filter((asset) => asset.name !== required);
      assert.throws(() => validateCandidateManifest(value), /missing|required|asset|immutable/i);
    });
  }
});

test("immutable payload suffixes must match the candidate build", () => {
  const value = manifestFor("41");
  value.assets[0].name = "programa-macos-40.dmg";

  assert.throws(() => validateCandidateManifest(value), /build|suffix|asset|required/i);
});

// PR #329 removed the remote daemon (programad-remote). Historical schema 1
// candidates can still carry its six legacy immutables, so they remain readable
// even though only schema 2 desktop payloads are promotable now.
function legacyDaemonAssets(build) {
  return [
    `programad-remote-checksums-${build}.txt`,
    `programad-remote-darwin-amd64-${build}`,
    `programad-remote-darwin-arm64-${build}`,
    `programad-remote-linux-amd64-${build}`,
    `programad-remote-linux-arm64-${build}`,
    `programad-remote-manifest-${build}.json`,
  ].map((name, index) => ({
    name,
    role: "immutable",
    size: index + 100,
    sha256: String(index + 100).padStart(64, "0"),
  }));
}

function historicalManifestFor(build) {
  const value = manifestFor(build);
  value.schemaVersion = 1;
  value.assets = value.assets.filter(
    (asset) =>
      asset.name !== `programa-windows-${build}.exe` && asset.name !== "programa-windows.exe",
  );
  return value;
}

test("a sealed manifest with the full legacy ten-asset daemon set still validates", () => {
  const value = historicalManifestFor("41");
  value.assets.push(...legacyDaemonAssets("41"));

  const validated = validateCandidateManifest(value);
  assert.equal(validated.assets.length, 10);
});

test("a sealed manifest with a partial legacy daemon asset set fails closed", () => {
  const value = historicalManifestFor("41");
  value.assets.push(...legacyDaemonAssets("41").slice(0, 3));

  assert.throws(() => validateCandidateManifest(value), /partial|legacy|daemon|asset/i);
});

test("an immutable asset with an unknown, non-legacy name still fails validation", () => {
  const value = manifestFor("41");
  value.assets.push({
    name: "programad-remote-windows-amd64-41",
    role: "immutable",
    size: 900,
    sha256: "e".repeat(64),
  });

  assert.throws(
    () => validateCandidateManifest(value),
    /unexpected immutable asset or build suffix/i,
  );
});

test("historical schema 1 payloads remain readable but cannot be promoted", () => {
  const historical = historicalManifestFor("41");
  assert.equal(validateCandidateManifest(historical).schemaVersion, 1);
  assert.throws(() => assertCandidateMayPromote(historical, null), /schema|current|version 2/i);
  assert.throws(() => getPromotionOrder(historical), /schema|current|version 2/i);
});

test("the stable DMG is byte-identical to the immutable build DMG", () => {
  const valid = manifestFor("41");
  assert.doesNotThrow(() => validateCandidateManifest(valid));

  for (const field of ["size", "sha256"]) {
    const mismatched = manifestFor("41");
    const stable = mismatched.assets.find((asset) => asset.name === "programa-macos.dmg");
    stable[field] = field === "size" ? stable.size + 1 : "d".repeat(64);
    assert.throws(() => validateCandidateManifest(mismatched), /stable|dmg|identical|size|sha|hash/i);
  }
});

test("the stable EXE is byte-identical to the immutable build EXE", () => {
  const valid = manifestFor("41");
  assert.doesNotThrow(() => validateCandidateManifest(valid));

  for (const field of ["size", "sha256"]) {
    const mismatched = manifestFor("41");
    const stable = mismatched.assets.find((asset) => asset.name === "programa-windows.exe");
    stable[field] = field === "size" ? stable.size + 1 : "e".repeat(64);
    assert.throws(() => validateCandidateManifest(mismatched), /stable|exe|identical|size|sha|hash/i);
  }
});

test("the appcast authenticates the exact immutable DMG bytes", async (t) => {
  const manifest = manifestFor("41");
  assert.doesNotThrow(() => validateReferences(manifest, appcast("41")));

  await t.test("enclosure length differs from sealed DMG", () => {
    assert.throws(() => validateReferences(manifest, appcast("41", "41", 901)), /length|size|dmg|enclosure/i);
  });
  for (const signature of [
    "",
    "not base64",
    "YWJjZA",
    Buffer.alloc(63, 1).toString("base64"),
    Buffer.alloc(65, 1).toString("base64"),
  ]) {
    await t.test(`invalid signature ${JSON.stringify(signature)}`, () => {
      assert.throws(
        () => validateReferences(manifest, appcast("41", "41", 902, signature)),
        /signature|base64|canonical|empty|64|length/i,
      );
    });
  }
});

test("every payload has a positive safe integer size and lowercase SHA-256", async (t) => {
  for (const size of [0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, "1"]) {
    await t.test(`size ${String(size)}`, () => {
      const value = manifestFor("41");
      value.assets[0].size = size;
      assert.throws(() => validateCandidateManifest(value), /size|integer|positive|safe/i);
    });
  }

  for (const sha256 of ["a".repeat(63), "A".repeat(64), "g".repeat(64), 123]) {
    await t.test(`sha256 ${String(sha256).slice(0, 8)}`, () => {
      const value = manifestFor("41");
      value.assets[0].sha256 = sha256;
      assert.throws(() => validateCandidateManifest(value), /sha|hash|lowercase|hex/i);
    });
  }
});

test("candidate selection returns the highest sealed build regardless of input order", () => {
  const low = manifestFor("900719925474099312345678901234567890");
  const high = manifestFor("900719925474099312345678901234567892");
  const middle = manifestFor("900719925474099312345678901234567891");

  assert.equal(selectPromotionCandidate([middle, high, low]).build, high.build);
  assert.equal(selectPromotionCandidate([high, low, middle]).build, high.build);
});

test("candidate selection ignores incomplete unsealed drafts", () => {
  const incompleteDraft = { schemaVersion: 1, sealed: false, build: "999999999999999999999999999999999999" };
  const sealed = manifestFor("42");

  assert.deepEqual(selectPromotionCandidate([incompleteDraft, sealed]), sealed);
  assert.equal(selectPromotionCandidate([incompleteDraft]), null);
});

test("a corrupt highest sealed candidate fails closed instead of falling back", () => {
  const validLower = manifestFor("41");
  const corruptHigher = manifestFor("42");
  corruptHigher.assets = corruptHigher.assets.filter((asset) => !asset.name.includes("dSYMs"));

  assert.throws(
    () => selectPromotionCandidate([validLower, corruptHigher]),
    /candidate|sealed|missing|required|asset/i,
  );
});

test("public high-water is the maximum build from rolling assets and readable appcasts", () => {
  const state = {
    rollingAssetNames: [
      "programa-macos-900719925474099312345678901234567891.dmg",
      "programa-dSYMs-900719925474099312345678901234567893.zip",
      "programa-macos.dmg",
      "appcast.xml",
    ],
    rollingAppcastXml: appcast("900719925474099312345678901234567892"),
    publishedMilestoneAppcastXmls: [appcast("900719925474099312345678901234567890")],
  };

  assert.equal(derivePublicHighWater(state), "900719925474099312345678901234567893");
});

test("missing or stale rolling aliases cannot lower the recoverable public high-water", async (t) => {
  const immutableBuild = "900719925474099312345678901234567899";
  const rollingAssetNames = [`programa-macos-${immutableBuild}.dmg`];

  await t.test("aliases missing", () => {
    assert.equal(
      derivePublicHighWater({ rollingAssetNames, rollingAppcastXml: null, publishedMilestoneAppcastXmls: [] }),
      immutableBuild,
    );
  });

  await t.test("rolling appcast points at an older enclosure", () => {
    assert.equal(
      derivePublicHighWater({
        rollingAssetNames: [...rollingAssetNames, "appcast.xml", "wrong-stable-name.dmg"],
        rollingAppcastXml: appcast("2"),
        publishedMilestoneAppcastXmls: [appcast("3")],
      }),
      immutableBuild,
    );
  });

  await t.test("an advertised rolling appcast is malformed", () => {
    assert.throws(
      () => derivePublicHighWater({
        rollingAssetNames,
        rollingAppcastXml: "<not-readable-appcast>",
        publishedMilestoneAppcastXmls: [appcast("3")],
      }),
      /appcast|xml|malformed|enclosure/i,
    );
  });
});

test("every valid appcast enclosure contributes to the public high-water", () => {
  const xml = `<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <item><sparkle:version>41</sparkle:version><enclosure url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos-41.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" /></item>
    <item><sparkle:version>900719925474099312345678901234567899</sparkle:version><enclosure url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos-900719925474099312345678901234567899.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" /></item>
    <item><sparkle:version>73</sparkle:version><enclosure url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos-73.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" /></item>
  </channel></rss>`;

  assert.equal(
    derivePublicHighWater({ rollingAssetNames: [], rollingAppcastXml: xml, publishedMilestoneAppcastXmls: [] }),
    "900719925474099312345678901234567899",
  );
});

test("legacy milestone appcasts with a stable DMG URL still contribute canonical high-water evidence", () => {
  assert.equal(
    derivePublicHighWater({
      rollingAssetNames: [],
      rollingAppcastXml: null,
      publishedMilestoneAppcastXmls: [legacyAppcast("900719925474099312345678901234567899")],
    }),
    "900719925474099312345678901234567899",
  );
});

test("official attribute-era Sparkle appcasts contribute canonical public high-water evidence", () => {
  assert.equal(
    derivePublicHighWater({
      rollingAssetNames: [],
      rollingAppcastXml: legacyAttributeAppcast("900719925474099312345678901234567899"),
      publishedMilestoneAppcastXmls: [],
    }),
    "900719925474099312345678901234567899",
  );
});

test("attribute-era versions are accepted only as one direct enclosure attribute", async (t) => {
  const feed = (item) => `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>${item}</channel></rss>`;
  const baseAttributes = `url="https://github.com/darkroomengineering/programa/releases/download/v0.1.0/programa-macos-41.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}"`;
  const cases = [
    ["child and matching attribute", `<item><sparkle:version>41</sparkle:version><enclosure ${baseAttributes} sparkle:version="41" /></item>`],
    ["child and disagreeing attribute", `<item><sparkle:version>41</sparkle:version><enclosure ${baseAttributes} sparkle:version="42" /></item>`],
    ["duplicate attributes", `<item><enclosure ${baseAttributes} sparkle:version="41" sparkle:version="41" /></item>`],
    ["attribute on item", `<item sparkle:version="41"><enclosure ${baseAttributes} /></item>`],
    ["attribute on nested enclosure", `<item><group><enclosure ${baseAttributes} sparkle:version="41" /></group></item>`],
  ];
  for (const [name, item] of cases) {
    await t.test(name, () => {
      assert.throws(
        () => derivePublicHighWater({ rollingAssetNames: [], rollingAppcastXml: feed(item), publishedMilestoneAppcastXmls: [] }),
        /appcast|version|duplicate|direct|item|enclosure|ambiguous/i,
      );
    });
  }
});

test("candidate appcasts still require the exact build-versioned enclosure URL", () => {
  const manifest = manifestFor("41");
  assert.throws(
    () => validateReferences(manifest, legacyAppcast("41")),
    /candidate|enclosure|url|programa-macos-41|versioned|exact/i,
  );
});

test("an archived candidate binds every build-specific URL to its exact permanent tag", () => {
  const manifest = manifestFor("41");
  const archiveTag = "rolling-candidate-41";

  assert.doesNotThrow(() => validateReferences(
    manifest,
    appcast("41", "41", 902, VALID_ED25519_SIGNATURE, archiveTag),
    archiveTag,
  ));
  assert.throws(
    () => validateReleasePayloadReferences({
      appcastXml: appcast("41", "41", 902, VALID_ED25519_SIGNATURE, "rolling-candidate-40"),
      repository: "darkroomengineering/programa",
      tag: archiveTag,
      manifest,
    }),
    /archive|candidate|release|tag|url|rolling-candidate-41|exact/i,
  );
});

test("candidate appcasts require the modern child version form", () => {
  const manifest = manifestFor("41");
  assert.throws(
    () => validateReferences(manifest, legacyAttributeAppcast("41")),
    /candidate|child|version|modern|appcast/i,
  );
});

test("each appcast item has one canonical child version paired with one matching enclosure", async (t) => {
  const feed = (item) => `<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>${item}</channel></rss>`;
  const enclosure = (build) => `<enclosure url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos-${build}.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" />`;
  const cases = [
    ["missing child version", `<item>${enclosure("41")}</item>`],
    ["duplicate child versions", `<item><sparkle:version>41</sparkle:version><sparkle:version>41</sparkle:version>${enclosure("41")}</item>`],
    ["duplicate enclosures", `<item><sparkle:version>41</sparkle:version>${enclosure("41")}${enclosure("41")}</item>`],
    ["version outside item", `<sparkle:version>41</sparkle:version><item>${enclosure("41")}</item>`],
    ["mismatched enclosure build", `<item><sparkle:version>41</sparkle:version>${enclosure("42")}</item>`],
  ];

  for (const [name, item] of cases) {
    await t.test(name, () => {
      assert.throws(
        () => derivePublicHighWater({
          rollingAssetNames: [],
          rollingAppcastXml: feed(item),
          publishedMilestoneAppcastXmls: [],
        }),
        /appcast|item|version|enclosure|ambiguous|match/i,
      );
    });
  }
});

test("Sparkle-prefixed fields require the canonical Sparkle namespace", async (t) => {
  for (const [name, namespace] of [
    ["missing namespace", ""],
    ["wrong namespace", ' xmlns:sparkle="urn:not-sparkle"'],
  ]) {
    await t.test(name, () => {
      const xml = appcast("41").replace(
        ' xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"',
        namespace,
      );
      assert.throws(
        () => derivePublicHighWater({ rollingAssetNames: [], rollingAppcastXml: xml, publishedMilestoneAppcastXmls: [] }),
        /namespace|xmlns|sparkle|appcast/i,
      );
    });
  }
});

test("candidate appcasts require one exact direct rss channel item hierarchy", async (t) => {
  const manifest = manifestFor("41");
  const enclosure = `<enclosure url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos-41.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" />`;
  const item = `<item><sparkle:version>41</sparkle:version>${enclosure}</item>`;
  const cases = [
    ["descendant namespace rebind", `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item xmlns:sparkle="urn:not-sparkle"><sparkle:version>41</sparkle:version>${enclosure}</item></channel></rss>`],
    ["nested channel", `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><wrapper><channel>${item}</channel></wrapper></rss>`],
    ["multiple channels", `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>${item}</channel><channel></channel></rss>`],
    ["item outside channel", `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">${item}<channel></channel></rss>`],
    ["nested item", `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><group>${item}</group></channel></rss>`],
  ];
  for (const [name, xml] of cases) {
    await t.test(name, () => {
      assert.throws(() => validateReferences(manifest, xml), /candidate|rss|channel|item|direct|namespace|structure/i);
    });
  }
});

test("a malformed advertised milestone appcast fails closed", () => {
  assert.throws(
    () => derivePublicHighWater({
      rollingAssetNames: ["programa-macos-42.dmg"],
      rollingAppcastXml: null,
      publishedMilestoneAppcastXmls: [appcast("43"), "<rss><channel><item>"],
    }),
    /appcast|xml|malformed|enclosure/i,
  );
});

test("an advertised appcast without a Sparkle enclosure fails closed", () => {
  const emptyFeed = `<?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
      <channel><title>Programa updates</title><item><title>No download</title></item></channel>
    </rss>`;

  assert.throws(
    () => derivePublicHighWater({
      rollingAssetNames: ["programa-macos-42.dmg"],
      rollingAppcastXml: emptyFeed,
      publishedMilestoneAppcastXmls: [],
    }),
    /appcast|malformed|enclosure/i,
  );
});

test("every published milestone appcast contributes even when semantic tag order disagrees with build order", () => {
  assert.equal(
    derivePublicHighWater({
      rollingAssetNames: [],
      rollingAppcastXml: null,
      publishedMilestoneAppcastXmls: [
        appcast("900719925474099312345678901234567899"),
        appcast("41"),
        appcast("73"),
      ],
    }),
    "900719925474099312345678901234567899",
  );
});

test("noncanonical build fragments in asset names do not become public high-water evidence", () => {
  assert.equal(
    derivePublicHighWater({
      rollingAssetNames: ["programa-macos-0042.dmg", "programa-dSYMs-1e3.zip"],
      rollingAppcastXml: null,
      publishedMilestoneAppcastXmls: [],
    }),
    null,
  );
});

test("an advertised appcast with a noncanonical child version fails closed", () => {
  assert.throws(
    () => derivePublicHighWater({
      rollingAssetNames: [],
      rollingAppcastXml: appcast("0042", "0042"),
      publishedMilestoneAppcastXmls: [],
    }),
    /appcast|version|canonical|decimal|build/i,
  );
});

test("promotion rejects downgrades, permits equal-build repair, and identifies newer promotion", () => {
  const highWater = "900719925474099312345678901234567891";

  assert.throws(
    () => assertCandidateMayPromote(manifestFor("900719925474099312345678901234567890"), highWater),
    /below|older|downgrade|high.water|build/i,
  );
  assert.equal(assertCandidateMayPromote(manifestFor(highWater), highWater), "repair");
  assert.equal(
    assertCandidateMayPromote(manifestFor("900719925474099312345678901234567892"), highWater),
    "promote",
  );
});

test("promotion order is deterministic: immutable prerequisites, appcast, then stable alias", () => {
  const value = manifestFor("41");
  value.assets.reverse();

  const ordered = getPromotionOrder(value);
  const names = ordered.map((asset) => asset.name);
  const immutableNames = requiredAssets("41").map((asset) => asset.name).sort();

  assert.deepEqual(names, [
    ...immutableNames,
    "appcast.xml",
    "programa-macos.dmg",
    "programa-windows.exe",
  ]);
  assert.ok(ordered.slice(0, -3).every((asset) => asset.role === "immutable"));
  assert.equal(ordered.at(-3).role, "appcast");
  assert.equal(ordered.at(-1).role, "stable-alias");
});

test("manifest creation adds the schema version and canonicalizes asset order", () => {
  const source = manifestFor("41");
  source.assets.reverse();
  delete source.schemaVersion;

  const created = createCandidateManifest(source);

  assert.equal(created.schemaVersion, 2);
  assert.equal(created.build, "41");
  assert.deepEqual(created.assets, getPromotionOrder(created));
  assert.deepEqual(validateCandidateManifest(clone(created)), created);
});

test("new candidate creation rejects the historical schema", () => {
  const source = manifestFor("41", { schemaVersion: 1 });
  assert.throws(() => createCandidateManifest(source), /new|schema|version 2/i);
});
