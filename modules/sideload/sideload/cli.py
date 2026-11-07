"""sideload: install iOS apps on the owner's iPhones and iPads from this Mac,
and keep them signed.

    sideload devices              the devices Xcode can install on (JSON)
    sideload apps                 the apps it knows, where each is installed, when it expires
    sideload limits               the free team's limits: apps per device, App IDs this week
    sideload status [APP]         the whole state, or one app's
    sideload add APP (--ipa PATH|URL | --project PATH|GIT-URL [--scheme S] [--ref R] [--keep-bundle-id]) [--name N]
    sideload install APP [--device UDID]... [--reason TEXT] [--wait]
                                  queue a build (or re-sign) and install, start the job, return at once
    sideload remove APP [--device UDID]...   uninstall it (from every device without --device)
    sideload forget APP           remove an added app from the list (after `remove`)
    sideload run                  the job (launchd): queued installs, then the refreshes due

Two kinds of app:
- xcode: a project (XcodeGen spec, .xcodeproj or .xcworkspace), from a path
  or a git URL, built for each device with Xcode's automatic signing
  (`xcodebuild -allowProvisioningUpdates -allowProvisioningDeviceRegistration`).
- ipa: an .ipa file, re-signed with the team: a one-file stub app with the
  same bundle id is built for the device, which makes Xcode register the id
  and the device and fetch a profile; that profile and identity then sign the
  .ipa's app (its frameworks first), with its bundle id rewritten to the
  team's and its app extensions removed (each would need an App ID and a
  profile of its own).

Installing is `xcrun devicectl device install app` over the local network. A
free personal team's profile lasts 7 days, so `run` rebuilds or re-signs what
expires within `refresh_before_hours`. A free team also allows 3 sideloaded
apps per device and 10 new App IDs per 7 days: refused beforehand, with why.
Everything runs as the service's account in its GUI session (a launchd
agent), where its login keychain, holding Xcode's account and signing key, is
unlocked.

Settings: a JSON file (SIDELOAD_CONFIG, written by Nix: modules/sideload).
Standard library only.
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

# Where Xcode caches profiles: Xcode 16 and later, then the older place.
PROFILE_DIRS = ("Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles")
KEEP_DONE = 30
KEEP_LOGS = 10
FREE_APPS_PER_DEVICE = 3
FREE_APP_IDS_PER_WEEK = 10
WEEK = dt.timedelta(days=7)


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


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "app"


class SideloadError(Exception):
    pass


class Config:
    def __init__(self, data: dict):
        self.home = Path(data.get("home") or Path.home())
        self.state_dir = Path(data.get("state_dir") or self.home / "Library/Application Support/sideload")
        self.cache_dir = Path(data.get("cache_dir") or self.home / "Library/Caches/sideload")
        team = data.get("team") or {}
        self.team_id = team.get("id") or None
        self.paid = bool(team.get("paid", False))
        self.refresh_before = dt.timedelta(hours=float(data.get("refresh_before_hours", 48)))
        self.secrets_file = data.get("secrets_file") or ""
        self.label = data.get("launchd_label", "")
        self.apps = dict(data.get("apps") or {})
        self.tools = {"xcrun": "xcrun", "xcodebuild": "xcodebuild", "xcodegen": "xcodegen", "security": "security",
                      "defaults": "defaults", "launchctl": "launchctl", "codesign": "codesign", "ditto": "ditto",
                      "git": "git", **(data.get("tools") or {})}
        self.install_timeout = int(data.get("install_timeout", 900))
        self.build_timeout = int(data.get("build_timeout", 5400))

    @classmethod
    def load(cls) -> "Config":
        path = os.environ.get("SIDELOAD_CONFIG")
        return cls(json.loads(Path(path).read_text()) if path else {})

    @property
    def state_file(self) -> Path:
        return self.state_dir / "state.json"

    @property
    def requests(self) -> Path:
        return self.state_dir / "requests"

    @property
    def done(self) -> Path:
        return self.requests / "done"


# ── State ───────────────────────────────────────────────────────────────────

def write_json(path: Path, data) -> None:
    # Atomic: readers (app-backend reads a status file whenever it changes) never see half of it.
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2, default=str) + "\n")
    os.replace(tmp, path)


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError, NotADirectoryError):
        return default


def load_state(cfg: Config) -> dict:
    state = read_json(cfg.state_file, None) or {}
    state.setdefault("v", 1)
    state.setdefault("devices", [])
    state.setdefault("apps", {})
    state.setdefault("app_ids", {})
    state.setdefault("running", None)
    for app_id, definition in cfg.apps.items():
        entry = state["apps"].setdefault(app_id, {"installs": {}})
        entry["declared"] = True
        # The Hermes app's earlier delivery.json, when this state is new: its devices carry over.
        old = read_json(Path(definition.get("status_file") or "/nonexistent"), None)
        if old and not entry["installs"] and not entry.get("imported"):
            for d in old.get("devices") or []:
                if d.get("chosen") and d.get("last_install"):
                    entry["installs"][d["id"]] = {**d["last_install"], "profile_expires": d.get("profile_expires")}
                device_entry(state, d["id"]).update({k: d.get(k) for k in ("name", "model", "os")})
            entry["imported"] = True
    return state


def app_definition(cfg: Config, state: dict, app_id: str) -> dict:
    if app_id in cfg.apps:
        return {"kind": "xcode", **cfg.apps[app_id]}
    entry = state["apps"].get(app_id) or {}
    if not entry.get("def"):
        known = ", ".join(sorted(state["apps"])) or "none"
        raise SideloadError(f"unknown app {app_id!r} (known: {known}); add it first: sideload add {app_id} --ipa … | --project …")
    return entry["def"]


def installs(state: dict, app_id: str) -> dict:
    return state["apps"].setdefault(app_id, {"installs": {}}).setdefault("installs", {})


def next_refresh(cfg: Config, state: dict) -> str | None:
    expiries = [parse_iso(i.get("profile_expires")) for a in state["apps"].values()
                for i in (a.get("installs") or {}).values() if i.get("ok") and not i.get("removed")]
    expiries = [e for e in expiries if e]
    return iso(min(expiries) - cfg.refresh_before) if expiries else None


def save_state(cfg: Config, state: dict) -> None:
    state["updated"] = iso(now())
    state["next_refresh"] = next_refresh(cfg, state)
    write_json(cfg.state_file, state)
    for app_id, definition in cfg.apps.items():
        if definition.get("status_file"):
            write_json(Path(definition["status_file"]), app_status(cfg, state, app_id))


def app_status(cfg: Config, state: dict, app_id: str) -> dict:
    """One app's devices in the shape of the Hermes app's delivery.json (app-backend reads it)."""
    mine = installs(state, app_id)
    devices = []
    for d in state["devices"]:
        record = mine.get(d["id"])
        chosen = bool(record and record.get("ok") and not record.get("removed"))
        devices.append({"id": d["id"], "name": d.get("name"), "model": d.get("model"), "os": d.get("os"),
                        "reachable": d.get("reachable", False), "chosen": chosen,
                        "last_install": {k: v for k, v in (record or {}).items() if k != "profile_expires"} or None,
                        "profile_expires": (record or {}).get("profile_expires") if chosen else None})
    expiries = [parse_iso(d["profile_expires"]) for d in devices if d["profile_expires"]]
    running = state.get("running")
    return {"v": 1, "devices": devices, "team": state.get("team"), "updated": state.get("updated"),
            "running": running if running and app_id in (running.get("apps") or []) else None,
            "next_refresh": iso(min(expiries) - cfg.refresh_before) if expiries else None}


def device_entry(state: dict, udid: str) -> dict:
    for device in state["devices"]:
        if device["id"] == udid:
            return device
    device = {"id": udid, "name": None, "model": None, "os": None, "reachable": False}
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
        raise SideloadError(f"{cfg.tools[name]} not found: {error}") from error
    except subprocess.TimeoutExpired as error:
        raise SideloadError(f"{name} {args[0] if args else ''} took more than {timeout} s") from error


def list_devices(cfg: Config) -> list[dict]:
    """The iPhones and iPads CoreDevice knows (paired once over USB), as devicectl reports them."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "devices.json"
        result = run_tool(cfg, "xcrun", "devicectl", "list", "devices", "--json-output", str(out), timeout=120)
        if result.returncode != 0 or not out.exists():
            raise SideloadError("devicectl list devices failed: " + (result.stderr or result.stdout or "").strip()[-500:])
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
            "id": udid, "name": props.get("name"),
            "model": hardware.get("marketingName") or hardware.get("productType"),
            "os": props.get("osVersionNumber"), "paired": paired,
            "developer_mode": props.get("developerModeStatus"), "transport": connection.get("transportType"),
            # A paired device seen neither on the network nor by cable is "unavailable".
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
    teams = []
    for key in ("IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"):
        for t in find_teams(prefs.get(key)):
            if t["teamID"] not in [x["id"] for x in teams]:
                teams.append({"id": t["teamID"], "name": t.get("teamName"), "free": bool(t.get("isFreeProvisioningTeam"))})
    return teams


