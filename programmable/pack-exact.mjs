#!/usr/bin/env node
// Packs the request with exact-version execution evidence. The evidence is inside the source bundle and the bundle
// decides the CREATE2 addresses, so this loops: build -> pack -> export the exact targets -> run every test on a
// mainnet fork -> collect evidence, until the regenerated evidence equals the evidence that was packed.
//
// Usage: the build-protected.mjs environment, plus pinned LAUNCH_NONCE, VALID_AFTER, DEADLINE, START_TICK and
// FORK_BLOCK so every iteration describes the same launch:  node programmable/pack-exact.mjs

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const env = process.env;
for (const k of ["PL_DIR", "SOLCJS_DIR", "ETH_RPC_URL", "LAUNCH_NONCE", "VALID_AFTER", "DEADLINE", "START_TICK", "FORK_BLOCK"]) {
  if (!env[k]) { console.error("pack-exact: set " + k); process.exit(1); }
}
const cli = path.join(env.PL_DIR, "bin/programmable-launch.mjs");
const shim = ["--import", pathToShim()];
function pathToShim() { return "file:///" + path.join(repo, "programmable/win-dir-fsync-shim.mjs").replace(/\\/g, "/").replace(/^\/+/, ""); }
const run = (cmd, args, cwd = repo, stdio = "inherit") => execFileSync(cmd, args, { cwd, env, stdio, maxBuffer: 1 << 28 });
const read = (p) => (existsSync(p) ? readFileSync(p) : Buffer.alloc(0));

for (let i = 1; i <= 4; i++) {
  console.error(`pack-exact: iteration ${i}`);
  run(process.execPath, ["programmable/build-protected.mjs"]);
  run(process.execPath, [...shim, cli, "pack", "--config", "protected-launch.config.json", "--output", "launch.json"],
    path.join(repo, "protected"), ["ignore", "ignore", "inherit"]);
  run(process.execPath, ["programmable/export-exact-fixture.mjs"]);
  rmSync(path.join(repo, "evidence/exact"), { recursive: true, force: true });
  mkdirSync(path.join(repo, "evidence/exact"), { recursive: true });
  const forgeOut = path.join(os.tmpdir(), "ciphra-forge-tests.json");
  writeFileSync(forgeOut, run("forge", ["test", "--json"], repo, ["ignore", "pipe", "inherit"]));
  run(process.execPath, ["programmable/collect-exact-evidence.mjs", forgeOut]);
  const same = ["exact-version.json", "tests.json"].every((f) => read(path.join(repo, "protected/ciphra/evidence", f)).equals(
    read(path.join(repo, "evidence", f === "tests.json" ? "forge-tests.json" : f))));
  if (same) {
    run(process.execPath, [...shim, cli, "validate", "launch.json", "--config", "protected-launch.config.json"],
      path.join(repo, "protected"), ["ignore", "ignore", "inherit"]);
    console.log(JSON.stringify({ ok: true, iterations: i, fixture: JSON.parse(readFileSync(path.join(repo, "test/fixtures/exact-launch.json"))).launchJsonSha256 }));
    process.exit(0);
  }
}
console.error("pack-exact: evidence did not converge");
process.exit(1);
