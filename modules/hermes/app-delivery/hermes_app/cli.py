"""hermes-app: build the Hermes iOS app on this server, sign it, install it on
the owner's devices over the network, and keep it signed.

    hermes-app devices            the devices Xcode can install on, with their last install (JSON)
    hermes-app status             delivery.json: what the App topic's `devices` state shows
    hermes-app install [--device UDID]... [--reason TEXT] [--wait]
                                  queue a build and install, start the job, return at once
    hermes-app run                the job (launchd): queued installs, then the refreshes due

Signing is Xcode's automatic signing (`xcodebuild -allowProvisioningUpdates
-allowProvisioningDeviceRegistration`) with the Apple Account signed in to
Xcode on Hermes' account; installing is `xcrun devicectl device install app`,
which reaches a paired device over the local network. A free personal team's
profile lasts 7 days, so `run` rebuilds and reinstalls what expires within
`refresh_before_hours`, with fresh profiles. Everything runs as Hermes in its
GUI session (a launchd agent), where its login keychain, holding the signing
key and Xcode's account, is unlocked.

The settings come from a JSON file (HERMES_APP_CONFIG, written by Nix:
modules/hermes/app/default.nix); tools are looked up on PATH unless it names
them. Standard library only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from pathlib import Path

ICON = "HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
PET_DIR = "Pet"
PET_FILES = ("pet.json", "spritesheet.webp")
# Where Xcode caches profiles: Xcode 16 and later, then the older place.
PROFILE_DIRS = ("Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles")
KEEP_DONE = 30
KEEP_LOGS = 5


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(moment: dt.datetime | None) -> str | None:
    if moment is None:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=dt.timezone.utc)
    return moment.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def parse_iso(text: str | None) -> dt.datetime | None:
    if not text:
        return None
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))


class AppError(Exception):
    pass


class Config:
    def __init__(self, data: dict):
        home = Path(data.get("home") or Path.home())
        self.home = home
        self.source = data.get("source") or ""
        self.scheme = data.get("scheme", "HermesApp")
        self.team_id = data.get("team_id") or None
        self.paid = bool(data.get("paid", False))
        self.bundle_id_prefix = data.get("bundle_id_prefix") or None
        self.refresh_before = dt.timedelta(hours=float(data.get("refresh_before_hours", 48)))
        self.state_dir = Path(data.get("state_dir") or home / ".hermes/app")
        self.cache_dir = Path(data.get("cache_dir") or home / "Library/Caches/hermes-app")
        self.secrets_file = data.get("secrets_file") or "/etc/hermes/secrets.env"
        self.label = data.get("launchd_label", "")
        self.tools = {"xcrun": "xcrun", "xcodebuild": "xcodebuild", "xcodegen": "xcodegen",
                      "security": "security", "defaults": "defaults", "launchctl": "launchctl",
                      **(data.get("tools") or {})}
        self.install_timeout = int(data.get("install_timeout", 900))
        self.build_timeout = int(data.get("build_timeout", 5400))

    @classmethod
    def load(cls) -> "Config":
        path = os.environ.get("HERMES_APP_CONFIG")
        return cls(json.loads(Path(path).read_text()) if path else {})

    @property
    def delivery(self) -> Path:
        return self.state_dir / "delivery.json"

    @property
    def requests(self) -> Path:
        return self.state_dir / "requests"

    @property
    def done(self) -> Path:
        return self.requests / "done"

    @property
    def pet(self) -> Path:
        return self.state_dir / "pet"


# ── State ───────────────────────────────────────────────────────────────────

def write_json(path: Path, data) -> None:
    # Atomic, as app-backend reads delivery.json whenever its mtime changes.
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2, default=str) + "\n")
    os.replace(tmp, path)


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def load_state(cfg: Config) -> dict:
    state = read_json(cfg.delivery, None) or {}
    state.setdefault("v", 1)
    state.setdefault("devices", [])
    state.setdefault("running", None)
    return state


def save_state(cfg: Config, state: dict) -> None:
    state["updated"] = iso(now())
    expiries = [parse_iso(d.get("profile_expires")) for d in state["devices"] if d.get("chosen")]
    expiries = [e for e in expiries if e]
    state["next_refresh"] = iso(min(expiries) - cfg.refresh_before) if expiries else None
    write_json(cfg.delivery, state)


def device_entry(state: dict, udid: str) -> dict:
    for device in state["devices"]:
        if device["id"] == udid:
            return device
    device = {"id": udid, "name": None, "model": None, "os": None, "reachable": False,
              "chosen": False, "last_install": None, "profile_expires": None}
    state["devices"].append(device)
    return device


# ── Tools ───────────────────────────────────────────────────────────────────

def run_tool(cfg: Config, name: str, *args, timeout: int = 300, env: dict | None = None,
             log=None, cwd: str | None = None) -> subprocess.CompletedProcess:
    command = [cfg.tools[name], *args]
    try:
        return subprocess.run(command, capture_output=log is None, stdout=log, stderr=subprocess.STDOUT if log else None,
                              text=True, timeout=timeout, env=env, cwd=cwd)
    except FileNotFoundError as error:
        raise AppError(f"{cfg.tools[name]} not found: {error}") from error
    except subprocess.TimeoutExpired as error:
        raise AppError(f"{name} {args[0] if args else ''} took more than {timeout} s") from error


def list_devices(cfg: Config) -> list[dict]:
    """The iPhones and iPads CoreDevice knows (paired once over USB), as devicectl reports them."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "devices.json"
        result = run_tool(cfg, "xcrun", "devicectl", "list", "devices", "--json-output", str(out), timeout=120)
        if result.returncode != 0 or not out.exists():
            raise AppError("devicectl list devices failed: " + (result.stderr or result.stdout or "").strip()[-500:])
        data = json.loads(out.read_text())
    devices = []
    for raw in (data.get("result") or {}).get("devices") or []:
        hardware = raw.get("hardwareProperties") or {}
        props = raw.get("deviceProperties") or {}
        connection = raw.get("connectionProperties") or {}
        if hardware.get("platform") not in ("iOS", "iPadOS"):
            continue
        udid = hardware.get("udid") or raw.get("identifier")
        if not udid:
            continue
        paired = connection.get("pairingState") == "paired"
        devices.append({
            "id": udid,
            "name": props.get("name"),
            "model": hardware.get("marketingName") or hardware.get("productType"),
            "os": props.get("osVersionNumber"),
            "paired": paired,
            "developer_mode": props.get("developerModeStatus"),
            "transport": connection.get("transportType"),
            # A paired device not seen on the network nor by cable is "unavailable".
            "reachable": paired and connection.get("tunnelState", "unavailable") != "unavailable",
        })
    return devices


