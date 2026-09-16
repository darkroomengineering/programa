"use strict";

const ROOT_FIELDS = ["schemaVersion", "sealed", "targetSha", "version", "build", "assets"];
const ASSET_FIELDS = ["name", "role", "size", "sha256"];
const ROLES = new Set(["immutable", "appcast", "stable-alias"]);
const CANONICAL_BUILD = /^[1-9][0-9]*$/;
const TARGET_SHA = /^[0-9a-f]{40}$/;
const ASSET_SHA = /^[0-9a-f]{64}$/;
const SAFE_BASENAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle";
const CANONICAL_BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function assertPlainObject(value, label) {
  if (!isPlainObject(value)) throw new TypeError(`${label} must be a plain JSON object`);
}

function assertExactFields(value, expected, label) {
  const keys = Reflect.ownKeys(value);
  if (
    keys.length !== expected.length ||
    keys.some((key) => typeof key !== "string" || !expected.includes(key))
  ) {
    throw new TypeError(`${label} fields must be exactly: ${expected.join(", ")}`);
  }

  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !("value" in descriptor) || !descriptor.enumerable) {
      throw new TypeError(`${label} field ${key} must be a JSON data field`);
    }
  }
}

function assertCanonicalBuild(build, label = "build") {
  if (typeof build !== "string" || !CANONICAL_BUILD.test(build)) {
    throw new TypeError(`${label} must be a canonical positive decimal string`);
  }
}

function requiredImmutableNames(build) {
  return [
    `programa-macos-${build}.dmg`,
    `programa-dSYMs-${build}.zip`,
    `programa-windows-${build}.exe`,
  ];
}

// The remote daemon (programad-remote) was removed in PR #329. Historical schema 1
// prereleases may still carry its six immutable artifacts in addition to the original
// macOS payload. They cannot be rewritten, so validation keeps accepting those sealed
// manifests for inspection while the promotion path requires the current schema 2.
function legacyImmutableNames(build) {
  return [
    `programad-remote-checksums-${build}.txt`,
    `programad-remote-darwin-amd64-${build}`,
    `programad-remote-darwin-arm64-${build}`,
    `programad-remote-linux-amd64-${build}`,
    `programad-remote-linux-arm64-${build}`,
    `programad-remote-manifest-${build}.json`,
  ];
}

function validateAsset(asset, index) {
  const label = `manifest asset ${index}`;
  assertPlainObject(asset, label);
  assertExactFields(asset, ASSET_FIELDS, label);

  if (
    typeof asset.name !== "string" ||
    !SAFE_BASENAME.test(asset.name) ||
    asset.name === "." ||
    asset.name === ".."
  ) {
    throw new TypeError(`${label} name must be a safe basename`);
  }
  if (!ROLES.has(asset.role)) throw new TypeError(`${label} role is invalid`);
  if (!Number.isSafeInteger(asset.size) || asset.size <= 0) {
    throw new TypeError(`${label} size must be a positive safe integer`);
  }
  if (typeof asset.sha256 !== "string" || !ASSET_SHA.test(asset.sha256)) {
    throw new TypeError(`${label} sha256 must be 64 lowercase hexadecimal characters`);
  }

  return {
    name: asset.name,
    role: asset.role,
    size: asset.size,
    sha256: asset.sha256,
  };
}

