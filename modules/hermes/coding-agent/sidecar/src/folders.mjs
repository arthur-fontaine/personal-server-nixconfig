// request_folder's snapshot: a folder of this Mac copied, once, into the
// sidecar's memory, where the guest sees it under /host/<name> through
// Gondolin's ReadonlyProvider. Never a mount of the folder itself: what Pi
// reads is the copy made when Hermes said yes, nothing it does reaches the
// original, and the provider refuses every write (root's included).
//
// Only regular files and directories are copied: symlinks are left out (in
// the guest they would point at its own files, or at nothing), and so are
// sockets, devices, and what Hermes' account cannot read.

import fs from "node:fs";
import path from "node:path";

export const LIMITS = { files: 10000, bytes: 100 * 1024 * 1024 };

export class FolderTooLarge extends Error {
  name = "FolderTooLarge";
}

// [{rel, kind: "dir"|"file", size, mode}], walked without following links.
function walk(root, limits) {
  const entries = [];
  let bytes = 0;
  let skipped = 0;
  const visit = (rel) => {
    let names;
    try {
      names = fs.readdirSync(path.join(root, rel)).sort();
    } catch {
      skipped += 1;
      return;
    }
    for (const name of names) {
      const childRel = rel ? `${rel}/${name}` : name;
      let stat;
      try {
        stat = fs.lstatSync(path.join(root, childRel));
      } catch {
        skipped += 1;
        continue;
      }
      if (stat.isDirectory()) {
        entries.push({ rel: childRel, kind: "dir", mode: stat.mode });
        visit(childRel);
      } else if (stat.isFile()) {
        bytes += stat.size;
        entries.push({ rel: childRel, kind: "file", size: stat.size, mode: stat.mode });
      } else {
        skipped += 1;
        continue;
      }
      if (entries.length > limits.files || bytes > limits.bytes) {
        throw new FolderTooLarge(`more than ${limits.files} files or ${Math.round(limits.bytes / 1048576)} MB`);
      }
    }
  };
  visit("");
  return { entries, skipped };
}

function safeName(source, taken) {
  const base = path.basename(source).replace(/[^A-Za-z0-9._-]/g, "_").replace(/^\.+/, "") || "folder";
  let name = base;
  for (let n = 2; taken(name); n++) name = `${base}-${n}`;
  return name;
}

// Copies `source` (an absolute, resolved directory) into `provider` (the
// MemoryProvider behind /host) as /<name>; returns {name, files, skipped}.
export function copyFolder(source, provider, limits = LIMITS) {
  if (!path.isAbsolute(source) || fs.realpathSync(source) !== source || !fs.statSync(source).isDirectory()) {
    throw new Error("not a resolved directory");
  }
  const { entries, skipped: unread } = walk(source, limits);
  const exists = (name) => {
    try {
      provider.statSync(`/${name}`);
      return true;
    } catch {
      return false;
    }
  };
  const name = safeName(source, exists);
  const target = `/${name}`;
  provider.mkdirSync(target, { recursive: true });
  let files = 0;
  let skipped = unread;
  for (const entry of entries) {
    const dest = `${target}/${entry.rel}`;
    if (entry.kind === "dir") {
      provider.mkdirSync(dest, { recursive: true });
      continue;
    }
    let data;
    try {
      data = fs.readFileSync(path.join(source, entry.rel));
    } catch {
      skipped += 1;
      continue;
    }
    provider.writeFileSync(dest, data);
    // Executables stay executable (a script Pi is to read may be run).
    provider.chmodSync(dest, entry.mode & 0o111 ? 0o755 : 0o644);
    files += 1;
  }
  return { name, files, skipped };
}
