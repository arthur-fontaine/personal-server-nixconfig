"""hermes-app and the app_delivery plugin against fake Apple tools.

The fakes are small Python scripts: xcrun (devicectl list and install),
xcodebuild (makes a signed-looking .app), xcodegen, security (cms -D prints the
profile, which the fake writes as a plain plist), defaults (Xcode's teams).
Run: python3 -I tests/test_app_delivery.py (from modules/hermes/app-delivery).
"""

from __future__ import annotations

import datetime as dt
import json
import os
import plistlib
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "hermes_app"))
sys.path.insert(0, str(HERE.parent))

import cli  # noqa: E402
from plugin import Delivery, summary  # noqa: E402

FAKES = {
    "xcrun": r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
log = Path(os.environ["FAKE_DIR"]) / "calls.jsonl"
with log.open("a") as f:
    f.write(json.dumps({"tool": "xcrun", "args": args}) + "\n")
if args[:3] == ["devicectl", "list", "devices"]:
    out = args[args.index("--json-output") + 1]
    devices = json.loads((Path(os.environ["FAKE_DIR"]) / "devices.json").read_text())
    Path(out).write_text(json.dumps({"result": {"devices": devices}}))
    sys.exit(0)
if args[:4] == ["devicectl", "device", "install", "app"]:
    udid = args[args.index("--device") + 1]
    if udid in os.environ.get("FAKE_INSTALL_FAIL", ""):
        print("error: the device was not reachable")
        sys.exit(1)
    print("App installed")
    sys.exit(0)
sys.exit(2)
''',
    "xcodebuild": r'''
import datetime as dt, json, os, plistlib, sys
from pathlib import Path
args = sys.argv[1:]
fake = Path(os.environ["FAKE_DIR"])
env = {k: v for k, v in os.environ.items() if k.startswith("HERMES_")}
with (fake / "calls.jsonl").open("a") as f:
    f.write(json.dumps({"tool": "xcodebuild", "args": args, "env": env}) + "\n")
if os.environ.get("FAKE_BUILD_FAIL"):
    print("/src/App.swift:1: error: cannot find 'Pet' in scope")
    sys.exit(65)
derived = Path(args[args.index("-derivedDataPath") + 1])
app = derived / "Build/Products/Release-iphoneos/HermesApp.app"
app.mkdir(parents=True, exist_ok=True)
build = next(a.split("=", 1)[1] for a in args if a.startswith("CURRENT_PROJECT_VERSION="))
(app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.0", "CFBundleVersion": build,
    "CFBundleIdentifier": env["HERMES_BUNDLE_ID_PREFIX"] + ".app"}, fmt=plistlib.FMT_BINARY))
expires = dt.datetime.now(dt.timezone.utc).replace(microsecond=0, tzinfo=None) + dt.timedelta(days=7)
(app / "embedded.mobileprovision").write_bytes(plistlib.dumps({"ExpirationDate": expires,
    "Entitlements": {"application-identifier": env["HERMES_TEAM_ID"] + "." + env["HERMES_BUNDLE_ID_PREFIX"] + ".app"}}))
print("** BUILD SUCCEEDED **")
''',
    "xcodegen": r'''
import json, os, sys
from pathlib import Path
with (Path(os.environ["FAKE_DIR"]) / "calls.jsonl").open("a") as f:
    f.write(json.dumps({"tool": "xcodegen", "args": sys.argv[1:], "cwd": os.getcwd()}) + "\n")
Path("HermesApp.xcodeproj").mkdir(exist_ok=True)
''',
    "security": r'''
import sys
from pathlib import Path
args = sys.argv[1:]
assert args[:3] == ["cms", "-D", "-i"], args
sys.stdout.write(Path(args[3]).read_text())
''',
    "defaults": r'''
import os, sys
from pathlib import Path
prefs = Path(os.environ["FAKE_DIR"]) / "xcode.plist"
if not prefs.exists():
    sys.exit(1)
