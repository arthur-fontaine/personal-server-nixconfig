"""Freeze the files Hermes created more than `freeze_after` seconds ago.

A frozen entry is handed to the administrator and carries an ACL that denies
the Hermes user every write. An explicit deny on the node wins over write
access to its directory, so a frozen file cannot be written, renamed or
deleted even inside a directory Hermes owns. Hermes keeps read access, so it
can still copy the file. A frozen directory still accepts new entries.

Birth times can be set by a file's owner, so a ledger keeps the first time
each inode was seen, and the earlier of the two counts.
"""

import json
import os
import pwd
import stat
import subprocess
import sys
import time

FILE_DENY = "deny write,delete,append,writeattr,writeextattr,writesecurity,chown"
DIR_DENY = "deny delete,writeattr,writeextattr,writesecurity,chown"
DIR_ALLOW = "allow list,search,add_file,add_subdirectory,delete_child,readattr,readextattr,readsecurity"


def walk(root, excluded):
    """Yield (path, lstat) for root and everything under it, staying on one device."""
    try:
        root_st = os.lstat(root)
    except FileNotFoundError:
        return
    stack = [(root, root_st)]
    while stack:
        path, st = stack.pop()
        yield path, st
        if not stat.S_ISDIR(st.st_mode):
            continue
        try:
            names = os.listdir(path)
        except OSError:
            continue
        for name in names:
            child = os.path.join(path, name)
            if child in excluded:
                continue
            try:
                child_st = os.lstat(child)
            except OSError:
                continue
            if child_st.st_dev != root_st.st_dev:
                continue
            stack.append((child, child_st))


def freeze(path, st, agent, admin_uid):
    is_dir = stat.S_ISDIR(st.st_mode)
    os.lchown(path, admin_uid, st.st_gid)
    if not stat.S_ISLNK(st.st_mode):
        mode = stat.S_IMODE(st.st_mode) & ~0o022
        os.chmod(path, mode | (0o055 if is_dir else 0o044))
    aces = [DIR_DENY, DIR_ALLOW] if is_dir else [FILE_DENY]
    for ace in aces:
        subprocess.run(["/bin/chmod", "-h", "+a", f"user:{agent} {ace}", path], check=True)


def scan(config, now):
    agent = pwd.getpwnam(config["agent_user"])
    admin = pwd.getpwnam(config["admin_user"])
    ledger_path = config["ledger"]
    try:
        with open(ledger_path) as f:
            ledger = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        ledger = {}

    seen = {}
    frozen = 0
    for root in config["roots"]:
        excluded = set(root.get("exclude", []))
        for path, st in walk(root["path"], excluded):
            if st.st_uid != agent.pw_uid or path == root["path"]:
                continue
            key = f"{st.st_dev}:{st.st_ino}"
            first_seen = ledger.get(key, now)
            seen[key] = first_seen
            created = min(st.st_birthtime, first_seen)
            if now - created < config["freeze_after"]:
                continue
            try:
                freeze(path, st, agent.pw_name, admin.pw_uid)
                frozen += 1
                seen.pop(key)
            except (OSError, subprocess.CalledProcessError) as err:
                print(f"hermes-freeze: {path}: {err}", file=sys.stderr)

    tmp = ledger_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(seen, f)
    os.replace(tmp, ledger_path)
    return frozen


def main():
    with open(sys.argv[1]) as f:
        config = json.load(f)
    frozen = scan(config, time.time())
    if frozen:
        print(f"hermes-freeze: froze {frozen} entries")


if __name__ == "__main__":
    main()
