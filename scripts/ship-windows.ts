import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { deriveReleaseBuildIdentity } from "./release_build_identity.js";

const repo = "darkroomengineering/programa";
const release = "rolling";
const main = "origin/main";
const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const { env } = process;
const dry = env.SHIP_DRY_RUN === "true";

function run(args: string[], capture = false) {
  const stdio = capture ? "pipe" : "inherit";
  const result = Bun.spawnSync(args, { stdout: stdio, stderr: stdio });
  const error = result.stderr?.toString().trim();
  if (!result.success) throw new Error(`${args[0]} exited ${result.exitCode}: ${error}`);
  if (error) console.error(error);
  return result.stdout?.toString().trim() ?? "";
}

const git = (...args: string[]) => run(["git", ...args], true);
const gh = (...args: string[]) => run(["gh", "release", ...args, "--repo", repo]);
const sha256 = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex");

function assertCurrentMain(commit: string) {
  git("fetch", "--quiet", "origin", "main");
  if (git("rev-parse", main) !== commit) throw new Error("Programa main moved during the dry run.");
}

function buildIdentity() {
  const versionInput = dry ? "" : (env.SHIP_RUN_VERSION ?? "");
  const buildInput = dry ? "" : (env.SHIP_RUN_BUILD ?? "");
  const commitInput = dry ? "" : (env.SHIP_RUN_COMMIT ?? "");
  const pinned = Boolean(versionInput || buildInput || commitInput);
  if (pinned && (!versionInput || !buildInput || !commitInput)) {
    throw new Error("Supply version, build and commit together.");
  }
  const commit = commitInput || git("rev-parse", main);
  if (!/^[0-9a-f]{40}$/.test(commit)) throw new Error("Commit must be a full lowercase SHA.");
  git("merge-base", "--is-ancestor", commit, main);

  const project = git("show", `${main}:GhosttyTabs.xcodeproj/project.pbxproj`);
  const versions = new Set([...project.matchAll(/MARKETING_VERSION = ([0-9.]+);/g)].map((match) => match[1]));
  const version = versionInput || (versions.size === 1 ? ([...versions][0] ?? "") : "");
  if (!versionPattern.test(version)) throw new Error("Expected a single canonical major.minor.patch version.");
  const build =
    buildInput ||
    deriveReleaseBuildIdentity({
      eventName: env.GITHUB_EVENT_NAME,
      upstreamRunId: undefined,
      upstreamRunAttempt: undefined,
      workflowRunId: env.GITHUB_RUN_ID,
      workflowRunAttempt: env.GITHUB_RUN_ATTEMPT,
    });
  if (!/^[1-9]\d*$/.test(build)) throw new Error("Build must be a canonical positive decimal.");
  return { version, build, commit, pinned };
}

const mode = process.argv[2];
if (mode !== "build" && mode !== "publish") throw new Error("Expected build or publish.");
if (!dry && (env.GITHUB_REPOSITORY !== repo || env.GITHUB_REF !== "refs/heads/main")) {
  throw new Error("Release builds must be dispatched from Programa main. Use dry-run on a branch.");
}
if (mode === "publish" && dry) throw new Error("A dry run cannot publish.");
if (!env.RUNNER_TEMP) throw new Error("RUNNER_TEMP is required.");

const { version, build, commit, pinned } = buildIdentity();
const output = join(env.RUNNER_TEMP, `shipit-windows-${build}`);
const feed = join(output, "feed");
const installers = join(output, "installers");
const alias = join(installers, "Programa-x64-setup.exe");
const versioned = join(installers, `Programa-${version}-${build}-x64-setup.exe`);

