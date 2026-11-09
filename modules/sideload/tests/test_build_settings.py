"""The build environment sideload sets reaches each declared app's build.

sideload gives an Xcode project its team, bundle-id prefix and secrets as
environment variables (cli.py, Build.env): xcodebuild reads them as build
settings, but at the lowest precedence. Any assignment in the project's
xcconfigs or project.yml, even an empty one, wins: the Hermes app's
Base.xcconfig once assigned them all, and the server built it with no team.

SIDELOAD_APPS names a JSON file, written by checks/default.nix from the real
configuration: {app: {"source": dir, "names": [variable, …]}}. Without it,
only the checker's own tests run.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
import unittest
from pathlib import Path

ASSIGNMENT = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])*\s*=")
YAML_KEY = re.compile(r"^\s+([A-Za-z_][A-Za-z0-9_]*):(?:\s|$)")


def overrides(source: Path, names: set[str]) -> list[str]:
    """Where the project assigns one of `names`: "file:line NAME"."""
    found = []
    for path in sorted(source.rglob("*.xcconfig")):
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            match = ASSIGNMENT.match(line.split("//", 1)[0])
            if match and match.group(1) in names:
                found.append(f"{path.relative_to(source)}:{number} {match.group(1)}")
    spec = source / "project.yml"
    if spec.exists():
        for number, line in enumerate(spec.read_text().splitlines(), 1):
            match = YAML_KEY.match(line.split("#", 1)[0])
            if match and match.group(1) in names:
                found.append(f"project.yml:{number} {match.group(1)}")
    return found


class Checker(unittest.TestCase):
    def test_catches_an_empty_assignment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Config").mkdir()
            (root / "Config/Base.xcconfig").write_text(
                "// HERMES_TG_API_HASH = in a comment\nHERMES_TEAM_ID =\nHERMES_TG_API_ID[sdk=iphoneos*] = 1\n"
                "HERMES_ID_PREFIX = $(HERMES_BUNDLE_ID_PREFIX:default=x)\n")
            (root / "project.yml").write_text("settings:\n  base:\n    HERMES_BOT_USERNAME: bot\n    DEVELOPMENT_TEAM: $(HERMES_TEAM_ID)\n")
            names = {"HERMES_TEAM_ID", "HERMES_TG_API_ID", "HERMES_TG_API_HASH", "HERMES_BUNDLE_ID_PREFIX", "HERMES_BOT_USERNAME"}
            self.assertEqual(overrides(root, names), ["Config/Base.xcconfig:2 HERMES_TEAM_ID",
                                                      "Config/Base.xcconfig:3 HERMES_TG_API_ID",
                                                      "project.yml:3 HERMES_BOT_USERNAME"])


class DeclaredApps(unittest.TestCase):
    def test_no_project_overrides_its_build_environment(self):
        listing = os.environ.get("SIDELOAD_APPS")
        if not listing:
            self.skipTest("SIDELOAD_APPS not set (checks/default.nix sets it)")
        apps = json.loads(Path(listing).read_text())
        self.assertIn("hermes", apps)
        for app_id, app in apps.items():
            source = Path(app["source"])
            if not source.is_dir():
                continue  # a git URL: fetched at build time
            with self.subTest(app=app_id):
                if app_id == "hermes":
                    self.assertIn("HERMES_TG_API_HASH", app["names"])
                self.assertEqual(overrides(source, set(app["names"])), [],
                                 "an assignment there wins over sideload's environment: leave it undefined")


if __name__ == "__main__":
    unittest.main(verbosity=1)