def team(cfg: Config) -> dict:
    if cfg.team_id:
        return {"id": cfg.team_id, "paid": cfg.paid}
    teams = xcode_teams(cfg)
    wanted = [t for t in teams if t["free"] != cfg.paid] or teams
    if not wanted:
        raise SideloadError("no Apple Account in Xcode: sign the service account's Xcode in (Settings → Accounts), "
                            "or run scripts/bootstrap-macos.sh sideload-account")
    return {"id": wanted[0]["id"], "paid": not wanted[0]["free"]}


def bundle_prefix(definition: dict, team_id: str, app_id: str) -> str:
    # A free team needs bundle ids no other team uses: the team id makes them so.
    return definition.get("bundle_id_prefix") or f"org.personal-server.{definition.get('prefix_name') or 'sideload.' + slug(app_id)}.{team_id.lower()}"


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
            app_id = ((profile_plist(cfg, path) or {}).get("Entitlements") or {}).get("application-identifier", "")
            if app_id.startswith(f"{team_id}.{prefix}"):
                log.write(f"removing cached profile {path.name} ({app_id})\n")
                path.unlink(missing_ok=True)


def errors(log_path: str) -> str:
    lines = Path(log_path).read_text(errors="replace").splitlines()
    picked = [line.strip() for line in lines if re.search(r"\berror\b", line, re.I)]
    return " | ".join((picked or lines)[-6:])[-1500:]