def find_teams(value) -> list[dict]:
    found = []
    if isinstance(value, dict):
        if "teamID" in value:
            found.append(value)
        for item in value.values():
            found.extend(find_teams(item))
    elif isinstance(value, list):
        for item in value:
            found.extend(find_teams(item))
    return found


def xcode_teams(cfg: Config) -> list[dict]:
    """The teams of the Apple Accounts signed in to Xcode (Settings → Accounts)."""
    result = run_tool(cfg, "defaults", "export", "com.apple.dt.Xcode", "-", timeout=30)
    if result.returncode != 0 or not result.stdout:
        return []
    try:
        prefs = plistlib.loads(result.stdout.encode())
    except Exception:  # noqa: BLE001
        return []
    # Xcode has kept them under IDEProvisioningTeams, then
    # IDEProvisioningTeamByIdentifier: whatever holds a teamID.
    teams = []
    for key in ("IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"):
        for team in find_teams(prefs.get(key)):
            if team["teamID"] not in [t["id"] for t in teams]:
                teams.append({"id": team["teamID"], "name": team.get("teamName"),
                              "free": bool(team.get("isFreeProvisioningTeam"))})
    return teams


def team(cfg: Config) -> dict:
    if cfg.team_id:
        return {"id": cfg.team_id, "paid": cfg.paid}
    teams = xcode_teams(cfg)
    wanted = [t for t in teams if t["free"] != cfg.paid] or teams
    if not wanted:
        raise AppError("no Apple Account in Xcode: sign Hermes' Xcode in (Settings → Accounts), "
                       "or run scripts/bootstrap-macos.sh apple")
    return {"id": wanted[0]["id"], "paid": not wanted[0]["free"]}


def bundle_prefix(cfg: Config, team_id: str) -> str:
    # A free team needs bundle ids no other team uses: the team id makes them so.
    return cfg.bundle_id_prefix or f"org.personal-server.hermes.{team_id.lower()}"


def secrets(cfg: Config) -> dict:
    values = {}
    try:
        for line in Path(cfg.secrets_file).read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key.strip()] = value.strip()
    except OSError:
        pass
    return values


def bot_username(cfg: Config, state: dict, token: str) -> str:
    if token:
        try:
            with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/getMe", timeout=15) as answer:
                name = json.loads(answer.read()).get("result", {}).get("username")
            if name:
                state["bot_username"] = name
        except Exception:  # noqa: BLE001 - offline: the last one known
            pass
    return state.get("bot_username") or ""