function validateCandidateManifest(manifest) {
  assertPlainObject(manifest, "manifest");
  assertExactFields(manifest, ROOT_FIELDS, "manifest");

  if (manifest.schemaVersion !== 1 && manifest.schemaVersion !== 2) {
    throw new TypeError("manifest schemaVersion must be 1 or 2");
  }
  if (typeof manifest.sealed !== "boolean") throw new TypeError("manifest sealed must be boolean");
  if (typeof manifest.targetSha !== "string" || !TARGET_SHA.test(manifest.targetSha)) {
    throw new TypeError("manifest targetSha must be 40 lowercase hexadecimal characters");
  }
  assertCanonicalBuild(manifest.build, "manifest build");

  if (typeof manifest.version !== "string") {
    throw new TypeError("manifest version must be a canonical major.minor.patch string");
  }
  if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(manifest.version)) {
    throw new TypeError("manifest version must be a canonical major.minor.patch string");
  }
  if (!Array.isArray(manifest.assets)) throw new TypeError("manifest assets must be an array");

  const assets = manifest.assets.map(validateAsset);
  const names = new Set();
  for (const asset of assets) {
    if (names.has(asset.name)) throw new TypeError(`manifest has duplicate asset name: ${asset.name}`);
    names.add(asset.name);
  }

  const appcast = assets.filter((asset) => asset.role === "appcast");
  const stableAliases = assets.filter((asset) => asset.role === "stable-alias");
  const immutable = assets.filter((asset) => asset.role === "immutable");
  const currentRequiredNames = requiredImmutableNames(manifest.build);
  const historicalRequiredNames = currentRequiredNames.slice(0, 2);
  const requiredNames = new Set(
    manifest.schemaVersion === 2 ? currentRequiredNames : historicalRequiredNames,
  );
  const legacyNames = new Set(legacyImmutableNames(manifest.build));

  for (const asset of assets) {
    if (asset.name === "appcast.xml" && asset.role !== "appcast") {
      throw new TypeError("appcast.xml must have the appcast role");
    }
    if (
      (asset.name === "programa-macos.dmg" || asset.name === "programa-windows.exe") &&
      asset.role !== "stable-alias"
    ) {
      throw new TypeError(`${asset.name} must have the stable-alias role`);
    }
    if (asset.role === "appcast" && asset.name !== "appcast.xml") {
      throw new TypeError("the appcast role is reserved for appcast.xml");
    }
    if (
      asset.role === "stable-alias" &&
      asset.name !== "programa-macos.dmg" &&
      asset.name !== "programa-windows.exe"
    ) {
      throw new TypeError(
        "the stable-alias role is reserved for programa-macos.dmg and programa-windows.exe",
      );
    }
    if (asset.role === "immutable" && !requiredNames.has(asset.name) && !legacyNames.has(asset.name)) {
      throw new TypeError(`manifest has an unexpected immutable asset or build suffix: ${asset.name}`);
    }
  }

  if (manifest.sealed) {
    const presentLegacyNames = immutable.filter((asset) => legacyNames.has(asset.name));
    const isLegacyManifest = presentLegacyNames.length > 0;
    if (isLegacyManifest && presentLegacyNames.length !== legacyNames.size) {
      throw new TypeError("sealed manifest has a partial legacy daemon asset set");
    }
    if (manifest.schemaVersion === 2 && isLegacyManifest) {
      throw new TypeError("schema 2 manifest must not contain legacy daemon assets");
    }
    const expectedAssetCount = isLegacyManifest ? 10 : manifest.schemaVersion === 2 ? 6 : 4;
    if (assets.length !== expectedAssetCount) {
      throw new TypeError(`sealed manifest must contain exactly ${expectedAssetCount} assets`);
    }
    const expectedStableAliasCount = manifest.schemaVersion === 2 ? 2 : 1;
    if (appcast.length !== 1 || stableAliases.length !== expectedStableAliasCount) {
      throw new TypeError(
        `sealed manifest must contain exactly one appcast and ${expectedStableAliasCount} stable aliases`,
      );
    }

    for (const asset of immutable) {
      requiredNames.delete(asset.name);
    }
    if (requiredNames.size !== 0) {
      throw new TypeError(
        `sealed manifest is missing required immutable asset: ${requiredNames.values().next().value}`,
      );
    }

    const stableDMG = assets.find((asset) => asset.name === "programa-macos.dmg");
    const immutableDMG = assets.find(
      (asset) => asset.name === `programa-macos-${manifest.build}.dmg`,
    );
    if (
      !immutableDMG ||
      stableDMG.size !== immutableDMG.size ||
      stableDMG.sha256 !== immutableDMG.sha256
    ) {
      throw new TypeError("stable DMG must be byte-identical to the immutable build DMG");
    }

    if (manifest.schemaVersion === 2) {
      const stableEXE = assets.find((asset) => asset.name === "programa-windows.exe");
      const immutableEXE = assets.find(
        (asset) => asset.name === `programa-windows-${manifest.build}.exe`,
      );
      if (
        !stableEXE ||
        !immutableEXE ||
        stableEXE.size !== immutableEXE.size ||
        stableEXE.sha256 !== immutableEXE.sha256
      ) {
        throw new TypeError("stable EXE must be byte-identical to the immutable build EXE");
      }
    }
  }

  return {
    schemaVersion: manifest.schemaVersion,
    sealed: manifest.sealed,
    targetSha: manifest.targetSha,
    version: manifest.version,
    build: manifest.build,
    assets,
  };
}