def bundle_ids(app: Path) -> list[str]:
    """The bundle ids an .app carries: its own and its extensions' (each one an App ID)."""
    out = []
    for info in [app / "Info.plist", *app.glob("PlugIns/*/Info.plist"), *app.glob("Extensions/*/Info.plist")]:
        try:
            bid = plistlib.loads(info.read_bytes()).get("CFBundleIdentifier")
        except (OSError, plistlib.InvalidFileException):
            continue
        if bid:
            out.append(bid)
    return out


def app_info(cfg: Config, app: Path) -> dict:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    profile = profile_plist(cfg, app / "embedded.mobileprovision") or {}
    expires = profile.get("ExpirationDate")
    return {"version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
            "bundle_id": info.get("CFBundleIdentifier"), "profile_expires": iso(expires) if expires else None}


# ── Limits ──────────────────────────────────────────────────────────────────

def recent_app_ids(state: dict) -> dict:
    since = now() - WEEK
    return {bid: at for bid, at in state["app_ids"].items() if (parse_iso(at) or now()) > since}


def installed_on(state: dict, udid: str) -> list[str]:
    return sorted(a for a, entry in state["apps"].items()
                  if (r := (entry.get("installs") or {}).get(udid)) and r.get("ok") and not r.get("removed"))


def check_limits(state: dict, team_info: dict, app_id: str, udid: str, new_ids: list[str]) -> None:
    """A free team's limits, checked before a build: 3 apps per device, 10 new App IDs a week."""
    if team_info.get("paid"):
        return
    on_device = installed_on(state, udid)
    if app_id not in on_device and len(on_device) >= FREE_APPS_PER_DEVICE:
        raise SideloadError(f"free team limit: {FREE_APPS_PER_DEVICE} sideloaded apps per device, and it has "
                            f"{', '.join(on_device)}; remove one first (sideload remove APP --device {udid})")
    recent = recent_app_ids(state)
    fresh = [b for b in new_ids if b not in state["app_ids"]]
    if fresh and len(recent) + len(fresh) > FREE_APP_IDS_PER_WEEK:
        oldest = min((parse_iso(at) for at in recent.values()), default=now())
        raise SideloadError(f"free team limit: {FREE_APP_IDS_PER_WEEK} new App IDs per 7 days, {len(recent)} used; "
                            f"{len(fresh)} more needed; the next frees up at {iso(oldest + WEEK)}")


def cmd_limits(cfg: Config) -> dict:
    state = load_state(cfg)
    team_info = state.get("team") or ({"id": cfg.team_id, "paid": cfg.paid} if cfg.team_id else None)
    recent = recent_app_ids(state)
    oldest = min((parse_iso(at) for at in recent.values()), default=None)
    paid = bool(team_info and team_info.get("paid"))
    return {
        "team": team_info, "paid": paid,
        "apps_per_device": {d["id"]: {"name": d.get("name"), "apps": installed_on(state, d["id"]),
                                      "max": None if paid else FREE_APPS_PER_DEVICE} for d in state["devices"]},
        "app_ids_this_week": {"used": len(recent), "max": None if paid else FREE_APP_IDS_PER_WEEK,
                              "ids": sorted(recent), "next_frees_at": iso(oldest + WEEK) if oldest and not paid else None},
        "note": None if paid else ("A free team: each app's signature lasts 7 days (renewed here), at most 3 sideloaded "
                                   "apps per device (apps installed by other means count too), at most 10 new App IDs "
                                   "a week (an app's extensions each take one)."),
    }


# ── Building ────────────────────────────────────────────────────────────────

