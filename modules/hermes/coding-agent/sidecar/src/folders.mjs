// request_folder's snapshot: a folder of this Mac copied, once, into the
// sidecar's memory, where the guest sees it under /host/<name> through
// Gondolin's ReadonlyProvider. Never a mount of the folder itself: what Pi
// reads is the copy made when Hermes said yes, nothing it does reaches the
// original, and the provider refuses every write (root's included).
//
// Regular files and directories are copied, and the symlinks that resolve
// inside the folder (as relative links to the copy); a link out of it, or to
// nothing, is left out, and so are sockets, devices, and what Hermes' account
// cannot read. The plugin has refused secret locations and checked these
// limits before asking (hermes-plugin/actions.py MAX_FOLDER_*).

import fs from "node:fs";
import path from "node:path";

export const LIMITS = { files: 20000, bytes: 200 * 1024 * 1024 };

export class FolderTooLarge extends Error {
  name = "FolderTooLarge";
}

// [{rel, kind: "dir"|"file"|"link", size, mode, target}], walked without
// following links.
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
      } else if (stat.isSymbolicLink()) {
        const target = inside(root, childRel);
        if (target === null) {
          skipped += 1;
          continue;
        }
        entries.push({ rel: childRel, kind: "link", target });
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

// A link's target relative to the link, when its real path is in `root`
// (itself excluded); else null. The real path, not the link's text, so the
// copy points where the original resolves.
function inside(root, rel) {
  let real;
  try {
    real = fs.realpathSync(path.join(root, rel));
  } catch {
    return null;
  }
  if (!real.startsWith(root + path.sep)) return null;
  return path.relative(path.dirname(path.join(root, rel)), real);
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
    if (entry.kind === "link") {
      provider.symlinkSync(entry.target, dest);
      files += 1;
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
