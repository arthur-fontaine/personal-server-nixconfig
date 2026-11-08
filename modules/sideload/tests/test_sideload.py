"""sideload and Hermes' sideload plugin against fake Apple tools.

The fakes are small Python scripts: xcrun (devicectl list, install,
uninstall), xcodebuild (makes a signed-looking .app), xcodegen, security (cms
-D prints the profile, which the fake writes as a plain plist), defaults
(Xcode's teams), codesign, ditto (unzip). Run: python3 -I tests/test_sideload.py
(from modules/sideload), with ../hermes/plugins on the path for the plugin.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import plistlib
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "sideload"))
sys.path.insert(0, str(HERE.parent.parent / "hermes" / "plugins"))

import cli  # noqa: E402
from sideload import Sideload, summary  # noqa: E402  (Hermes' plugin)

LOG = r'''
import json, os, sys
from pathlib import Path
def log(tool, **extra):
    with (Path(os.environ["FAKE_DIR"]) / "calls.jsonl").open("a") as f:
        f.write(json.dumps({"tool": tool, "args": sys.argv[1:], **extra}) + "\n")
'''

FAKES = {
    "xcrun": LOG + r'''
args = sys.argv[1:]
log("xcrun")
fake = Path(os.environ["FAKE_DIR"])
if args[:3] == ["devicectl", "list", "devices"]:
    out = args[args.index("--json-output") + 1]
    Path(out).write_text(json.dumps({"result": {"devices": json.loads((fake / "devices.json").read_text())}}))
    sys.exit(0)
if args[:4] == ["devicectl", "device", "install", "app"]:
    if args[args.index("--device") + 1] in os.environ.get("FAKE_INSTALL_FAIL", ""):
        print("error: the device was not reachable"); sys.exit(1)
    print("App installed"); sys.exit(0)
if args[:4] == ["devicectl", "device", "uninstall", "app"]:
    print("App uninstalled"); sys.exit(0)
sys.exit(2)
''',
    "xcodebuild": LOG + r'''
import datetime as dt, plistlib
args = sys.argv[1:]
env = {k: v for k, v in os.environ.items() if k.startswith("HERMES_") or k.startswith("APP_")}
log("xcodebuild", env=env)
if os.environ.get("FAKE_BUILD_FAIL"):
    print("/src/App.swift:1: error: cannot find 'Pet' in scope"); sys.exit(65)
settings = dict(a.split("=", 1) for a in args if "=" in a and not a.startswith("-"))
scheme = args[args.index("-scheme") + 1]
team = settings.get("DEVELOPMENT_TEAM") or env.get("HERMES_TEAM_ID")
bid = settings.get("PRODUCT_BUNDLE_IDENTIFIER") or (env.get("HERMES_BUNDLE_ID_PREFIX", "x") + ".app")
app = Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release-iphoneos" / f"{scheme}.app"
app.mkdir(parents=True, exist_ok=True)
(app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.0",
    "CFBundleVersion": settings.get("CURRENT_PROJECT_VERSION", "1"), "CFBundleIdentifier": bid}, fmt=plistlib.FMT_BINARY))
if scheme == "HermesApp":
    (app / "PlugIns/Widgets.appex").mkdir(parents=True, exist_ok=True)
    (app / "PlugIns/Widgets.appex/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bid + ".widgets"}))
expires = dt.datetime.now(dt.timezone.utc).replace(microsecond=0, tzinfo=None) + dt.timedelta(days=7)
(app / "embedded.mobileprovision").write_bytes(plistlib.dumps({"ExpirationDate": expires,
    "Entitlements": {"application-identifier": f"{team}.{bid}", "get-task-allow": True, "aps-environment": "x"}}))
print("** BUILD SUCCEEDED **")
''',
    "xcodegen": LOG + r'''
log("xcodegen", cwd=os.getcwd())
spec = Path("project.yml").read_text()
name = json.loads(spec)["name"] if spec.lstrip().startswith("{") else "HermesApp"
Path(f"{name}.xcodeproj").mkdir(exist_ok=True)
''',
    "security": r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
# The login keychain's identities: FAKE_DIR/identities.json, {name: certificate subject}.
ids = Path(os.environ["FAKE_DIR"]) / "identities.json"
identities = json.loads(ids.read_text()) if ids.exists() else {}
if args[:1] == ["find-identity"]:
    for i, name in enumerate(identities, 1):
        print(f'  {i}) {i:040X} "{name}"')
    print(f"     {len(identities)} valid identities found")
    sys.exit(0)
if args[:1] == ["find-certificate"]:
    name = args[args.index("-c") + 1]
    if name not in identities:
        sys.exit(44)
    print("-----BEGIN CERTIFICATE-----\n" + identities[name] + "\n-----END CERTIFICATE-----")
    sys.exit(0)
assert args[:3] == ["cms", "-D", "-i"], args
sys.stdout.write(Path(args[3]).read_text())
''',
    # Prints the subject the fake security put in the PEM, as LibreSSL does.
    "openssl": r'''
import sys
assert sys.argv[1:] == ["x509", "-noout", "-subject"], sys.argv
print("subject= " + sys.stdin.read().splitlines()[1])
''',
    "defaults": r'''
import os, sys
from pathlib import Path
prefs = Path(os.environ["FAKE_DIR"]) / "xcode.plist"
if not prefs.exists():
    sys.exit(1)
sys.stdout.write(prefs.read_text())
''',
    "codesign": LOG + r'''
log("codesign")
if sys.argv[1] == "-dvv":
    sys.stderr.write("Executable=x\nAuthority=Apple Development: arthur@example.com (ABC)\nAuthority=Apple WWDR\n")
''',
    "ditto": r'''
import sys, zipfile
args = sys.argv[1:]
assert args[:2] == ["-x", "-k"], args
zipfile.ZipFile(args[2]).extractall(args[3])
''',
    "launchctl": "import sys; sys.exit(113)\n",
    "git": "import sys; sys.exit(1)\n",
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
        root = self.root = Path(self.tmp.name)
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
        for path in [*self.source.rglob("*")]:  # as in the Nix store
            path.chmod(0o555 if path.is_dir() else 0o444)
        self.home = root / "home"
        self.pet = self.home / ".hermes/app/pet"
        self.pet.mkdir(parents=True)
        secrets = root / "secrets.env"
        secrets.write_text("TELEGRAM_API_ID=12345\nTELEGRAM_API_HASH=abcdef\n")
        self.status_file = self.home / ".hermes/app/delivery.json"
        hermes = {
            "name": "Hermes", "source": str(self.source), "scheme": "HermesApp", "prefix_name": "hermes",
            "team_env": {"team_id": "HERMES_TEAM_ID", "bundle_id_prefix": "HERMES_BUNDLE_ID_PREFIX", "paid": "HERMES_PAID_TEAM"},
            "secret_env": {"HERMES_TG_API_ID": "TELEGRAM_API_ID", "HERMES_TG_API_HASH": "TELEGRAM_API_HASH"},
            "env_commands": {"HERMES_BOT_USERNAME": "echo hermes_bot"},
            "inputs": [{"from": str(self.pet / "icon.png"), "to": "HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"},
                       {"from": str(self.pet / "spritesheet.webp"), "to": "Pet/spritesheet.webp"}],
            "version_file": str(self.pet / "pet.json"), "status_file": str(self.status_file),
        }
        self.config = {"home": str(self.home), "team": {"id": "TEAM123456"}, "secrets_file": str(secrets),
                       "tools": tools, "launchd_label": "", "refresh_before_hours": 48, "apps": {"hermes": hermes}}
        self.cfg = cli.Config(self.config)
        self.devices([device("UDID-A", "Arthur's iPhone"), device("UDID-W", "Watch", platform="watchOS")])

    def tearDown(self):
        for path in self.root.rglob("*"):
            if not path.is_symlink():
                path.chmod(0o755 if path.is_dir() else 0o644)
        self.tmp.cleanup()

    def devices(self, devices: list) -> None:
        (self.fake / "devices.json").write_text(json.dumps(devices))

    def calls(self, tool: str) -> list:
        path = self.fake / "calls.jsonl"
        return [c for c in map(json.loads, path.read_text().splitlines()) if c["tool"] == tool] if path.exists() else []

    def state(self) -> dict:
        return json.loads(self.cfg.state_file.read_text())

    def done(self, request) -> dict:
        return json.loads((self.cfg.done / f"{request['id']}.json").read_text())

    def ipa(self, bid="com.vendor.tool", name="Tool") -> Path:
        path = self.root / f"{name}.ipa"
        with zipfile.ZipFile(path, "w") as z:
            z.writestr(f"Payload/{name}.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": bid, "CFBundleVersion": "7",
                                                                         "CFBundleShortVersionString": "2.0", "MinimumOSVersion": "16.0"}))
            z.writestr(f"Payload/{name}.app/{name}", b"binary")
            z.writestr(f"Payload/{name}.app/Frameworks/Lib.framework/Lib", b"lib")
            z.writestr(f"Payload/{name}.app/PlugIns/Share.appex/Info.plist", plistlib.dumps({"CFBundleIdentifier": bid + ".share"}))
        return path

    def add(self, *argv) -> dict:
        parser_args = cli.argparse.Namespace(app=argv[0], ipa=None, project=None, scheme=None, ref=None, name=None,
                                             keep_bundle_id=False)
        for key, value in zip(argv[1::2], argv[2::2]):
            setattr(parser_args, key, value)
        return cli.cmd_add(self.cfg, parser_args)


class Devices(Base):
    def test_lists_ios_devices_only(self):
        self.devices([device("UDID-A", "iPhone"), device("UDID-P", "iPad", tunnel="unavailable"),
                      device("UDID-W", "Watch", platform="watchOS"), device("UDID-N", "New", paired=False)])
        listed = {d["id"]: d for d in cli.list_devices(self.cfg)}
        self.assertEqual(set(listed), {"UDID-A", "UDID-P", "UDID-N"})
        self.assertTrue(listed["UDID-A"]["reachable"])
        self.assertFalse(listed["UDID-P"]["reachable"])
        self.assertFalse(listed["UDID-N"]["paired"])


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
        with self.assertRaisesRegex(cli.SideloadError, "no Apple Account in Xcode"):
            cli.team(self.cfg)

    def xcode27(self, identities: dict) -> None:
        """Xcode 27 keeps only the account list in its preferences."""
        (self.fake / "xcode.plist").write_text(plistlib.dumps({
            "DVTDeveloperAccountManagerAppleIDLists": {"IDE.Prod": [{"username": "arthur@example.com"}]},
            "IDELastViewedSettingsPane": "Accounts"}).decode())
        (self.fake / "identities.json").write_text(json.dumps(identities))
        self.cfg.team_id = None

    def test_xcode27_team_from_the_development_certificate(self):
        self.xcode27({"Apple Development: arthur@example.com (Q2W3E4R5T6)":
                      "/UID=ABCDEF1234/CN=Apple Development: arthur@example.com (Q2W3E4R5T6)/OU=FREE000027/O=Arthur Fontaine/C=FR"})
        self.assertEqual(cli.find_team(self.cfg), {"id": "FREE000027", "paid": False, "source": "development certificate"})
        self.cfg.paid = True
        self.assertEqual(cli.team(self.cfg), {"id": "FREE000027", "paid": True})

    def test_xcode27_account_without_certificate(self):
        self.xcode27({})
        with self.assertRaisesRegex(cli.SideloadError, "Manage Certificates"):
            cli.team(self.cfg)

    def test_configured_team_first(self):
        self.xcode27({})
        self.cfg.team_id = "CONF000001"
        self.assertEqual(cli.find_team(self.cfg)["source"], "configuration")

    def test_team_command(self):
        self.xcode27({})
        config = self.root / "config.json"
        config.write_text(json.dumps({**self.config, "team": {}}))
        os.environ["SIDELOAD_CONFIG"] = str(config)
        try:
            self.assertEqual(cli.main(["team"]), 1)
            (self.fake / "identities.json").write_text(json.dumps({"Apple Development: a (B)": "/CN=Apple Development: a (B)/OU=FREE000027"}))
            self.assertEqual(cli.main(["team"]), 0)
        finally:
            os.environ.pop("SIDELOAD_CONFIG")


class Failures(Base):
    def main(self, *argv) -> int:
        config = self.root / "config.json"
        config.write_text(json.dumps(self.config))
        os.environ["SIDELOAD_CONFIG"] = str(config)
        try:
            return cli.main(list(argv))
        finally:
            os.environ.pop("SIDELOAD_CONFIG")

    def test_install_without_a_team_is_refused_logged_and_kept(self):
        self.config["team"] = {}
        self.assertEqual(self.main("install", "hermes", "--reason", "first install"), 1)
        self.assertFalse(list(self.cfg.requests.glob("*.json")))  # nothing queued
        self.assertIn("no Apple Account in Xcode", self.cfg.log_file.read_text())
        self.assertIn("no Apple Account in Xcode", cli.app_status(self.cfg, self.state(), "hermes")["last_error"]["error"])

    def test_team_lost_after_queueing_is_logged_and_answered(self):
        request = cli.queue(self.cfg, "hermes", ["UDID-A"], "asked")
        self.cfg.team_id = None
        cli.cmd_run(self.cfg)
        self.assertIn("no Apple Account", self.done(request)["results"]["UDID-A"]["error"])
        self.assertIn("no Apple Account", self.state()["last_error"]["error"])
        self.assertIn("hermes on UDID-A: failed", self.cfg.log_file.read_text())

    def test_a_crashed_job_still_answers_each_request(self):
        request = cli.queue(self.cfg, "hermes", [], "first install")
        from unittest import mock
        with mock.patch.object(cli, "refresh_seen", side_effect=RuntimeError("boom")), self.assertRaises(RuntimeError):
            cli.cmd_run(self.cfg)
        done = self.done(request)
        self.assertIn("the job failed", done["results"]["*"]["error"])
        self.assertIn("the job failed", self.state()["last_error"]["error"])
        self.assertIsNone(self.state()["running"])

    def test_a_success_clears_the_last_error(self):
        cli.note_error(self.cfg, "earlier")
        cli.queue(self.cfg, "hermes", ["UDID-A"], "asked")
        cli.cmd_run(self.cfg)
        self.assertIsNone(self.state()["last_error"])


class HermesApp(Base):
    def test_first_install_with_the_pet(self):
        (self.pet / "icon.png").write_bytes(b"pet icon")
        (self.pet / "spritesheet.webp").write_bytes(b"sprites")
        (self.pet / "pet.json").write_text(json.dumps({"id": "fox", "version": 3}))
        request = cli.queue(self.cfg, "hermes", [], "new pet Fox")
        self.assertEqual(cli.cmd_run(self.cfg), 0)
        src = self.cfg.cache_dir / "apps/hermes/src"
        self.assertEqual((src / "HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png").read_bytes(), b"pet icon")
        self.assertEqual((src / "Pet/spritesheet.webp").read_bytes(), b"sprites")
        build = self.calls("xcodebuild")
        self.assertEqual(len(build), 1)
        args, env = build[0]["args"], build[0]["env"]
        self.assertIn("id=UDID-A", args)
        self.assertIn("-allowProvisioningDeviceRegistration", args)
        self.assertEqual(env["HERMES_TEAM_ID"], "TEAM123456")
        self.assertEqual(env["HERMES_BUNDLE_ID_PREFIX"], "org.personal-server.hermes.team123456")
        self.assertEqual(env["HERMES_TG_API_HASH"], "abcdef")
        self.assertEqual(env["HERMES_BOT_USERNAME"], "hermes_bot")
        self.assertFalse(any("abcdef" in a for a in args), "secrets stay out of the command line")
        self.assertTrue(self.done(request)["results"]["UDID-A"]["ok"])
        # The Hermes app's delivery.json, as app-backend reads it.
        status = json.loads(self.status_file.read_text())
        phone = next(d for d in status["devices"] if d["id"] == "UDID-A")
        self.assertTrue(phone["chosen"])
        self.assertEqual(phone["last_install"]["input_version"], 3)
        self.assertEqual(phone["last_install"]["reason"], "new pet Fox")
        expires = cli.parse_iso(phone["profile_expires"])
        self.assertGreater(expires, cli.now() + dt.timedelta(days=6))
        self.assertEqual(cli.parse_iso(status["next_refresh"]), expires - dt.timedelta(hours=48))
        self.assertIsNone(status["running"])
        # Its two App IDs (the app and its widgets) are counted.
        self.assertEqual(len(self.state()["app_ids"]), 2)

    def test_failures_are_recorded_per_device(self):
        self.devices([device("UDID-A", "iPhone"), device("UDID-B", "iPad"), device("UDID-C", "Away", tunnel="unavailable")])
        os.environ["FAKE_INSTALL_FAIL"] = "UDID-B"
        request = cli.queue(self.cfg, "hermes", ["UDID-A", "UDID-B", "UDID-C", "UDID-X"], "asked")
        cli.cmd_run(self.cfg)
        results = self.done(request)["results"]
        self.assertTrue(results["UDID-A"]["ok"])
        self.assertIn("devicectl install failed", results["UDID-B"]["error"])
        self.assertIn("not reachable", results["UDID-C"]["error"])
        self.assertIn("not paired", results["UDID-X"]["error"])
        self.assertEqual(len(self.calls("xcodebuild")), 2)

    def test_build_error_and_missing_source(self):
        os.environ["FAKE_BUILD_FAIL"] = "1"
        request = cli.queue(self.cfg, "hermes", ["UDID-A"], "asked")
        cli.cmd_run(self.cfg)
        self.assertIn("cannot find 'Pet' in scope", self.done(request)["results"]["UDID-A"]["error"])
        os.environ.pop("FAKE_BUILD_FAIL")
        self.cfg.apps["hermes"]["source"] = str(self.root / "missing")
        request = cli.queue(self.cfg, "hermes", ["UDID-A"], "asked")
        cli.cmd_run(self.cfg)
        self.assertIn("no source for hermes", self.done(request)["results"]["UDID-A"]["error"])
        self.assertIsNone(self.state()["running"])

    def test_old_delivery_json_carries_over(self):
        self.status_file.parent.mkdir(parents=True, exist_ok=True)
        expires = cli.iso(cli.now() + dt.timedelta(days=5))
        self.status_file.write_text(json.dumps({"devices": [{"id": "UDID-A", "name": "Old", "chosen": True,
                                                             "profile_expires": expires, "last_install": {"ok": True}}]}))
        state = cli.load_state(self.cfg)
        self.assertEqual(state["apps"]["hermes"]["installs"]["UDID-A"]["profile_expires"], expires)

    def test_locked_run_leaves_the_queue(self):
        import fcntl
        self.cfg.state_dir.mkdir(parents=True, exist_ok=True)
        with open(self.cfg.state_dir / "run.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            cli.queue(self.cfg, "hermes", ["UDID-A"], "asked")
            self.assertEqual(cli.cmd_run(self.cfg), 0)
        self.assertEqual(len(list(self.cfg.requests.glob("*.json"))), 1)


class Refresh(Base):
    def installed(self, expires_in: dt.timedelta) -> None:
        state = cli.load_state(self.cfg)
        cli.installs(state, "hermes")["UDID-A"] = {"ok": True, "bundle_id": "org.personal-server.hermes.team123456.app",
                                                   "profile_expires": cli.iso(cli.now() + expires_in)}
        cli.save_state(self.cfg, state)

    def test_not_due(self):
        self.installed(dt.timedelta(days=5))
        cli.cmd_run(self.cfg)
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_due_purges_this_apps_profiles_and_reinstalls(self):
        self.installed(dt.timedelta(hours=30))
        profiles = self.home / cli.PROFILE_DIRS[0]
        profiles.mkdir(parents=True)
        ours, theirs = profiles / "ours.mobileprovision", profiles / "theirs.mobileprovision"
        ours.write_bytes(plistlib.dumps({"Entitlements": {"application-identifier": "TEAM123456.org.personal-server.hermes.team123456.app.widgets"}}))
        theirs.write_bytes(plistlib.dumps({"Entitlements": {"application-identifier": "TEAM123456.com.other.app"}}))
        cli.cmd_run(self.cfg)
        self.assertFalse(ours.exists())
        self.assertTrue(theirs.exists())
        record = self.state()["apps"]["hermes"]["installs"]["UDID-A"]
        self.assertEqual(record["reason"], "profile expires soon")
        self.assertGreater(cli.parse_iso(record["profile_expires"]), cli.now() + dt.timedelta(days=6))

    def test_failed_refresh_keeps_the_install(self):
        self.installed(dt.timedelta(hours=30))
        os.environ["FAKE_BUILD_FAIL"] = "1"
        cli.cmd_run(self.cfg)
        record = self.state()["apps"]["hermes"]["installs"]["UDID-A"]
        self.assertTrue(record["ok"])
        self.assertIn("xcodebuild failed", record["error"])


class Ipa(Base):
    def test_add_resign_install(self):
        added = self.add("tool", "ipa", str(self.ipa()))
        self.assertEqual(added["kind"], "ipa")
        request = cli.queue(self.cfg, "tool", [], "asked")
        cli.cmd_run(self.cfg)
        result = self.done(request)["results"]["UDID-A"]
        self.assertTrue(result["ok"], result)
        bid = "org.personal-server.sideload.tool.team123456"
        self.assertEqual(result["bundle_id"], bid)
        # A stub signs for the new id; the .ipa's app is signed with its profile, frameworks first, extensions dropped.
        stub = self.calls("xcodebuild")[0]["args"]
        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER={bid}", stub)
        signs = [c["args"] for c in self.calls("codesign") if c["args"][0] == "-f"]
        self.assertTrue(signs[0][-1].endswith("Lib.framework"))
        self.assertTrue(signs[-1][-1].endswith("Tool.app") and "--entitlements" in signs[-1])
        app = self.cfg.cache_dir / "apps/tool/payload/Payload/Tool.app"
        self.assertFalse((app / "PlugIns").exists())
        self.assertTrue((app / "embedded.mobileprovision").exists())
        ent = plistlib.loads((self.cfg.cache_dir / "apps/tool/entitlements.plist").read_bytes())
        self.assertNotIn("aps-environment", ent)
        apps = {a["id"]: a for a in cli.cmd_apps(self.cfg)["apps"]}
        self.assertEqual(apps["tool"]["devices"][0]["bundle_id"], bid)

    def test_not_an_ipa(self):
        junk = self.root / "x.ipa"
        junk.write_text("hello")
        with self.assertRaisesRegex(cli.SideloadError, "not an .ipa"):
            self.add("junk", "ipa", str(junk))

    def test_unknown_app(self):
        with self.assertRaisesRegex(cli.SideloadError, "unknown app 'nope'"):
            cli.app_definition(self.cfg, cli.load_state(self.cfg), "nope")


class Limits(Base):
    def test_three_apps_per_device(self):
        state = cli.load_state(self.cfg)
        for name in ("a", "b", "c"):
            cli.installs(state, name)["UDID-A"] = {"ok": True, "bundle_id": f"x.{name}"}
        cli.save_state(self.cfg, state)
        self.add("tool", "ipa", str(self.ipa()))
        request = cli.queue(self.cfg, "tool", ["UDID-A"], "asked")
        cli.cmd_run(self.cfg)
        error = self.done(request)["results"]["UDID-A"]["error"]
        self.assertIn("3 sideloaded apps per device", error)
        self.assertEqual(self.calls("codesign"), [])
        limits = cli.cmd_limits(self.cfg)
        self.assertEqual(limits["apps_per_device"]["UDID-A"]["apps"], ["a", "b", "c"])
        # A paid team has no such limit.
        self.cfg.paid = True
        cli.check_limits(state, {"paid": True}, "tool", "UDID-A", ["new"])

    def test_ten_app_ids_a_week(self):
        state = cli.load_state(self.cfg)
        state["app_ids"] = {f"id{i}": cli.iso(cli.now() - dt.timedelta(days=1)) for i in range(10)}
        state["app_ids"]["old"] = cli.iso(cli.now() - dt.timedelta(days=8))
        with self.assertRaisesRegex(cli.SideloadError, "10 new App IDs per 7 days, 10 used"):
            cli.check_limits(state, {"paid": False}, "tool", "UDID-A", ["fresh"])
        cli.check_limits(state, {"paid": False}, "tool", "UDID-A", ["id3"])  # already registered


class Remove(Base):
    def test_remove_and_forget(self):
        self.add("tool", "ipa", str(self.ipa()))
        cli.queue(self.cfg, "tool", [], "asked")
        cli.cmd_run(self.cfg)
        with self.assertRaisesRegex(cli.SideloadError, "still installed"):
            cli.cmd_forget(self.cfg, "tool")
        request = cli.queue(self.cfg, "tool", [], "done", action="remove")
        cli.cmd_run(self.cfg)
        self.assertTrue(self.done(request)["results"]["UDID-A"]["removed"])
        uninstall = [c for c in self.calls("xcrun") if c["args"][2:3] == ["uninstall"]]
        self.assertEqual(uninstall[0]["args"][-1], "org.personal-server.sideload.tool.team123456")
        self.assertEqual(cli.installed_on(self.state(), "UDID-A"), [])
        self.assertEqual(cli.cmd_forget(self.cfg, "tool"), {"forgotten": "tool"})
        with self.assertRaisesRegex(cli.SideloadError, "declared in the configuration"):
            cli.cmd_forget(self.cfg, "hermes")


class Plugin(Base):
    def test_install_notifies_the_chat_that_asked(self):
        command = self.fake / "sideload"
        config = self.fake / "config.json"
        config.write_text(json.dumps(self.config))
        command.write_text(f"#!/bin/sh\nSIDELOAD_CONFIG={config} exec {sys.executable} -I {HERE.parent / 'sideload/cli.py'} \"$@\"\n")
        command.chmod(0o755)
        events = []
        s = Sideload({"command": str(command), "state_dir": str(self.cfg.state_dir), "poll_seconds": 0.2}, notify=events.append)
        self.assertEqual([d["id"] for d in s.devices()["devices"]], ["UDID-A"])
        apps = s.apps()
        self.assertIn("hermes", [a["id"] for a in apps["apps"]])
        self.assertEqual(apps["limits"]["app_ids_this_week"]["max"], 10)
        started = s.install({"app": "tool", "ipa": str(self.ipa())}, {"platform": "telegram", "chat_id": "42", "thread_id": "7"})
        self.assertTrue(started.get("started"), started)
        deadline = time.monotonic() + 60
        while not events and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertEqual(len(events), 1, "the end of the install reaches the chat")
        event = events[0]
        self.assertEqual((event["type"], event["platform"], event["chat_id"]), ("watch_match", "telegram", "42"))
        self.assertIn("Arthur's iPhone: installed 2.0", event["output"])
        self.assertIn("error", s.install({"app": "nope"}, {}))

    def test_summary(self):
        text = summary("tool", {"results": {"U1": {"ok": False, "error": "boom"}}, "log": "/l"}, {"U1": "iPad"})
        self.assertIn("iPad: failed: boom", text)
        self.assertIn("no device", summary("tool", {"results": {}}, {}))


if __name__ == "__main__":
    unittest.main(verbosity=1)