class Build:
    """One app for a run: its source prepared once, then built (or re-signed) per device."""

    def __init__(self, cfg: Config, state: dict, app_id: str, team_info: dict, log):
        self.cfg, self.state, self.app_id, self.team, self.log = cfg, state, app_id, team_info, log
        self.definition = app_definition(cfg, state, app_id)
        self.kind = self.definition.get("kind", "xcode")
        self.prefix = bundle_prefix(self.definition, team_info["id"], app_id)
        self.number = now().strftime("%Y%m%d%H%M")
        self.work = cfg.cache_dir / "apps" / slug(app_id)
        self.derived = self.work / "DerivedData"
        self.src = self.work / "src"
        self.project: Path | None = None
        self.input_version = None

    # the bundle ids this app will take, for the limits
    def planned_ids(self) -> list[str]:
        if self.kind == "ipa":
            return [self.ipa_bundle_id()]
        if self.definition.get("bundle_id"):
            return [self.definition["bundle_id"]]
        built = sorted(self.derived.glob("Build/Products/Release-iphoneos/*.app"))
        return bundle_ids(built[0]) if built else [self.prefix + ".app"]

    def ipa_bundle_id(self) -> str:
        return self.definition.get("bundle_id") or self.prefix

    def prepare(self) -> None:
        if self.kind == "ipa":
            self.prepare_ipa()
        else:
            self.prepare_xcode()

    def _source(self) -> Path:
        source = str(self.definition.get("source") or "")
        if re.match(r"^(https?://|git@|ssh://)", source) or source.endswith(".git"):
            repo = self.work / "repo"
            ref = self.definition.get("ref")
            if (repo / ".git").exists():
                run_tool(self.cfg, "git", "-C", str(repo), "fetch", "--depth", "1", "origin", ref or "HEAD", log=self.log, timeout=600)
                run_tool(self.cfg, "git", "-C", str(repo), "reset", "--hard", "FETCH_HEAD", log=self.log, timeout=120)
            else:
                args = ["clone", "--depth", "1", *(["--branch", ref] if ref else []), source, str(repo)]
                if run_tool(self.cfg, "git", *args, log=self.log, timeout=1200).returncode != 0:
                    raise SideloadError(f"could not clone {source}")
            return repo
        path = Path(source)
        if not source or not path.exists():
            raise SideloadError(f"no source for {self.app_id} at {source or '(none)'}")
        return path

    def prepare_xcode(self) -> None:
        source = self._source()
        if self.src.exists():
            shutil.rmtree(self.src)
        # Often from the Nix store: read-only, made writable for XcodeGen and the inputs.
        shutil.copytree(source, self.src, symlinks=True, ignore=shutil.ignore_patterns(".git"))
        for path in [self.src, *self.src.rglob("*")]:
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o200)
        for item in self.definition.get("inputs") or []:
            origin = Path(item["from"])
            if origin.exists():
                (self.src / item["to"]).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(origin, self.src / item["to"])
        version_file = self.definition.get("version_file")
        if version_file:
            self.input_version = (read_json(Path(version_file), {}) or {}).get("version")
        if (self.src / "project.yml").exists():
            self.log.write(f"== xcodegen ({self.src})\n")
            self.log.flush()
            if run_tool(self.cfg, "xcodegen", "generate", "--spec", "project.yml", cwd=str(self.src),
                        log=self.log, timeout=600).returncode != 0:
                raise SideloadError("xcodegen failed")
        found = sorted(self.src.glob("*.xcworkspace")) or sorted(self.src.glob("*.xcodeproj"))
        if not found:
            raise SideloadError(f"no Xcode project in {self.definition.get('source')} (an .xcodeproj, .xcworkspace or project.yml)")
        self.project = found[0]

    def env(self) -> dict:
        values = secrets(self.cfg)
        env = dict(os.environ)
        names = self.definition.get("team_env") or {}
        # As environment, not arguments: ps shows arguments. xcodebuild reads
        # the environment as build settings.
        for key, value in (("team_id", self.team["id"]), ("bundle_id_prefix", self.prefix),
                           ("paid", "1" if self.team["paid"] else "0")):
            if names.get(key):
                env[names[key]] = value
        env.update({k: str(v) for k, v in (self.definition.get("env") or {}).items()})
        env.update({var: values.get(key, "") for var, key in (self.definition.get("secret_env") or {}).items()})
        for var, command in (self.definition.get("env_commands") or {}).items():
            try:
                env[var] = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=60).stdout.strip()
            except (OSError, subprocess.SubprocessError):
                env[var] = ""
        return env

    def _xcodebuild(self, project: Path, scheme: str, udid: str, derived: Path, settings: list[str], env: dict) -> Path:
        self.log.write(f"== xcodebuild {scheme} for {udid}\n")
        self.log.flush()
        flag = "-workspace" if project.suffix == ".xcworkspace" else "-project"
        result = run_tool(
            self.cfg, "xcodebuild", "build", flag, str(project), "-scheme", scheme, "-configuration", "Release",
            "-destination", f"id={udid}", "-derivedDataPath", str(derived),
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            # Nobody is there to trust a package's plugin or macro.
            "-skipPackagePluginValidation", "-skipMacroValidation", *settings,
            env=env, log=self.log, timeout=self.cfg.build_timeout,
        )
        if result.returncode != 0:
            raise SideloadError("xcodebuild failed: " + errors(self.log.name))
        apps = sorted((derived / "Build/Products/Release-iphoneos").glob("*.app"))
        if not apps:
            raise SideloadError("xcodebuild made no .app in Release-iphoneos")
        return next((a for a in apps if a.stem == scheme), apps[0])

    def build(self, udid: str) -> Path:
        if self.kind == "ipa":
            return self.resign(udid)
        assert self.project is not None
        scheme = self.definition.get("scheme") or self.project.stem
        settings = [f"CURRENT_PROJECT_VERSION={self.number}"]
        if not self.definition.get("team_env"):
            # A project of someone else's: signed by this team, automatically.
            settings += [f"DEVELOPMENT_TEAM={self.team['id']}", "CODE_SIGN_STYLE=Automatic"]
            if self.definition.get("bundle_id"):
                settings.append(f"PRODUCT_BUNDLE_IDENTIFIER={self.definition['bundle_id']}")
        return self._xcodebuild(self.project, scheme, udid, self.derived, settings, self.env())

    # ── ipa ──

    def prepare_ipa(self) -> None:
        ipa = Path(self.definition["ipa"])
        if not ipa.exists():
            raise SideloadError(f"the .ipa of {self.app_id} is gone ({ipa}): add it again")
        payload = self.work / "payload"
        if payload.exists():
            shutil.rmtree(payload)
        payload.mkdir(parents=True)
        if run_tool(self.cfg, "ditto", "-x", "-k", str(ipa), str(payload), log=self.log, timeout=600).returncode != 0:
            raise SideloadError(f"could not unpack {ipa.name}: not an .ipa?")
        apps = sorted((payload / "Payload").glob("*.app"))
        if len(apps) != 1:
            raise SideloadError(f"{ipa.name} holds {len(apps)} apps in Payload/, expected one")
        self.unpacked = apps[0]
        # Its extensions would each need an App ID and a profile: left out.
        for folder in ("PlugIns", "Extensions", "Watch"):
            if (self.unpacked / folder).exists():
                self.log.write(f"removing {folder}/ (app extensions are not re-signed)\n")
                shutil.rmtree(self.unpacked / folder)
        info_path = self.unpacked / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = self.ipa_bundle_id()
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        self.write_stub(info)

    def write_stub(self, info: dict) -> None:
        """A one-file app with the .ipa's (new) bundle id, which Xcode can sign: its profile signs the .ipa."""
        stub = self.work / "stub"
        if stub.exists():
            shutil.rmtree(stub)
        (stub / "Stub").mkdir(parents=True)
        (stub / "Stub/main.swift").write_text("print(\"stub\")\n")
        target = str(info.get("MinimumOSVersion") or "15.0")
        (stub / "project.yml").write_text(json.dumps({
            "name": "Stub", "options": {"deploymentTarget": {"iOS": target}},
            "targets": {"Stub": {"type": "application", "platform": "iOS", "sources": ["Stub"],
                                 "info": {"path": "Stub/Info.plist", "properties": {"CFBundleDisplayName": "Stub"}},
                                 "settings": {"PRODUCT_BUNDLE_IDENTIFIER": self.ipa_bundle_id(),
                                              "DEVELOPMENT_TEAM": self.team["id"], "CODE_SIGN_STYLE": "Automatic"}}},
        }, indent=2))
        if run_tool(self.cfg, "xcodegen", "generate", "--spec", "project.yml", cwd=str(stub), log=self.log,
                    timeout=300).returncode != 0:
            raise SideloadError("xcodegen failed on the signing stub")
        self.project = stub / "Stub.xcodeproj"

    def resign(self, udid: str) -> Path:
        assert self.project is not None
        stub_app = self._xcodebuild(self.project, "Stub", udid, self.work / "StubData",
                                    [f"PRODUCT_BUNDLE_IDENTIFIER={self.ipa_bundle_id()}", f"DEVELOPMENT_TEAM={self.team['id']}"],
                                    dict(os.environ))
        profile = stub_app / "embedded.mobileprovision"
        details = run_tool(self.cfg, "codesign", "-dvv", str(stub_app), timeout=60)
        authority = re.search(r"^Authority=(.+)$", (details.stderr or "") + (details.stdout or ""), re.M)
        if not profile.exists() or not authority:
            raise SideloadError("the signing stub came out without a profile or a signing identity")
        identity = authority.group(1).strip()
        entitlements = (profile_plist(self.cfg, profile) or {}).get("Entitlements") or {}
        keep = {k: v for k, v in entitlements.items()
                if k in ("application-identifier", "com.apple.developer.team-identifier", "get-task-allow",
                         "keychain-access-groups")}
        ent_file = self.work / "entitlements.plist"
        ent_file.write_bytes(plistlib.dumps(keep))
        app = self.unpacked
        shutil.copyfile(profile, app / "embedded.mobileprovision")
        self.log.write(f"== codesign {app.name} as {identity}\n")
        nested = sorted([*app.glob("Frameworks/*.framework"), *app.glob("Frameworks/*.dylib")])
        for item in nested:
            if run_tool(self.cfg, "codesign", "-f", "-s", identity, str(item), log=self.log, timeout=300).returncode != 0:
                raise SideloadError(f"codesign failed on {item.name}: " + errors(self.log.name))
        if run_tool(self.cfg, "codesign", "-f", "-s", identity, "--entitlements", str(ent_file), str(app),
                    log=self.log, timeout=300).returncode != 0:
            raise SideloadError("codesign failed: " + errors(self.log.name))
        return app