sys.stdout.write(prefs.read_text())
''',
    "launchctl": "import sys; sys.exit(113)\n",
}


def device(udid: str, name: str, tunnel: str = "disconnected", platform: str = "iOS", paired: bool = True) -> dict:
    return {
        "identifier": "CORE-" + udid,
        "hardwareProperties": {"udid": udid, "platform": platform, "marketingName": "iPhone 15", "productType": "iPhone15,4"},
        "deviceProperties": {"name": name, "osVersionNumber": "26.1", "developerModeStatus": "enabled"},
        "connectionProperties": {"pairingState": "paired" if paired else "unpaired", "transportType": "localNetwork",
                                 "tunnelState": tunnel},
    }


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.root = root
        self.fake = root / "fake"
        self.fake.mkdir()
        os.environ["FAKE_DIR"] = str(self.fake)
        for var in ("FAKE_INSTALL_FAIL", "FAKE_BUILD_FAIL"):
            os.environ.pop(var, None)
        tools = {}
        for name, body in FAKES.items():
            path = self.fake / name
            path.write_text(f"#!{sys.executable}\n{body}")
            path.chmod(0o755)
            tools[name] = str(path)
        self.source = root / "store/hermes-ios"
        (self.source / "HermesApp/Assets.xcassets/AppIcon.appiconset").mkdir(parents=True)
        (self.source / "project.yml").write_text("name: HermesApp\n")
        (self.source / "HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png").write_bytes(b"default")
        # As in the Nix store.
        for path in [*self.source.rglob("*")]:
            path.chmod(0o555 if path.is_dir() else 0o444)
        self.home = root / "home"
        (self.home / ".hermes/app/pet").mkdir(parents=True)
        secrets = root / "secrets.env"
        secrets.write_text("TELEGRAM_API_ID=12345\nTELEGRAM_API_HASH=abcdef\n")
        self.cfg = cli.Config({
            "home": str(self.home), "source": str(self.source), "team_id": "TEAM123456",
            "secrets_file": str(secrets), "tools": tools, "launchd_label": "",
            "refresh_before_hours": 48,
        })
        self.devices([device("UDID-A", "Arthur's iPhone"), device("UDID-W", "Watch", platform="watchOS")])

    def tearDown(self):
        for path in self.root.rglob("*"):
            if not path.is_symlink():
                path.chmod(0o755 if path.is_dir() else 0o644)
        self.tmp.cleanup()

    def devices(self, devices: list[dict]) -> None:
        (self.fake / "devices.json").write_text(json.dumps(devices))

    def calls(self, tool: str) -> list[dict]:
        path = self.fake / "calls.jsonl"
        if not path.exists():
            return []
        return [c for c in map(json.loads, path.read_text().splitlines()) if c["tool"] == tool]

    def state(self) -> dict:
        return json.loads(self.cfg.delivery.read_text())


class Devices(Base):
    def test_lists_ios_devices_only(self):
        self.devices([device("UDID-A", "iPhone"), device("UDID-P", "iPad", tunnel="unavailable"),
                      device("UDID-W", "Watch", platform="watchOS"), device("UDID-N", "New", paired=False)])
        listed = {d["id"]: d for d in cli.list_devices(self.cfg)}
        self.assertEqual(set(listed), {"UDID-A", "UDID-P", "UDID-N"})
        self.assertTrue(listed["UDID-A"]["reachable"])
        self.assertFalse(listed["UDID-P"]["reachable"])
        self.assertFalse(listed["UDID-N"]["paired"])
        self.assertEqual(listed["UDID-A"]["name"], "iPhone")

    def test_devices_command_merges_known(self):
        state = cli.load_state(self.cfg)
        gone = cli.device_entry(state, "UDID-OLD")
        gone.update({"name": "Old iPad", "chosen": True})
        cli.save_state(self.cfg, state)
        out = cli.cmd_devices(self.cfg)
        ids = {d["id"]: d for d in out["devices"]}
        self.assertTrue(ids["UDID-A"]["reachable"])
        self.assertFalse(ids["UDID-OLD"]["reachable"])
        self.assertTrue(ids["UDID-OLD"]["chosen"])


class Teams(Base):
    def test_free_team_from_xcode(self):
        (self.fake / "xcode.plist").write_text(plistlib.dumps({"IDEProvisioningTeamByIdentifier": {
            "acct": [{"teamID": "PAID000001", "teamName": "Paid", "isFreeProvisioningTeam": False},
                     {"teamID": "FREE000001", "teamName": "Arthur (Personal Team)", "isFreeProvisioningTeam": True}]}}).decode())
        self.cfg.team_id = None
        self.assertEqual(cli.team(self.cfg), {"id": "FREE000001", "paid": False})
        self.cfg.paid = True
        self.assertEqual(cli.team(self.cfg), {"id": "PAID000001", "paid": True})

    def test_no_account(self):
        self.cfg.team_id = None
        with self.assertRaisesRegex(cli.AppError, "no Apple Account in Xcode"):
            cli.team(self.cfg)

    def test_prefix_from_team(self):
        self.assertEqual(cli.bundle_prefix(self.cfg, "TEAM123456"), "org.personal-server.hermes.team123456")
        self.cfg.bundle_id_prefix = "me.example.hermes"
        self.assertEqual(cli.bundle_prefix(self.cfg, "TEAM123456"), "me.example.hermes")


class Install(Base):
    def test_first_install_goes_to_paired_devices_with_the_pet(self):
        (self.cfg.pet / "icon.png").write_bytes(b"pet icon")
        (self.cfg.pet / "spritesheet.webp").write_bytes(b"sprites")
        (self.cfg.pet / "pet.json").write_text(json.dumps({"id": "fox", "displayName": "Fox", "version": 3}))
        request = cli.queue(self.cfg, [], "new pet Fox")
        self.assertEqual(cli.cmd_run(self.cfg), 0)

        src = self.cfg.cache_dir / "src"
        self.assertEqual((src / cli.ICON).read_bytes(), b"pet icon")
        self.assertEqual((src / "Pet/spritesheet.webp").read_bytes(), b"sprites")
        self.assertEqual(Path(self.calls("xcodegen")[0]["cwd"]).resolve(), src.resolve())
        build = self.calls("xcodebuild")
        self.assertEqual(len(build), 1)
        args, env = build[0]["args"], build[0]["env"]
        self.assertIn("id=UDID-A", args)
        self.assertIn("-allowProvisioningUpdates", args)
        self.assertIn("-allowProvisioningDeviceRegistration", args)
        self.assertEqual(env["HERMES_TEAM_ID"], "TEAM123456")
        self.assertEqual(env["HERMES_PAID_TEAM"], "0")
        self.assertEqual(env["HERMES_TG_API_HASH"], "abcdef")
        self.assertFalse(any("abcdef" in a for a in args), "secrets stay out of the command line")
        installs = [c for c in self.calls("xcrun") if c["args"][:2] == ["devicectl", "device"]]
        self.assertEqual([c["args"][5] for c in installs], ["UDID-A"])

        state = self.state()
        phone = next(d for d in state["devices"] if d["id"] == "UDID-A")
        self.assertTrue(phone["chosen"])
        self.assertTrue(phone["last_install"]["ok"])
        self.assertEqual(phone["last_install"]["pet_version"], 3)
        self.assertEqual(phone["last_install"]["reason"], "new pet Fox")
        expires = cli.parse_iso(phone["profile_expires"])
        self.assertGreater(expires, cli.now() + dt.timedelta(days=6))
        self.assertEqual(cli.parse_iso(state["next_refresh"]), expires - dt.timedelta(hours=48))
        self.assertIsNone(state["running"])
        self.assertEqual(state["team"], {"id": "TEAM123456", "paid": False})
        done = json.loads((self.cfg.done / f"{request['id']}.json").read_text())
        self.assertTrue(done["results"]["UDID-A"]["ok"])
        self.assertFalse(list(self.cfg.requests.glob("*.json")))

    def test_failures_are_recorded_per_device(self):
        self.devices([device("UDID-A", "iPhone"), device("UDID-B", "iPad"), device("UDID-C", "Away", tunnel="unavailable")])
        os.environ["FAKE_INSTALL_FAIL"] = "UDID-B"
        request = cli.queue(self.cfg, ["UDID-A", "UDID-B", "UDID-C", "UDID-X"], "asked")
        cli.cmd_run(self.cfg)
        results = json.loads((self.cfg.done / f"{request['id']}.json").read_text())["results"]
        self.assertTrue(results["UDID-A"]["ok"])
        self.assertIn("devicectl install failed", results["UDID-B"]["error"])
        self.assertIn("not reachable", results["UDID-C"]["error"])
        self.assertIn("not paired", results["UDID-X"]["error"])
        # Never built for a device that cannot take it.
        self.assertEqual(len(self.calls("xcodebuild")), 2)
        chosen = {d["id"] for d in self.state()["devices"] if d["chosen"]}
        self.assertEqual(chosen, {"UDID-A"})

    def test_build_error_is_reported(self):
        os.environ["FAKE_BUILD_FAIL"] = "1"
        request = cli.queue(self.cfg, ["UDID-A"], "asked")
        cli.cmd_run(self.cfg)
        result = json.loads((self.cfg.done / f"{request['id']}.json").read_text())["results"]["UDID-A"]
        self.assertFalse(result["ok"])
        self.assertIn("cannot find 'Pet' in scope", result["error"])

    def test_no_source(self):
        self.cfg.source = str(self.root / "missing")
        request = cli.queue(self.cfg, ["UDID-A"], "asked")
        cli.cmd_run(self.cfg)
        result = json.loads((self.cfg.done / f"{request['id']}.json").read_text())["results"]["UDID-A"]
        self.assertIn("no app source", result["error"])
        self.assertIsNone(self.state()["running"])

    def test_nothing_to_do(self):
        cli.cmd_run(self.cfg)
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_locked_run_leaves_the_queue(self):
        import fcntl
        self.cfg.state_dir.mkdir(parents=True, exist_ok=True)
        with open(self.cfg.state_dir / "run.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            cli.queue(self.cfg, ["UDID-A"], "asked")
            self.assertEqual(cli.cmd_run(self.cfg), 0)
        self.assertEqual(len(list(self.cfg.requests.glob("*.json"))), 1)


class Refresh(Base):
    def chosen(self, expires_in: dt.timedelta) -> None:
        state = cli.load_state(self.cfg)
        entry = cli.device_entry(state, "UDID-A")
        entry.update({"chosen": True, "profile_expires": cli.iso(cli.now() + expires_in)})
        cli.save_state(self.cfg, state)

    def test_not_due(self):
        self.chosen(dt.timedelta(days=5))
        cli.cmd_run(self.cfg)
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_due_purges_this_apps_profiles_and_reinstalls(self):
        self.chosen(dt.timedelta(hours=30))
        profiles = self.home / cli.PROFILE_DIRS[0]
        profiles.mkdir(parents=True)
        ours = profiles / "ours.mobileprovision"
        theirs = profiles / "theirs.mobileprovision"
        ours.write_bytes(plistlib.dumps({"Entitlements": {"application-identifier": "TEAM123456.org.personal-server.hermes.team123456.app.widgets"}}))
        theirs.write_bytes(plistlib.dumps({"Entitlements": {"application-identifier": "TEAM123456.com.other.app"}}))
        cli.cmd_run(self.cfg)
        self.assertFalse(ours.exists())
        self.assertTrue(theirs.exists())
        self.assertEqual(len(self.calls("xcodebuild")), 1)
        phone = next(d for d in self.state()["devices"] if d["id"] == "UDID-A")
        self.assertEqual(phone["last_install"]["reason"], "profile expires soon")
        self.assertGreater(cli.parse_iso(phone["profile_expires"]), cli.now() + dt.timedelta(days=6))

    def test_default_targets_are_the_chosen_ones(self):
        self.devices([device("UDID-A", "iPhone"), device("UDID-B", "iPad")])
        self.chosen(dt.timedelta(days=5))
        request = cli.queue(self.cfg, [], "new pet")
        cli.cmd_run(self.cfg)
        results = json.loads((self.cfg.done / f"{request['id']}.json").read_text())["results"]
        self.assertEqual(list(results), ["UDID-A"])


class Plugin(Base):
    def test_install_notifies_the_chat_that_asked(self):
        command = self.fake / "hermes-app"
        config = self.fake / "config.json"
        config.write_text(json.dumps({**{k: str(v) for k, v in {"home": self.home, "source": self.source,
                                                                 "secrets_file": self.cfg.secrets_file}.items()},
                                      "team_id": "TEAM123456", "tools": self.cfg.tools}))
        command.write_text(f"#!/bin/sh\nHERMES_APP_CONFIG={config} exec {sys.executable} -I {HERE.parent / 'hermes_app/cli.py'} \"$@\"\n")
        command.chmod(0o755)
        events = []
        delivery = Delivery({"command": str(command), "state_dir": str(self.cfg.state_dir), "poll_seconds": 0.2},
                            notify=events.append)
        listed = delivery.devices()
        self.assertEqual([d["id"] for d in listed["devices"]], ["UDID-A"])
        started = delivery.install(["UDID-A"], "new pet", {"platform": "telegram", "chat_id": "42", "thread_id": "7"})
        self.assertTrue(started["started"])
        deadline = time.monotonic() + 60
        while not events and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertEqual(len(events), 1, "the end of the install reaches the chat")
        event = events[0]
        self.assertEqual(event["type"], "watch_match")
        self.assertEqual((event["platform"], event["chat_id"], event["thread_id"]), ("telegram", "42", "7"))
        self.assertIn("Arthur's iPhone: installed 1.0", event["output"])

    def test_summary(self):
        text = summary({"results": {"U1": {"ok": False, "error": "boom"}}, "log": "/l"}, {"U1": "iPad"})
        self.assertIn("iPad: failed: boom", text)
        self.assertIn("no device", summary({"results": {}}, {}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