def profile_plist(cfg: Config, path: Path) -> dict | None:
    result = run_tool(cfg, "security", "cms", "-D", "-i", str(path), timeout=30)
    if result.returncode != 0 or not result.stdout:
        return None
    try:
        return plistlib.loads(result.stdout.encode())
    except Exception:  # noqa: BLE001
        return None


def purge_profiles(cfg: Config, team_id: str, prefix: str, log) -> None:
    """Drop Xcode's cached profiles of this app, so the next build gets new 7-day ones."""
    for folder in PROFILE_DIRS:
        for path in (cfg.home / folder).glob("*.mobileprovision"):
            profile = profile_plist(cfg, path)
            app_id = ((profile or {}).get("Entitlements") or {}).get("application-identifier", "")
            if app_id.startswith(f"{team_id}.{prefix}"):
                log.write(f"removing cached profile {path.name} ({app_id})\n")
                path.unlink(missing_ok=True)


# ── Building ────────────────────────────────────────────────────────────────

class Build:
    """One source tree for a run: copied, given the pet, generated once; built per device."""

    def __init__(self, cfg: Config, state: dict, log):
        self.cfg, self.state, self.log = cfg, state, log
        self.team = team(cfg)
        self.prefix = bundle_prefix(cfg, self.team["id"])
        self.number = now().strftime("%Y%m%d%H%M")
        self.src = cfg.cache_dir / "src"
        self.derived = cfg.cache_dir / "DerivedData"
        self.project: Path | None = None
        self.pet_version = None

    def prepare(self) -> None:
        source = Path(self.cfg.source) if self.cfg.source else None
        if not source or not (source / "project.yml").exists():
            raise AppError(f"no app source at {self.cfg.source or '(none)'}: this revision has no apps/hermes-ios")
        if self.src.exists():
            shutil.rmtree(self.src)
        # From the Nix store: read-only files, made writable for XcodeGen and the pet.
        shutil.copytree(source, self.src, symlinks=True)
        for path in [self.src, *self.src.rglob("*")]:
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o200)
        icon = self.cfg.pet / "icon.png"
        if icon.exists():
            (self.src / ICON).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(icon, self.src / ICON)
        for name in PET_FILES:
            if (self.cfg.pet / name).exists():
                (self.src / PET_DIR).mkdir(exist_ok=True)
                shutil.copyfile(self.cfg.pet / name, self.src / PET_DIR / name)
        self.pet_version = (read_json(self.cfg.pet / "pet.json", {}) or {}).get("version")
        self.log.write(f"== xcodegen ({self.src})\n")
        self.log.flush()
        if run_tool(self.cfg, "xcodegen", "generate", "--spec", "project.yml", cwd=str(self.src),
                    log=self.log, timeout=600).returncode != 0:
            raise AppError("xcodegen failed")
        projects = sorted(self.src.glob("*.xcodeproj"))
        if not projects:
            raise AppError("xcodegen made no .xcodeproj")
        self.project = projects[0]

    def env(self) -> dict:
        values = secrets(self.cfg)
        env = dict(os.environ)
        # As environment, not arguments: ps shows arguments. xcodebuild reads
        # the environment as build settings (Config/*.xcconfig name them).
        env.update({
            "HERMES_TEAM_ID": self.team["id"],
            "HERMES_BUNDLE_ID_PREFIX": self.prefix,
            "HERMES_PAID_TEAM": "1" if self.team["paid"] else "0",
            "HERMES_TG_API_ID": values.get("TELEGRAM_API_ID", ""),
            "HERMES_TG_API_HASH": values.get("TELEGRAM_API_HASH", ""),
            "HERMES_BOT_USERNAME": bot_username(self.cfg, self.state, values.get("TELEGRAM_BOT_TOKEN", "")),
        })
        return env

    def build(self, udid: str) -> Path:
        assert self.project is not None
        self.log.write(f"== xcodebuild for {udid}\n")
        self.log.flush()
        result = run_tool(
            self.cfg, "xcodebuild", "build",
            "-project", str(self.project), "-scheme", self.cfg.scheme, "-configuration", "Release",
            "-destination", f"id={udid}", "-derivedDataPath", str(self.derived),
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            # Nobody is there to trust a package's plugin or macro.
            "-skipPackagePluginValidation", "-skipMacroValidation",
            f"CURRENT_PROJECT_VERSION={self.number}",
            env=self.env(), log=self.log, timeout=self.cfg.build_timeout,
        )
        if result.returncode != 0:
            raise AppError("xcodebuild failed: " + errors(self.log.name))
        apps = sorted((self.derived / "Build/Products/Release-iphoneos").glob("*.app"))
        if len(apps) != 1:
            raise AppError(f"expected one .app in Release-iphoneos, found {len(apps)}")
        return apps[0]


