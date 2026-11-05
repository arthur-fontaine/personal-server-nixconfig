#!/usr/bin/env node
// hermes-sandbox run <session.json>   one Pi session, JSON lines on stdio
// hermes-sandbox build-image          build the guest image if it is missing
// hermes-sandbox smoke                boot the guest, check its isolation
//
// The Nix wrapper sets HERMES_SANDBOX_GUEST (Pi's tree for the guest) and
// puts QEMU and the image builder's tools on PATH.

import fs from "node:fs";
import path from "node:path";

import { Peer } from "./protocol.mjs";
import { Session } from "./session.mjs";
import { ensureImage } from "./image.mjs";
import { smoke } from "./smoke.mjs";

function stateDir() {
  return process.env.HERMES_SANDBOX_STATE ?? path.join(process.env.HOME, ".hermes", "sandbox");
}

function guestDir() {
  const dir = process.env.HERMES_SANDBOX_GUEST;
  if (!dir || !fs.existsSync(dir)) throw new Error("HERMES_SANDBOX_GUEST does not name Pi's guest tree");
  return dir;
}

async function main(argv) {
  const [command, ...rest] = argv;
  // Gondolin keeps its downloads under XDG_CACHE_HOME (~/.cache by default),
  // where Hermes' account may not keep writing: its state, then.
  process.env.XDG_CACHE_HOME ??= path.join(stateDir(), "cache");
  const gondolin = await import("@earendil-works/gondolin");
  if (command === "run") {
    const config = JSON.parse(fs.readFileSync(rest[0], "utf8"));
    const peer = new Peer(process.stdin, process.stdout);
    const session = new Session(
      { stateDir: stateDir(), guestDir: guestDir(), ...config },
      { gondolin, peer },
    );
    // The plugin going away (Hermes restarting) ends the session.
    peer.onClose = () => session.stop("stopped");
    peer.on("stop", () => session.stop("stopped"));
    peer.on("status", () => peer.send("status", { phase: session.phase, ...session.progress.snapshot() }));
    peer.on("grant", ({ grant }) => {
      const added = session.policy.grants.add(grant);
      session.audit({ event: "grant", grant: added });
      peer.send("grants", { grants: session.policy.grants.list() });
    });
    peer.on("revoke", ({ grant }) => {
      session.policy.grants.revoke(grant);
      session.audit({ event: "revoke", grant });
      peer.send("grants", { grants: session.policy.grants.list() });
    });
    const result = await session.run();
    process.exitCode = result.status === "finished" ? 0 : 1;
    // stdin stays open while the plugin runs; nothing is left to read.
    process.stdin.destroy();
    return;
  }
  if (command === "build-image") {
    const { dir, built } = await ensureImage({
      stateDir: stateDir(),
      guestDir: guestDir(),
      buildAssets: gondolin.buildAssets,
      verifyAssets: gondolin.verifyAssets,
      log: (message) => process.stderr.write(`${message}\n`),
    });
    process.stdout.write(`${built ? "built" : "already built"}: ${dir}\n`);
    return;
  }
  if (command === "smoke") {
    const ok = await smoke({ gondolin, stateDir: stateDir(), guestDir: guestDir() });
    process.exitCode = ok ? 0 : 1;
    return;
  }
  process.stderr.write("usage: hermes-sandbox run <session.json> | build-image | smoke\n");
  process.exitCode = 2;
}

main(process.argv.slice(2)).catch((error) => {
  process.stderr.write(`hermes-sandbox: ${error?.stack ?? error}\n`);
  process.exitCode = 1;
});