def install(cfg: Config, app: Path, udid: str, log) -> None:
    log.write(f"== devicectl install on {udid}\n")
    log.flush()
    result = run_tool(cfg, "xcrun", "devicectl", "device", "install", "app", "--device", udid, str(app),
                      log=log, timeout=cfg.install_timeout)
    if result.returncode != 0:
        raise SideloadError("devicectl install failed: " + errors(log.name))


# ── The job ─────────────────────────────────────────────────────────────────

def pending(cfg: Config) -> list[dict]:
    out = []
    for path in sorted(cfg.requests.glob("*.json")):
        request = read_json(path)
        if request:
            request["_path"] = str(path)
            out.append(request)
    return out


RETRY_AFTER = dt.timedelta(hours=1)


def due(cfg: Config, state: dict) -> list[tuple[str, str]]:
    """What expires soon; a refresh that just failed waits for a later run (else the job loops on it)."""
    limit = now() + cfg.refresh_before
    tried = now() - RETRY_AFTER
    return [(app_id, udid) for app_id, entry in state["apps"].items()
            for udid, r in (entry.get("installs") or {}).items()
            if r.get("ok") and not r.get("removed") and r.get("profile_expires") and parse_iso(r["profile_expires"]) <= limit
            and not ((parse_iso(r.get("last_error_at")) or tried) > tried)]