def errors(log_path: str) -> str:
    lines = Path(log_path).read_text(errors="replace").splitlines()
    picked = [line.strip() for line in lines if re.search(r"\berror\b", line, re.I)]
    return " | ".join((picked or lines)[-6:])[-1500:]


def app_info(cfg: Config, app: Path) -> dict:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    profile = profile_plist(cfg, app / "embedded.mobileprovision") or {}
    expires = profile.get("ExpirationDate")
    return {"version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
            "bundle_id": info.get("CFBundleIdentifier"), "profile_expires": iso(expires) if expires else None}


def install(cfg: Config, app: Path, udid: str, log) -> None:
    log.write(f"== devicectl install on {udid}\n")
    log.flush()
    result = run_tool(cfg, "xcrun", "devicectl", "device", "install", "app", "--device", udid, str(app),
                      log=log, timeout=cfg.install_timeout)
    if result.returncode != 0:
        raise AppError("devicectl install failed: " + errors(log.name))


# ── The job ─────────────────────────────────────────────────────────────────

def pending(cfg: Config) -> list[dict]:
    out = []
    for path in sorted(cfg.requests.glob("*.json")):
        request = read_json(path)
        if request:
            request["_path"] = str(path)
            out.append(request)
    return out


def due(cfg: Config, state: dict) -> list[str]:
    limit = now() + cfg.refresh_before
    return [d["id"] for d in state["devices"]
            if d.get("chosen") and d.get("profile_expires") and parse_iso(d["profile_expires"]) <= limit]


def default_targets(cfg: Config, state: dict) -> list[str]:
    """No device named: those it was installed on, or else every paired one."""
    chosen = [d["id"] for d in state["devices"] if d.get("chosen")]
    if chosen:
        return chosen
    try:
        return [d["id"] for d in list_devices(cfg) if d["paired"]]
    except AppError:
        return []


def refresh_seen(cfg: Config, state: dict) -> dict[str, dict]:
    try:
        seen = {d["id"]: d for d in list_devices(cfg)}
    except AppError:
        return {}
    for device in state["devices"]:
        device["reachable"] = False
    for udid, live in seen.items():
        entry = device_entry(state, udid)
        entry.update({k: live[k] for k in ("name", "model", "os", "reachable")})
    return seen


def run_once(cfg: Config) -> bool:
    """One pass: what was asked, then what expires soon. False when there was nothing."""
    state = load_state(cfg)
    requests = pending(cfg)
    targets: list[str] = []
    reasons: dict[str, str] = {}
    for request in requests:
        for udid in request.get("devices") or default_targets(cfg, state):
            if udid not in targets:
                targets.append(udid)
                reasons[udid] = request.get("reason") or "asked"
    refresh = [u for u in due(cfg, state) if u not in targets]
    for udid in refresh:
        targets.append(udid)
        reasons[udid] = "profile expires soon"
    if not targets and not requests:
        return False

    seen = refresh_seen(cfg, state)
    state["running"] = {"since": iso(now()), "devices": targets, "reason": "; ".join(sorted(set(reasons.values())))}
    save_state(cfg, state)

    results: dict[str, dict] = {}
    logs = cfg.cache_dir / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    log_path = logs / f"run-{now().strftime('%Y%m%dT%H%M%S')}.log"
    with open(log_path, "w") as log:
        try:
            build = Build(cfg, state, log) if targets else None
            if build:
                build.prepare()
                state["team"] = build.team
        except AppError as error:
            build = None
            for udid in targets:
                results[udid] = {"ok": False, "error": str(error)}
        for udid in targets if build else []:
            entry = device_entry(state, udid)
            try:
                if udid in seen and not seen[udid]["reachable"]:
                    raise AppError(f"{entry.get('name') or udid} is not reachable (on another network, off, or asleep)")
                if udid not in seen and seen:
                    raise AppError(f"{udid} is not paired with this Mac: plug it in once (bootstrap-macos.sh app)")
                if udid in due(cfg, state):
                    purge_profiles(cfg, build.team["id"], build.prefix, log)
                app = build.build(udid)
                info = app_info(cfg, app)
                install(cfg, app, udid, log)
                results[udid] = {"ok": True, "error": None, **info}
            except AppError as error:
                log.write(f"!! {error}\n")
                results[udid] = {"ok": False, "error": str(error)}
            record = results[udid]
            entry["last_install"] = {
                "at": iso(now()), "ok": record["ok"], "error": record.get("error"),
                "version": record.get("version"), "build": record.get("build"),
                "pet_version": build.pet_version, "reason": reasons[udid],
            }
            if record["ok"]:
                entry["chosen"] = True
                entry["profile_expires"] = record.get("profile_expires")
            save_state(cfg, state)

    state["running"] = None
    state["last_log"] = str(log_path)
    save_state(cfg, state)
    finish(cfg, requests, results, log_path)
    prune(logs.glob("run-*.log"), KEEP_LOGS)
    return True


