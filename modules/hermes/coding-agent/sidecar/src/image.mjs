// The guest image: Alpine with Node, git and Pi, built by Gondolin's own
// builder (`gondolin build`, here its buildAssets API) on the server, once per
// configuration, into Hermes' state. No Docker: postBuild.commands would need
// one on macOS (build/index.js, shouldUseContainer), so nothing runs in the
// rootfs at build time; Pi arrives as a finished node_modules tree
// (postBuild.copy) that Nix installed for linux-arm64 from ../pi's lockfile,
// with Pi's settings.json and extensions.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

// Pi's tree, in the guest.
export const PI_DIR = "/opt/pi";
export const PI_CLI = `${PI_DIR}/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js`;

export function buildConfig({ guestDir, alpineVersion = "3.23.7" }) {
  return {
    arch: "aarch64",
    distro: "alpine",
    alpine: {
      version: alpineVersion,
      kernelPackage: "linux-virt",
      kernelImage: "vmlinuz-virt",
      rootfsPackages: [
        // Gondolin's own: the kernel and its modules, entropy, the rootfs tools.
        "linux-virt",
        "rng-tools",
        "e2fsprogs",
        // Pi's: its runtime (>= 22.19), its bash tool, its grep and find, git.
        "nodejs-current",
        "bash",
        "ca-certificates",
        "git",
        "ripgrep",
        "fd",
      ],
      initramfsPackages: [],
    },
    rootfs: { label: "gondolin-root" },
    postBuild: { copy: [{ src: guestDir, dest: PI_DIR }] },
  };
}

// The image's identity: its configuration, which names the guest tree by its
// Nix store path, so a new Pi or package list is a new image.
export function imageId(config) {
  return crypto.createHash("sha256").update(JSON.stringify(config)).digest("hex").slice(0, 16);
}

export function imageDir(stateDir, config) {
  return path.join(stateDir, "images", imageId(config));
}

function stageWritable(source, target) {
  fs.rmSync(target, { recursive: true, force: true });
  fs.cpSync(source, target, { recursive: true, verbatimSymlinks: true });
  const walk = (p) => {
    const stat = fs.lstatSync(p);
    if (stat.isSymbolicLink()) return;
    fs.chmodSync(p, stat.isDirectory() ? 0o755 : (stat.mode & 0o111 ? 0o755 : 0o644));
    if (stat.isDirectory()) for (const entry of fs.readdirSync(p)) walk(path.join(p, entry));
  };
  walk(target);
}

// Builds the image unless it is there; a build lands in a temporary
// directory first, so a failed one never looks finished.
export async function ensureImage({ stateDir, guestDir, buildAssets, verifyAssets, log = () => {} }) {
  const config = buildConfig({ guestDir });
  const dir = imageDir(stateDir, config);
  if (fs.existsSync(path.join(dir, "manifest.json")) && verifyAssets(dir)) return { dir, built: false };
  fs.mkdirSync(path.dirname(dir), { recursive: true });
  const partial = `${dir}.partial-${process.pid}`;
  fs.rmSync(partial, { recursive: true, force: true });
  log(`building the guest image ${path.basename(dir)}`);
  // postBuild.copy keeps each directory's mode, and the Nix store's are
  // read-only, so a writable copy goes in instead of the store path.
  const staged = `${partial}-guest`;
  try {
    stageWritable(guestDir, staged);
    const copy = { ...config, postBuild: { copy: [{ src: staged, dest: PI_DIR }] } };
    await buildAssets(copy, { outputDir: partial, configDir: stateDir, verbose: true });
    fs.rmSync(dir, { recursive: true, force: true });
    fs.renameSync(partial, dir);
  } catch (error) {
    fs.rmSync(partial, { recursive: true, force: true });
    throw error;
  } finally {
    fs.rmSync(staged, { recursive: true, force: true });
  }
  // Older images are only disk space once a new one exists.
  for (const entry of fs.readdirSync(path.dirname(dir))) {
    const other = path.join(path.dirname(dir), entry);
    if (other !== dir && !entry.includes(".partial-")) fs.rmSync(other, { recursive: true, force: true });
  }
  return { dir, built: true };
}
