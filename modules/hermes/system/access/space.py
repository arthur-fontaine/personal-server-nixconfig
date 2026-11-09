"""hermes-space: this Mac's room, for Hermes and its owner. Nothing here deletes.

    hermes-space [--json]       free disk and memory, what Hermes created that
                                freezes soon (by size), the frozen leftovers
    space.py weekly CONFIG      (root, weekly) one Telegram line to the owner
                                when the frozen leftovers pass a threshold

The file lists come from hermes-freeze's space report (freeze.py), written at
each scan; memory is read live (vm_stat, sysctl).
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

REPORT = "/var/db/hermes-space/report.json"
GB = 1024 ** 3


def size(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024


def until(seconds):
    seconds = max(0, int(seconds))
    hours, minutes = divmod(seconds // 60, 60)
    return f"{hours} h {minutes:02d} min" if hours else f"{minutes} min"


def home_short(path, home):
    return "~" + path[len(home):] if home and path.startswith(home + "/") else path


def memory():
    """Total and available memory in bytes (free + inactive + speculative + purgeable pages)."""
    try:
        total = int(subprocess.run(["/usr/sbin/sysctl", "-n", "hw.memsize"], capture_output=True, text=True,
                                   timeout=5).stdout.strip())
        out = subprocess.run(["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    page = int((re.search(r"page size of (\d+) bytes", out) or [0, 16384])[1])
    pages = {m.group(1).strip().lower(): int(m.group(2)) for m in re.finditer(r"^(.+?):\s+(\d+)\.?$", out, re.M)}
    free = sum(pages.get(k, 0) for k in ("pages free", "pages inactive", "pages speculative", "pages purgeable"))
    return {"total": total, "available": free * page}


def load(path=REPORT):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def show(report, mem, now, home=""):
    lines = []
    disk = (report or {}).get("disk") or {}
    if disk:
        lines.append(f"Disk: {size(disk['free'])} free of {size(disk['total'])}.")
    if mem:
        lines.append(f"Memory: {size(mem['available'])} available of {size(mem['total'])}.")
    if report is None:
        lines.append("No space report yet (hermes-freeze writes it every few minutes).")
        return "\n".join(lines)
    age = now - report.get("updated_at", now)
    upcoming = report.get("upcoming") or {}
    lines.append("")
    lines.append(f"Freezing soon, still yours to delete ({size(upcoming.get('bytes'))} in "
                 f"{upcoming.get('files', 0)} files):")
    for g in (upcoming.get("groups") or [])[:15]:
        lines.append(f"  {size(g['bytes']):>9}  {home_short(g['path'], home)}  ({g['files']} files, the first "
                     f"freezes in {until(g['freezes_at'] - now)})")
    if not upcoming.get("groups"):
        lines.append("  nothing")
    frozen = report.get("frozen") or {}
    lines.append("")
    lines.append(f"Frozen leftovers, now the owner's: Hermes can no longer delete them "
                 f"({size(frozen.get('bytes'))} in {frozen.get('files', 0)} files):")
    for g in (frozen.get("groups") or [])[:15]:
        lines.append(f"  {size(g['bytes']):>9}  {home_short(g['path'], home)}  ({g['files']} files)")
    if not frozen.get("groups"):
        lines.append("  nothing")
    if age > 3600:
        lines.append(f"\n(The report is {until(age)} old: is hermes-freeze running?)")
    return "\n".join(lines)


def read_env(path):
    values = {}
    try:
        with open(path) as f:
            for row in f:
                key, sep, value = row.partition("=")
                if sep:
                    values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def weekly_line(report, threshold, home=""):
    frozen = (report or {}).get("frozen") or {}
    if frozen.get("bytes", 0) < threshold:
        return ""
    groups = frozen.get("groups") or []
    biggest = ", ".join(f"{home_short(g['path'], home)} ({size(g['bytes'])})" for g in groups[:3])
    return (f"Hermes' frozen leftovers take {size(frozen['bytes'])} ({frozen.get('files', 0)} files)"
            + (f", mostly {biggest}" if biggest else "") + ". They are yours now and nothing deletes them: "
            "run `hermes-space` to see them, and delete what you don't need.")


def weekly(config):
    line = weekly_line(load(config.get("report", REPORT)), config["threshold"], config.get("home", ""))
    if not line:
        return False
    values = read_env(config["secrets_file"])
    token = values.get("TELEGRAM_BOT_TOKEN", "")
    owner = values.get("TELEGRAM_ALLOWED_USERS", "").split(",")[0].strip()
    if not token or not owner:
        print("hermes-space: the owner was not told: no Telegram bot or owner in the secrets file", file=sys.stderr)
        return False
    api = (config.get("telegram_api") or "https://api.telegram.org").rstrip("/")
    data = urllib.parse.urlencode({"chat_id": owner, "text": line}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{api}/bot{token}/sendMessage", data=data), timeout=10) as r:
            r.read()
    except Exception as error:  # noqa: BLE001
        # Not the error's text: a URL in it would carry the token.
        print(f"hermes-space: could not tell the owner ({type(error).__name__})", file=sys.stderr)
        return False
    return True


def main(argv):
    if argv[:1] == ["weekly"]:
        with open(argv[1]) as f:
            weekly(json.load(f))
        return 0
    report, mem = load(os.environ.get("HERMES_SPACE_REPORT", REPORT)), memory()
    if "--json" in argv:
        print(json.dumps({"report": report, "memory": mem}))
    else:
        print(show(report, mem, time.time(), os.environ.get("HERMES_SPACE_HOME", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