def default_targets(cfg: Config, state: dict, app_id: str) -> list[str]:
    """No device named: those it is installed on, or else every paired one."""
    on = [u for u, r in installs(state, app_id).items() if r.get("ok") and not r.get("removed")]
    if on:
        return on
    try:
        return [d["id"] for d in list_devices(cfg) if d["paired"]]
    except SideloadError:
        return []


def refresh_seen(cfg: Config, state: dict) -> dict[str, dict]:
    try:
        seen = {d["id"]: d for d in list_devices(cfg)}
    except SideloadError:
        return {}
    for device in state["devices"]:
        device["reachable"] = False
    for udid, live in seen.items():
        device_entry(state, udid).update({k: live[k] for k in ("name", "model", "os", "reachable")})
    return seen


def run_once(cfg: Config) -> bool:
    """One pass: what was asked, then what expires soon. False when there was nothing."""
    state = load_state(cfg)
    requests = pending(cfg)
    jobs: dict[str, dict[str, str]] = {}  # app -> device -> reason
    removals = [r for r in requests if r.get("action") == "remove"]
    for request in requests:
        if request.get("action") == "remove":
            continue
        app_id = request["app"]
        for udid in request.get("devices") or default_targets(cfg, state, app_id):
            jobs.setdefault(app_id, {}).setdefault(udid, request.get("reason") or "asked")
    for app_id, udid in due(cfg, state):
        jobs.setdefault(app_id, {}).setdefault(udid, "profile expires soon")
    if not jobs and not requests:
        return False

    seen = refresh_seen(cfg, state)
    state["running"] = {"since": iso(now()), "apps": list(jobs),
                        "devices": sorted({u for d in jobs.values() for u in d}),
                        "reason": "; ".join(sorted({r for d in jobs.values() for r in d.values()}))}
    save_state(cfg, state)

    results: dict[str, dict[str, dict]] = {}
    logs = cfg.cache_dir / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    log_path = logs / f"run-{now().strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:4]}.log"
    with open(log_path, "w") as log:
        for request in removals:
            results[request["app"]] = remove(cfg, state, request["app"], request.get("devices") or [], log)
        try:
            team_info = team(cfg) if jobs else None
            if team_info:
                state["team"] = team_info
        except SideloadError as error:
            team_info = None
            for app_id, targets in jobs.items():
                results[app_id] = {u: {"ok": False, "error": str(error)} for u in targets}
        for app_id, targets in jobs.items() if team_info else []:
            results.setdefault(app_id, {})
            log.write(f"=== {app_id}\n")
            try:
                build = Build(cfg, state, app_id, team_info, log)
                build.prepare()
            except SideloadError as error:
                for udid in targets:
                    results[app_id][udid] = {"ok": False, "error": str(error)}
                record_results(state, app_id, targets, results[app_id], None)
                save_state(cfg, state)
                continue
            for udid, reason in targets.items():
                name = device_entry(state, udid).get("name") or udid
                try:
                    if udid in seen and not seen[udid]["reachable"]:
                        raise SideloadError(f"{name} is not reachable (on another network, off, or asleep)")
                    if udid not in seen and seen:
                        raise SideloadError(f"{udid} is not paired with this Mac: plug it in once (bootstrap-macos.sh sideload-devices)")
                    check_limits(state, team_info, app_id, udid, build.planned_ids())
                    if reason == "profile expires soon":
                        purge_profiles(cfg, team_info["id"], build.ipa_bundle_id() if build.kind == "ipa" else build.prefix, log)
                    app = build.build(udid)
                    for bid in bundle_ids(app):
                        state["app_ids"].setdefault(bid, iso(now()))
                    info = app_info(cfg, app)
                    install(cfg, app, udid, log)
                    results[app_id][udid] = {"ok": True, "error": None, **info}
                except SideloadError as error:
                    log.write(f"!! {error}\n")
                    results[app_id][udid] = {"ok": False, "error": str(error)}
                record_results(state, app_id, {udid: reason}, results[app_id], build.input_version)
                save_state(cfg, state)

    state["running"] = None
    state["last_log"] = str(log_path)
    save_state(cfg, state)
    finish(cfg, requests, results, log_path)
    prune(logs.glob("run-*.log"), KEEP_LOGS)
    return True