def finish(cfg: Config, requests: list[dict], results: dict, log_path: Path) -> None:
    cfg.done.mkdir(parents=True, exist_ok=True)
    for request in requests:
        path = Path(request.pop("_path"))
        asked = request.get("devices") or list(results)
        request.update({"finished": iso(now()), "log": str(log_path),
                        "results": {u: results[u] for u in asked if u in results}})
        write_json(cfg.done / path.name, request)
        path.unlink(missing_ok=True)
    prune(cfg.done.glob("*.json"), KEEP_DONE)


def prune(paths, keep: int) -> None:
    for path in sorted(paths)[:-keep]:
        path.unlink(missing_ok=True)


def cmd_run(cfg: Config) -> int:
    cfg.state_dir.mkdir(parents=True, exist_ok=True)
    with open(cfg.state_dir / "run.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # The run in progress picks up what was queued before it ends.
            return 0
        try:
            while run_once(cfg):
                pass
        except Exception:
            state = load_state(cfg)
            state["running"] = None
            save_state(cfg, state)
            raise
    return 0


def queue(cfg: Config, devices: list[str], reason: str) -> dict:
    request = {"id": f"{time.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:6]}",
               "devices": devices, "reason": reason, "at": iso(now())}
    write_json(cfg.requests / f"{request['id']}.json", request)
    return request


def start(cfg: Config) -> None:
    if cfg.label:
        domain = f"gui/{os.getuid()}/{cfg.label}"
        if run_tool(cfg, "launchctl", "kickstart", domain, timeout=30).returncode == 0:
            return
    # No launchd job (a test, or the session's agents not loaded yet): detached.
    subprocess.Popen([sys.executable, os.path.abspath(sys.argv[0]), "run"], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_for(cfg: Config, request_id: str, timeout: float) -> dict | None:
    deadline = time.monotonic() + timeout
    path = cfg.done / f"{request_id}.json"
    while time.monotonic() < deadline:
        if path.exists():
            return read_json(path)
        time.sleep(2)
    return None


def cmd_devices(cfg: Config) -> dict:
    state = load_state(cfg)
    try:
        live = list_devices(cfg)
        error = None
    except AppError as failure:
        live, error = [], str(failure)
    known = {d["id"]: d for d in state["devices"]}
    out = []
    for device in live:
        record = known.pop(device["id"], {})
        out.append({**device, "chosen": record.get("chosen", False), "last_install": record.get("last_install"),
                    "profile_expires": record.get("profile_expires")})
    for record in known.values():
        out.append({**record, "paired": False, "reachable": False})
    return {"devices": out, "running": state.get("running"), "next_refresh": state.get("next_refresh"),
            **({"error": error} if error else {})}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hermes-app", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("devices")
    sub.add_parser("status")
    sub.add_parser("run")
    inst = sub.add_parser("install")
    inst.add_argument("--device", action="append", default=[], help="a device's UDID (repeat); none: the usual ones")
    inst.add_argument("--reason", default="asked")
    inst.add_argument("--wait", action="store_true", help="wait until it is installed")
    inst.add_argument("--timeout", type=float, default=5400)
    args = parser.parse_args(argv)
    cfg = Config.load()
    try:
        if args.command == "run":
            return cmd_run(cfg)
        if args.command == "status":
            print(json.dumps(load_state(cfg), indent=2))
            return 0
        if args.command == "devices":
            print(json.dumps(cmd_devices(cfg), indent=2))
            return 0
        request = queue(cfg, args.device, args.reason)
        start(cfg)
        if not args.wait:
            print(json.dumps({"started": True, "request": request["id"]}))
            return 0
        done = wait_for(cfg, request["id"], args.timeout)
        print(json.dumps(done or {"request": request["id"], "error": "still running"}, indent=2))
        results = (done or {}).get("results") or {}
        return 0 if done and results and all(r.get("ok") for r in results.values()) else 1
    except AppError as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
