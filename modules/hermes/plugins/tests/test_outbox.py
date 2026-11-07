"""The outbox plugin: a reply never claims to attach what the gateway drops.

Run from the plugins directory, as checks/default.nix does for every plugin's
tests. The gateway's validator is not imported here (``python3 -I`` in a test
sandbox has no gateway), so these exercise the same list the plugin keeps for
that case, plus the injected-validator path the gateway really takes.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import outbox  # noqa: E402


def write(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x")
    return path


def check(name: str, got, want) -> None:
    if got != want:
        raise AssertionError(f"{name}: got {got!r}, want {want!r}")
    print(f"ok  {name}")


def main() -> None:
    scratch = Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR") or None))
    home = Path(tempfile.mkdtemp(dir=scratch))
    os.environ["HOME"] = str(home)

    # Where the browser harness put every screenshot it took, and the reason
    # the user never received one.
    shot = write(home / ".config" / "browser-harness" / "tmp" / "p-1" / "shot.png")
    plain = write(scratch / "chart.png")
    secret = write(home / ".hermes" / "auth.json")
    credentials = write(home / ".ssh" / "id_ed25519")

    check("denied: ~/.config", outbox.deliverable(str(shot)), False)
    check("denied: ~/.ssh", outbox.deliverable(str(credentials)), False)
    check("denied: Hermes credentials", outbox.deliverable(str(secret)), False)
    check("denied: /etc", outbox.deliverable("/etc/hosts"), False)
    check("denied: missing file", outbox.deliverable(str(scratch / "nope.png")), False)
    check("denied: relative path", outbox.deliverable("chart.png"), False)
    check("delivered: a fresh file", outbox.deliverable(str(plain)), True)
    check("delivered: MEDIA: prefix", outbox.deliverable(f"MEDIA:{plain}"), True)

    # The reply the user never got an image from.
    lied = f"Voici le screenshot : MEDIA:{shot}"
    check("rewritten: MEDIA tag", outbox.rescue(lied),
          f"Voici le screenshot : {outbox._note('attachment', str(shot))}")
    check("rewritten: sentence punctuation", outbox.rescue(f"Voici MEDIA:{shot}."),
          f"Voici {outbox._note('attachment', str(shot))}")

    # The two forms the model tried after that, one of which Telegram showed as
    # a file called "!Capture d'écran…".
    check("rewritten: markdown image", outbox.rescue(f"![Capture d'écran]({shot})"),
          outbox._note("image", str(shot)))
    check("kept: markdown image in a deliverable place",
          outbox.rescue(f"![Chart]({plain})"), None)

    # An honest reply is left alone, and so is a good attachment.
    check("kept: no media at all", outbox.rescue("Bonjour, tout va bien."), None)
    check("kept: deliverable MEDIA tag", outbox.rescue(f"MEDIA:{plain}"), None)
    check("kept: empty reply", outbox.rescue(""), None)

    # The gateway's own verdict wins over the local list, both ways.
    seen: list[str] = []

    def always_ok(path: str) -> str:
        seen.append(path)
        return path

    def always_no(path: str) -> None:
        seen.append(path)
        return None

    check("gateway says ok", outbox.rescue(f"MEDIA:{shot}", validate=always_ok), None)
    check("gateway asked once", len(seen), 1)
    check("gateway says no", outbox.rescue(f"MEDIA:{plain}", validate=always_no),
          outbox._note("attachment", str(plain)))

    # A remote image is the gateway's to fetch, and a relative link is no
    # attachment at all: neither is judged.
    check("kept: remote markdown image",
          outbox.rescue("Voici : ![chat](https://upload.wikimedia.org/a/cat.png)"), None)
    check("kept: relative markdown image", outbox.rescue("![a](relative.png)"), None)
    check("kept: a plain link", outbox.rescue(f"[doc]({shot})"), None)

    # Code and quotes are examples to the gateway (_mask_protected_spans).
    check("kept: tag in inline code", outbox.rescue("Write it like `MEDIA:/path/to/file.png`."), None)
    check("kept: tag in a fenced block", outbox.rescue(f"```\nMEDIA:/etc/hosts\n![x]({shot})\n```"), None)
    check("kept: tag in a quote", outbox.rescue(f"> MEDIA:{shot}"), None)
    check("rewritten: outside the code, not inside",
          outbox.rescue(f"`MEDIA:/etc/hosts` then MEDIA:{shot}"),
          f"`MEDIA:/etc/hosts` then {outbox._note('attachment', str(shot))}")

    # A file that is not there, or a path that is not one, says so: copying
    # it elsewhere would not help.
    missing = scratch / "nope.png"
    check("rewritten: missing file", outbox.rescue(f"MEDIA:{missing}"),
          f"[attachment not sent: {missing} — no such file]")
    check("rewritten: missing markdown image", outbox.rescue(f"![x]({missing})"),
          f"[image not sent: {missing} — no such file]")
    check("rewritten: relative tag", outbox.rescue("MEDIA:chart.png"),
          "[attachment not sent: chart.png — not an absolute path]")
    check("verdict: missing", outbox.verdict(str(missing)), "missing")
    check("verdict: refused", outbox.verdict(str(shot)), "refused")
    check("verdict: deliverable", outbox.verdict(str(plain)), None)

    # A quoted path may hold spaces, as the gateway reads it.
    spaced = write(scratch / "Capture d'écran.png")
    check("kept: quoted path with spaces", outbox.rescue(f'MEDIA:"{spaced}"'), None)
    check("kept: backticked path", outbox.rescue(f"MEDIA: `{spaced}`"), None)

    # The operator allowlist (browser.nix) opens the harness' folder alone.
    os.environ["HERMES_MEDIA_ALLOW_DIRS"] = str(shot.parent.parent)
    check("allowed: the harness' screenshots", outbox.deliverable(str(shot)), True)
    check("still denied: the rest of ~/.config",
          outbox.deliverable(str(write(home / ".config" / "gh" / "hosts.yml"))), False)
    del os.environ["HERMES_MEDIA_ALLOW_DIRS"]

    print("outbox: all checks passed")


if __name__ == "__main__":
    main()