def record_results(state: dict, app_id: str, targets: dict, results: dict, input_version) -> None:
    mine = installs(state, app_id)
    for udid, reason in targets.items():
        record = results.get(udid) or {}
        before = mine.get(udid) or {}
        entry = {"at": iso(now()), "ok": record.get("ok", False), "error": record.get("error"),
                 "version": record.get("version"), "build": record.get("build"), "bundle_id": record.get("bundle_id"),
                 "input_version": input_version, "reason": reason}
        if record.get("ok"):
            entry["profile_expires"] = record.get("profile_expires")
        elif before.get("ok") and not before.get("removed"):
            # A failed refresh leaves the app where it was, still signed until then.
            entry.update(ok=True, error=record.get("error"), profile_expires=before.get("profile_expires"),
                         version=before.get("version"), build=before.get("build"), bundle_id=before.get("bundle_id"),
                         last_error_at=iso(now()))
        mine[udid] = entry


def remove(cfg: Config, state: dict, app_id: str, devices: list[str], log) -> dict:
    mine = installs(state, app_id)
    targets = devices or [u for u, r in mine.items() if r.get("ok") and not r.get("removed")]
    out = {}
    for udid in targets:
        bid = (mine.get(udid) or {}).get("bundle_id")
        if not bid:
            out[udid] = {"ok": False, "error": f"{app_id} is not installed on {udid} by sideload"}
            continue
        log.write(f"== devicectl uninstall {bid} on {udid}\n")
        result = run_tool(cfg, "xcrun", "devicectl", "device", "uninstall", "app", "--device", udid, bid,
                          log=log, timeout=300)
        if result.returncode != 0:
            out[udid] = {"ok": False, "error": "devicectl uninstall failed: " + errors(log.name)}
            continue
        mine[udid] = {**mine[udid], "removed": True, "removed_at": iso(now())}
        out[udid] = {"ok": True, "removed": True}
    return out


def finish(cfg: Config, requests: list[dict], results: dict, log_path: Path) -> None:
    cfg.done.mkdir(parents=True, exist_ok=True)
    for request in requests:
        path = Path(request.pop("_path"))
        mine = results.get(request.get("app"), {})
        asked = request.get("devices") or list(mine)
        request.update({"finished": iso(now()), "log": str(log_path),
                        "results": {u: mine[u] for u in asked if u in mine}})
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
            return 0  # the run in progress picks up what was queued before it ends
        try:
            while run_once(cfg):
                pass
        except Exception:
            state = load_state(cfg)
            state["running"] = None
            save_state(cfg, state)
            raise
    return 0


def queue(cfg: Config, app_id: str, devices: list[str], reason: str, action: str = "install") -> dict:
    request = {"id": f"{time.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:6]}", "app": app_id, "action": action,
               "devices": devices, "reason": reason, "at": iso(now())}
    write_json(cfg.requests / f"{request['id']}.json", request)
    return request


def start(cfg: Config) -> None:
    if cfg.label:
        if run_tool(cfg, "launchctl", "kickstart", f"gui/{os.getuid()}/{cfg.label}", timeout=30).returncode == 0:
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
        live, error = list_devices(cfg), None
    except SideloadError as failure:
        live, error = [], str(failure)
    known = {d["id"]: d for d in state["devices"]}
    out = []
    for device in live:
        known.pop(device["id"], None)
        out.append({**device, "apps": installed_on(state, device["id"])})
    for record in known.values():
        out.append({**record, "paired": False, "reachable": False, "apps": installed_on(state, record["id"])})
    return {"devices": out, "running": state.get("running"), "next_refresh": state.get("next_refresh"),
            **({"error": error} if error else {})}


def cmd_apps(cfg: Config) -> dict:
    state = load_state(cfg)
    names = {d["id"]: d.get("name") for d in state["devices"]}
    apps = []
    for app_id, entry in sorted(state["apps"].items()):
        try:
            definition = app_definition(cfg, state, app_id)
        except SideloadError:
            continue
        apps.append({
            "id": app_id, "name": definition.get("name") or app_id, "kind": definition.get("kind", "xcode"),
            "source": definition.get("ipa_origin") or definition.get("source") or definition.get("ipa"),
            "declared": app_id in cfg.apps,
            "devices": [{"id": u, "name": names.get(u), **{k: r.get(k) for k in
                         ("ok", "error", "version", "build", "bundle_id", "profile_expires", "at", "removed")}}
                        for u, r in (entry.get("installs") or {}).items()],
        })
    return {"apps": apps, "running": state.get("running"), "next_refresh": state.get("next_refresh")}


