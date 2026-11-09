"use strict";

// scripts/source-fingerprint.sh must print the same hash for the same commit whether or
// not the ghostty submodule is checked out: CI jobs that skip `submodules: recursive`
// compare against an app built from a full checkout.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const SCRIPT = path.join(__dirname, "source-fingerprint.sh");

function git(cwd, ...args) {
  return execFileSync(
    "git",
    ["-c", "protocol.file.allow=always", "-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t", ...args],
    { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  ).trim();
}

function fingerprint(root) {
  return execFileSync("bash", [SCRIPT, root], { encoding: "utf8" }).trim();
}

function makeRepos() {
  const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "src-fp-")));
  const sub = path.join(tmp, "ghostty-src");
  fs.mkdirSync(sub);
  git(sub, "init", "-q", "-b", "main");
  fs.writeFileSync(path.join(sub, "build.zig"), "pub fn main() void {}\n");
  git(sub, "add", ".");
  git(sub, "commit", "-q", "-m", "sub");

  const parent = path.join(tmp, "parent");
  fs.mkdirSync(path.join(parent, "Sources"), { recursive: true });
  git(parent, "init", "-q", "-b", "main");
  fs.writeFileSync(path.join(parent, "Sources", "App.swift"), "let x = 1\n");
  git(parent, "submodule", "add", "-q", sub, "ghostty");
  git(parent, "add", ".");
  git(parent, "commit", "-q", "-m", "parent");

  const bare = path.join(tmp, "bare");
  git(parent, "clone", "-q", "--no-recurse-submodules", parent, bare);
  return { tmp, parent, bare };
}

test("an uninitialized ghostty submodule hashes the same as a clean checkout of the pin", (t) => {
  const { tmp, parent, bare } = makeRepos();
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

  assert.equal(fs.readdirSync(path.join(bare, "ghostty")).length, 0);
  assert.equal(fingerprint(bare), fingerprint(parent));
});

test("local edits inside the ghostty submodule change the hash", (t) => {
  const { tmp, parent } = makeRepos();
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

  const before = fingerprint(parent);
  fs.appendFileSync(path.join(parent, "ghostty", "build.zig"), "// edit\n");
  assert.notEqual(fingerprint(parent), before);
});

test("app source edits change the hash", (t) => {
  const { tmp, bare } = makeRepos();
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

  const before = fingerprint(bare);
  fs.appendFileSync(path.join(bare, "Sources", "App.swift"), "let y = 2\n");
  assert.notEqual(fingerprint(bare), before);
});