function selectPromotionCandidate(candidates) {
  if (!Array.isArray(candidates)) throw new TypeError("candidates must be an array");

  let selected = null;
  for (const candidate of candidates) {
    if (!isPlainObject(candidate) || candidate.sealed !== true) continue;
    let validated;
    try {
      validated = validateCandidateManifest(candidate);
    } catch (error) {
      throw new TypeError(`sealed candidate is invalid: ${error.message}`, { cause: error });
    }
    if (selected === null || BigInt(validated.build) > BigInt(selected.build)) selected = validated;
  }
  return selected;
}

const VERSIONED_ASSET_PATTERNS = [
  /^programa-macos-([1-9][0-9]*)\.dmg$/,
  /^programa-dSYMs-([1-9][0-9]*)\.zip$/,
  /^programa-windows-([1-9][0-9]*)\.exe$/,
];

function buildFromAssetName(name) {
  if (typeof name !== "string") return null;
  for (const pattern of VERSIONED_ASSET_PATTERNS) {
    const match = pattern.exec(name);
    if (match) return match[1];
  }
  return null;
}

function parseTagAttributes(tag, tagName, label) {
  const closingLength = /\/\s*>$/.test(tag) ? 2 : 1;
  let source = tag.slice(tagName.length + 1, -closingLength);
  const attributes = Object.create(null);

  while (source.length > 0) {
    if (/^\s*$/.test(source)) break;
    const match = /^\s+([A-Za-z_][A-Za-z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/.exec(source);
    if (!match) throw new TypeError(`${label} contains malformed XML attributes`);
    const name = match[1];
    if (Object.hasOwn(attributes, name)) {
      throw new TypeError(`${label} contains a duplicate XML attribute: ${name}`);
    }
    attributes[name] = match[2] ?? match[3];
    source = source.slice(match[0].length);
  }
  return attributes;
}

function parseAppcastEnclosures(
  xml,
  label = "appcast",
  { allowLegacyEnclosureVersion = false, requireSingleItem = false } = {},
) {
  if (typeof xml !== "string" || xml.trim() === "") {
    throw new TypeError(`${label} XML must be a non-empty string`);
  }

  const stack = [];
  const enclosures = [];
  let root = null;
  let channelCount = 0;
  let itemCount = 0;
  let currentItem = null;
  let cursor = 0;

  while (cursor < xml.length) {
    const start = xml.indexOf("<", cursor);
    const text = start === -1 ? xml.slice(cursor) : xml.slice(cursor, start);
    if (start === -1) {
      if (stack.length === 0 && text.trim() !== "") {
        throw new TypeError(`${label} XML has text outside its root element`);
      }
      if (stack.at(-1)?.name === "sparkle:version") stack.at(-1).text += text;
      cursor = xml.length;
      break;
    }
    if (stack.length === 0 && text.trim() !== "") {
      throw new TypeError(`${label} XML has text outside its root element`);
    }
    if (stack.at(-1)?.name === "sparkle:version") stack.at(-1).text += text;

    if (xml.startsWith("<!--", start)) {
      if (stack.at(-1)?.name === "sparkle:version") {
        throw new TypeError(`${label} sparkle:version must contain only a canonical build`);
      }
      const end = xml.indexOf("-->", start + 4);
      if (end === -1) throw new TypeError(`${label} XML has an unterminated comment`);
      cursor = end + 3;
      continue;
    }
    if (xml.startsWith("<![CDATA[", start)) {
      if (stack.at(-1)?.name === "sparkle:version") {
        throw new TypeError(`${label} sparkle:version must contain only a canonical build`);
      }
      const end = xml.indexOf("]]>", start + 9);
      if (end === -1) throw new TypeError(`${label} XML has an unterminated CDATA section`);
      if (stack.length === 0 && xml.slice(start + 9, end).trim() !== "") {
        throw new TypeError(`${label} XML has CDATA outside its root element`);
      }
      cursor = end + 3;
      continue;
    }
    if (xml.startsWith("<?", start)) {
      if (stack.at(-1)?.name === "sparkle:version") {
        throw new TypeError(`${label} sparkle:version must contain only a canonical build`);
      }
      const end = xml.indexOf("?>", start + 2);
      if (end === -1) throw new TypeError(`${label} XML has an unterminated declaration`);
      cursor = end + 2;
      continue;
    }
    if (xml.startsWith("<!", start)) {
      throw new TypeError(`${label} XML contains an unsupported declaration`);
    }

    const end = xml.indexOf(">", start + 1);
    if (end === -1) throw new TypeError(`${label} XML has an unterminated tag`);
    const tag = xml.slice(start, end + 1);
    const closing = /^<\/([A-Za-z_][A-Za-z0-9_.:-]*)\s*>$/.exec(tag);
    if (closing) {
      const entry = stack.pop();
      if (entry?.name !== closing[1]) {
        throw new TypeError(`${label} XML has mismatched tags`);
      }
      if (entry.name === "sparkle:version") {
        const version = entry.text.trim();
        if (!CANONICAL_BUILD.test(version)) {
          throw new TypeError(`${label} item version must be a canonical positive decimal build`);
        }
        currentItem.version = version;
      } else if (entry.name === "item") {
        if (currentItem.enclosure === null) {
          throw new TypeError(`${label} item must contain exactly one enclosure child`);
        }
        const legacyVersion = currentItem.enclosure["sparkle:version"];
        if (currentItem.version !== null && legacyVersion !== undefined) {
          throw new TypeError(
            `${label} item must not contain both child and enclosure-attribute versions`,
          );
        }
        if (currentItem.version === null) {
          if (!allowLegacyEnclosureVersion || legacyVersion === undefined) {
            throw new TypeError(`${label} item must contain exactly one sparkle:version child`);
          }
          if (!CANONICAL_BUILD.test(legacyVersion)) {
            throw new TypeError(
              `${label} enclosure version must be a canonical positive decimal build`,
            );
          }
          currentItem.version = legacyVersion;
        }
        currentItem.enclosure["sparkle:version"] = currentItem.version;
        enclosures.push(currentItem.enclosure);
        currentItem = null;
      }
      cursor = end + 1;
      continue;
    }

    const opening = /^<([A-Za-z_][A-Za-z0-9_.:-]*)(?:\s[^<>]*)?\/?>$/.exec(tag);
    if (!opening) throw new TypeError(`${label} XML has a malformed tag`);
    const name = opening[1];
    const attributes = parseTagAttributes(tag, name, label);
    const selfClosing = /\/\s*>$/.test(tag);
    const parent = stack.at(-1)?.name ?? null;
    const inheritedSparkleNamespace = stack.at(-1)?.sparkleNamespace ?? null;
    const declaresSparkleNamespace = Object.hasOwn(attributes, "xmlns:sparkle");
    if (stack.length > 0 && declaresSparkleNamespace) {
      throw new TypeError(`${label} XML must not rebind the Sparkle namespace below rss`);
    }
    const sparkleNamespace = declaresSparkleNamespace
      ? attributes["xmlns:sparkle"]
      : inheritedSparkleNamespace;

    if (stack.length === 0) {
      if (root !== null) throw new TypeError(`${label} XML has multiple root elements`);
      root = name;
      if (name === "rss" && attributes["xmlns:sparkle"] !== SPARKLE_NAMESPACE) {
        throw new TypeError(`${label} XML must declare the canonical Sparkle namespace`);
      }
    }
    if (
      (name.startsWith("sparkle:") ||
        Reflect.ownKeys(attributes).some(
          (attribute) => attribute !== "xmlns:sparkle" && attribute.startsWith("sparkle:"),
        )) &&
      sparkleNamespace !== SPARKLE_NAMESPACE
    ) {
      throw new TypeError(`${label} Sparkle fields require the canonical Sparkle namespace`);
    }
    if (name === "channel") {
      if (parent !== "rss" || selfClosing) {
        throw new TypeError(`${label} channel must be one non-empty direct child of rss`);
      }
      channelCount += 1;
      if (channelCount > 1) throw new TypeError(`${label} XML must contain exactly one channel`);
    }
    if (
      Object.hasOwn(attributes, "sparkle:version") &&
      !(
        allowLegacyEnclosureVersion &&
        name === "enclosure" &&
        parent === "item" &&
        currentItem !== null
      )
    ) {
      throw new TypeError(`${label} versions must be item children, not attributes`);
    }
    if (name === "item") {
      if (parent !== "channel" || currentItem !== null || selfClosing) {
        throw new TypeError(`${label} item must be a non-empty child of channel`);
      }
      itemCount += 1;
      if (requireSingleItem && itemCount > 1) {
        throw new TypeError(`${label} must contain exactly one direct item`);
      }
      currentItem = { versionSeen: false, version: null, enclosure: null };
    } else if (name === "sparkle:version") {
      if (parent !== "item" || currentItem === null) {
        throw new TypeError(`${label} sparkle:version must be a direct item child`);
      }
      if (currentItem.versionSeen) {
        throw new TypeError(`${label} item contains duplicate sparkle:version children`);
      }
      if (Reflect.ownKeys(attributes).length !== 0 || selfClosing) {
        throw new TypeError(`${label} sparkle:version must contain one canonical build`);
      }
      currentItem.versionSeen = true;
    } else if (name === "enclosure") {
      if (parent !== "item" || currentItem === null) {
        throw new TypeError(`${label} enclosure must be a direct item child`);
      }
      if (currentItem.enclosure !== null) {
        throw new TypeError(`${label} item contains duplicate enclosure children`);
      }
      currentItem.enclosure = attributes;
    } else if (parent === "sparkle:version") {
      throw new TypeError(`${label} sparkle:version must contain only a canonical build`);
    }
    if (!selfClosing) {
      stack.push({
        name,
        text: name === "sparkle:version" ? "" : null,
        sparkleNamespace,
      });
    }
    cursor = end + 1;
  }

  if (stack.length !== 0) throw new TypeError(`${label} XML has unclosed tags`);
  if (root !== "rss" || channelCount !== 1) {
    throw new TypeError(`${label} XML must contain one direct channel under its rss root`);
  }
  if (requireSingleItem && itemCount !== 1) {
    throw new TypeError(`${label} must contain exactly one direct item`);
  }
  return enclosures;
}

function buildsFromAppcast(xml, label) {
  const builds = [];
  const enclosures = parseAppcastEnclosures(xml, label, {
    allowLegacyEnclosureVersion: true,
  });
  if (enclosures.length === 0) throw new TypeError(`${label} contains no Sparkle enclosure`);
  for (const enclosure of enclosures) {
    const version = enclosure["sparkle:version"];
    const urlText = enclosure.url;
    if (typeof version !== "string" || typeof urlText !== "string") {
      throw new TypeError(`${label} enclosure must contain url and sparkle:version attributes`);
    }

    let url;
    try {
      url = new URL(urlText);
    } catch (error) {
      throw new TypeError(`${label} enclosure contains an invalid URL`, { cause: error });
    }
    if (!CANONICAL_BUILD.test(version)) {
      throw new TypeError(`${label} sparkle:version must be a canonical positive decimal build`);
    }
    const basename = url.pathname.slice(url.pathname.lastIndexOf("/") + 1);
    const versionedName = /^programa-macos-([1-9][0-9]*)\.dmg$/.exec(basename);
    if (basename !== "programa-macos.dmg" && versionedName?.[1] !== version) {
      throw new TypeError(
        `${label} enclosure URL must use the legacy DMG name or match sparkle:version`,
      );
    }
    builds.push(version);
  }
  return builds;
}

function derivePublicHighWater(state) {
  if (state === null || typeof state !== "object" || Array.isArray(state)) {
    throw new TypeError("public state must be an object");
  }

  const builds = [];
  if (Array.isArray(state.rollingAssetNames)) {
    for (const name of state.rollingAssetNames) {
      const build = buildFromAssetName(name);
      if (build !== null) builds.push(build);
    }
  }
  const milestoneAppcasts = state.publishedMilestoneAppcastXmls ?? [];
  if (!Array.isArray(milestoneAppcasts)) {
    throw new TypeError("published milestone appcasts must be an array");
  }
  const appcasts = [[state.rollingAppcastXml, "rolling appcast"]];
  for (const [index, xml] of milestoneAppcasts.entries()) {
    appcasts.push([xml, `published milestone appcast ${index + 1}`]);
  }
  for (const [xml, label] of appcasts) {
    if (xml !== null && xml !== undefined) builds.push(...buildsFromAppcast(xml, label));
  }

  let highWater = null;
  for (const build of builds) {
    if (highWater === null || BigInt(build) > BigInt(highWater)) highWater = build;
  }
  return highWater;
}

function assertSafeReleaseLocation(repository, tag) {
  if (
    typeof repository !== "string" ||
    !/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/.test(repository)
  ) {
    throw new TypeError("repository must be a safe owner/name value");
  }
  if (typeof tag !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(tag)) {
    throw new TypeError("release tag must be safe");
  }
}

function assertExactGitHubURL(value, expected, label) {
  if (typeof value !== "string") throw new TypeError(`${label} must be a URL string`);
  let parsed;
  try {
    parsed = new URL(value);
  } catch (error) {
    throw new TypeError(`${label} must be a valid URL`, { cause: error });
  }
  if (
    value !== expected ||
    parsed.href !== expected ||
    parsed.protocol !== "https:" ||
    parsed.hostname !== "github.com" ||
    parsed.port !== "" ||
    parsed.username !== "" ||
    parsed.password !== "" ||
    parsed.search !== "" ||
    parsed.hash !== ""
  ) {
    throw new TypeError(`${label} must exactly reference ${expected}`);
  }
}

function requireImmutableAsset(assetsByName, name, label) {
  const asset = assetsByName.get(name);
  if (!asset || asset.role !== "immutable") {
    throw new TypeError(`${label} must reference a sealed immutable asset: ${name}`);
  }
  return asset;
}

function validateReleasePayloadReferences({ appcastXml, repository, tag, manifest }) {
  const normalizedManifest = validateCandidateManifest(manifest);
  if (!normalizedManifest.sealed) throw new TypeError("release payload manifest must be sealed");
  assertSafeReleaseLocation(repository, tag);

  const assetsByName = new Map(normalizedManifest.assets.map((asset) => [asset.name, asset]));
  const releaseURL = `https://github.com/${repository}/releases/download/${tag}`;
  const enclosureName = `programa-macos-${normalizedManifest.build}.dmg`;
  const enclosureURL = `${releaseURL}/${enclosureName}`;
  const enclosureAsset = requireImmutableAsset(assetsByName, enclosureName, "appcast enclosure");

  const enclosures = parseAppcastEnclosures(appcastXml, "candidate appcast", {
    allowLegacyEnclosureVersion: false,
    requireSingleItem: true,
  });
  if (enclosures.length !== 1) {
    throw new TypeError("candidate appcast must contain exactly one enclosure");
  }
  const enclosure = enclosures[0];
  if (enclosure["sparkle:version"] !== normalizedManifest.build) {
    throw new TypeError("candidate appcast sparkle:version must equal the manifest build");
  }
  assertExactGitHubURL(enclosure.url, enclosureURL, "candidate appcast enclosure URL");
  if (enclosure.length !== String(enclosureAsset.size)) {
    throw new TypeError("candidate appcast enclosure length must equal the sealed DMG size");
  }
  const signature = enclosure["sparkle:edSignature"];
  const decodedSignature =
    typeof signature === "string" && CANONICAL_BASE64.test(signature)
      ? Buffer.from(signature, "base64")
      : null;
  if (
    decodedSignature === null ||
    decodedSignature.length !== 64 ||
    decodedSignature.toString("base64") !== signature
  ) {
    throw new TypeError(
      "candidate appcast enclosure signature must be canonical base64 encoding exactly 64 bytes",
    );
  }

  return {
    manifest: normalizedManifest,
    appcast: { url: enclosureURL, build: normalizedManifest.build },
  };
}

function assertCandidateMayPromote(candidate, highWater) {
  const validated = validateCandidateManifest(candidate);
  if (!validated.sealed) throw new TypeError("promotion candidate must be sealed");
  if (validated.schemaVersion !== 2) {
    throw new TypeError("promotion candidate must use the current schema version 2");
  }
  if (highWater === null || highWater === undefined) return "promote";
  assertCanonicalBuild(highWater, "public high-water build");

  const candidateBuild = BigInt(validated.build);
  const publicBuild = BigInt(highWater);
  if (candidateBuild < publicBuild) {
    throw new RangeError(
      `candidate build ${validated.build} is below public high-water build ${highWater}`,
    );
  }
  return candidateBuild === publicBuild ? "repair" : "promote";
}

function compareAssets(left, right) {
  const roleOrder = { immutable: 0, appcast: 1, "stable-alias": 2 };
  const roleDifference = roleOrder[left.role] - roleOrder[right.role];
  if (roleDifference !== 0) return roleDifference;
  if (left.name < right.name) return -1;
  if (left.name > right.name) return 1;
  return 0;
}

function getPromotionOrder(manifest) {
  const validated = validateCandidateManifest(manifest);
  if (!validated.sealed) throw new TypeError("promotion manifest must be sealed");
  if (validated.schemaVersion !== 2) {
    throw new TypeError("promotion manifest must use the current schema version 2");
  }
  return [...validated.assets].sort(compareAssets);
}

function createCandidateManifest(input) {
  assertPlainObject(input, "candidate manifest input");
  const allowedFields = new Set(ROOT_FIELDS);
  for (const key of Reflect.ownKeys(input)) {
    if (typeof key !== "string" || !allowedFields.has(key)) {
      throw new TypeError(`candidate manifest input has an unknown field: ${String(key)}`);
    }
  }
  if (Object.hasOwn(input, "schemaVersion") && input.schemaVersion !== 2) {
    throw new TypeError("new candidate manifests must use schemaVersion 2");
  }

  const candidate = validateCandidateManifest({
    schemaVersion: 2,
    sealed: true,
    targetSha: input.targetSha,
    version: input.version,
    build: input.build,
    assets: input.assets,
  });
  candidate.assets.sort(compareAssets);
  return candidate;
}

module.exports = {
  validateCandidateManifest,
  selectPromotionCandidate,
  derivePublicHighWater,
  validateReleasePayloadReferences,
  assertCandidateMayPromote,
  getPromotionOrder,
  createCandidateManifest,
  parseAppcastEnclosures,
  buildsFromAppcast,
};