def fetch(source: str, dest: Path) -> str:
    """An .ipa from a path or a URL (a Telegram attachment saved by the gateway, a big-file link)."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if re.match(r"^https?://", source):
        request = urllib.request.Request(source, headers={"User-Agent": "sideload"})
        with urllib.request.urlopen(request, timeout=600) as answer, open(dest, "wb") as out:
            shutil.copyfileobj(answer, out)
    else:
        path = Path(source).expanduser()
        if not path.is_file():
            raise SideloadError(f"no file at {source}")
        shutil.copyfile(path, dest)
    with open(dest, "rb") as f:
        if f.read(2) != b"PK":
            dest.unlink(missing_ok=True)
            raise SideloadError(f"{source} is not an .ipa (a zip archive)")
    return source


def cmd_add(cfg: Config, args) -> dict:
    if args.app in cfg.apps:
        raise SideloadError(f"{args.app} is declared in the configuration; pick another name")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,40}", args.app):
        raise SideloadError("an app name is lowercase letters, digits, '.', '_' or '-'")
    state = load_state(cfg)
    if args.ipa:
        ipa = cfg.state_dir / "ipas" / f"{slug(args.app)}.ipa"
        definition = {"kind": "ipa", "ipa": str(ipa), "ipa_origin": fetch(args.ipa, ipa)}
    else:
        definition = {"kind": "xcode", "source": args.project, "scheme": args.scheme, "ref": args.ref}
        if not args.keep_bundle_id:
            definition["bundle_id"] = None  # filled from the team at build time, below
    definition["name"] = args.name or args.app
    entry = state["apps"].setdefault(args.app, {"installs": {}})
    entry["def"] = definition
    if definition.get("kind") == "xcode" and not args.keep_bundle_id:
        # A free team cannot sign a bundle id another team registered: one of the team's own.
        try:
            definition["bundle_id"] = bundle_prefix({}, team(cfg)["id"], args.app)
        except SideloadError:
            definition.pop("bundle_id")
    save_state(cfg, state)
    return {"added": args.app, **definition}


def cmd_forget(cfg: Config, app_id: str) -> dict:
    state = load_state(cfg)
    if app_id in cfg.apps:
        raise SideloadError(f"{app_id} is declared in the configuration")
    if installed := [u for u, r in installs(state, app_id).items() if r.get("ok") and not r.get("removed")]:
        raise SideloadError(f"{app_id} is still installed on {', '.join(installed)}: sideload remove {app_id} first")
    entry = state["apps"].pop(app_id, None) or {}
    if (entry.get("def") or {}).get("ipa"):
        Path(entry["def"]["ipa"]).unlink(missing_ok=True)
    save_state(cfg, state)
    return {"forgotten": app_id}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="sideload", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("devices", "apps", "limits", "run"):
        sub.add_parser(name)
    status = sub.add_parser("status")
    status.add_argument("app", nargs="?")
    add = sub.add_parser("add")
    add.add_argument("app")
    what = add.add_mutually_exclusive_group(required=True)
    what.add_argument("--ipa")
    what.add_argument("--project")
    add.add_argument("--scheme")
    add.add_argument("--ref")
    add.add_argument("--name")
    add.add_argument("--keep-bundle-id", action="store_true")
    for name in ("install", "remove"):
        p = sub.add_parser(name)
        p.add_argument("app")
        p.add_argument("--device", action="append", default=[], help="a device's UDID (repeat)")
        p.add_argument("--reason", default="asked")
        p.add_argument("--wait", action="store_true")
        p.add_argument("--timeout", type=float, default=5400)
    forget = sub.add_parser("forget")
    forget.add_argument("app")
    args = parser.parse_args(argv)
    cfg = Config.load()
    try:
        if args.command == "run":
            return cmd_run(cfg)
        if args.command in ("devices", "apps", "limits"):
            print(json.dumps({"devices": cmd_devices, "apps": cmd_apps, "limits": cmd_limits}[args.command](cfg), indent=2))
            return 0
        if args.command == "status":
            state = load_state(cfg)
            print(json.dumps(app_status(cfg, state, args.app) if args.app else state, indent=2))
            return 0
        if args.command == "add":
            print(json.dumps(cmd_add(cfg, args), indent=2))
            return 0
        if args.command == "forget":
            print(json.dumps(cmd_forget(cfg, args.app)))
            return 0
        state = load_state(cfg)
        app_definition(cfg, state, args.app)  # an unknown app fails here, not in the job
        request = queue(cfg, args.app, args.device, args.reason, args.command)
        start(cfg)
        if not args.wait:
            print(json.dumps({"started": True, "request": request["id"]}))
            return 0
        done = wait_for(cfg, request["id"], args.timeout)
        print(json.dumps(done or {"request": request["id"], "error": "still running"}, indent=2))
        results = (done or {}).get("results") or {}
        return 0 if done and results and all(r.get("ok") for r in results.values()) else 1
    except SideloadError as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