if (mode === "build") {
  if (dry) assertCurrentMain(commit);
  git("checkout", "--detach", commit);
  const config: unknown = JSON.parse(readFileSync("ship.json", "utf8"));
  const windows = config && typeof config === "object" && "windows" in config ? config.windows : undefined;
  if (
    !windows ||
    typeof windows !== "object" ||
    !("vpk" in windows) ||
    typeof windows.vpk !== "string" ||
    !versionPattern.test(windows.vpk)
  ) {
    throw new Error("ship.json must pin windows.vpk to a canonical version.");
  }
  if (!dry && "signing" in windows && windows.signing !== null) {
    throw new Error("The Velopack lane requires a signing implementation before publishing a signed release.");
  }
  console.warn("Building an unsigned Velopack installer.");
  mkdirSync(feed, { recursive: true });
  mkdirSync(installers);
  const published = join(env.RUNNER_TEMP, "programa-windows-publish");
  delete env.PROGRAMA_WINDOWS_SIGN_SCRIPT;
  run([
    "pwsh",
    "-NoProfile",
    "-NonInteractive",
    "-File",
    resolve("scripts/build-windows.ps1"),
    "-Version",
    version,
    "-Build",
    build,
    "-Commit",
    commit,
    "-OutputDirectory",
    join(env.RUNNER_TEMP, "programa-windows-exe"),
    "-PublishDirectory",
    published,
  ]);

  const tools = join(env.RUNNER_TEMP, "programa-vpk");
  run(["dotnet", "tool", "install", "vpk", "--version", windows.vpk, "--tool-path", tools]);
  run([
    join(tools, "vpk.exe"),
    "pack",
    "--packId",
    "Programa",
    "--packTitle",
    "Programa",
    "--packVersion",
    `${version}-build.${build}`,
    "--packDir",
    published,
    "--mainExe",
    "programa.exe",
    "--runtime",
    "win-x64",
    "--channel",
    "win",
    "--noPortable",
    "--outputDir",
    feed,
  ]);

  const setups = readdirSync(feed).filter((name) => name.endsWith("-Setup.exe"));
  const [setupName] = setups;
  if (!setupName || setups.length !== 1) throw new Error("Expected one Velopack setup executable.");
  const setup = join(feed, setupName);
  copyFileSync(setup, alias);
  copyFileSync(setup, versioned);
  const hash = sha256(setup);
  if (sha256(alias) !== hash || sha256(versioned) !== hash) throw new Error("Installer copies differ.");
  console.log(`Windows installer SHA-256: ${hash}`);
  if (!existsSync(join(feed, "releases.win.json")) || !readdirSync(feed).some((name) => name.endsWith("-full.nupkg"))) {
    throw new Error("Velopack did not produce a complete update feed.");
  }
  if (dry) {
    assertCurrentMain(commit);
    console.log(`Dry run complete for ${version} build ${build}. No release assets uploaded.`);
  }
} else {
  const files = readdirSync(feed).filter((name) => !name.endsWith("-Setup.exe"));
  const packages = files.filter((name) => name.endsWith(".nupkg")).map((name) => join(feed, name));
  const mutable = files.filter((name) => !name.endsWith(".nupkg")).map((name) => join(feed, name));
  try {
    run(["gh", "release", "view", release, "--json", "isDraft", "--repo", repo], true);
  } catch (error) {
    if (!(error instanceof Error && /release not found/i.test(error.message))) throw error;
    const notes = git("show", "-s", "--format=%s", commit);
    gh("create", release, "--draft", "--target", commit, "--title", `Programa ${version} (${build})`, "--notes", notes);
  }
  // An installed copy can read the updated feed as soon as it is uploaded.
  gh("upload", release, versioned, ...packages, "--clobber");
  gh("upload", release, alias, ...mutable, "--clobber");
  if (!pinned) {
    run(["gh", "auth", "setup-git", "--hostname", "github.com", "--force"]);
    const tag = `v${version}-${build}`;
    git(
      "-c",
      "user.name=github-actions[bot]",
      "-c",
      "user.email=41898282+github-actions[bot]@users.noreply.github.com",
      "-c",
      "tag.gpgsign=false",
      "tag",
      "-a",
      tag,
      commit,
      "-m",
      `Programa ${version} build ${build} (windows)`,
    );
    run(["git", "push", "origin", `refs/tags/${tag}`]);
    gh("edit", release, "--draft=false");
  }
}
