"""guard's command titles (titles.py), with the Pi extension bash-titles' tests."""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from guard.titles import TitleCache, Titles, request, title_of, wants_title  # noqa: E402


def main() -> None:
    assert not wants_title("ls -la")
    assert not wants_title("git status && git diff")
    assert wants_title("cd a && make && make test && make install")
    assert wants_title("python3 -c 'print(1)'\necho done")
    assert wants_title("x" * 81)

    assert title_of("Lists the largest session files.") == "Lists the largest session files"
    assert title_of('"runs the unit tests"') == "Runs the unit tests"
    assert title_of("one two three four five six seven eight nine ten eleven twelve thirteen") == \
        "One two three four five six seven eight nine ten eleven twelve…"
    assert title_of("Lists files.\nThen sorts them.") == "Lists files"
    assert title_of("") is None

    sent = request("a" * 3000, 1000)
    assert len(sent) < 1100 and "…" in sent

    cache = TitleCache({}, 2)
    cache.set("one", "One"), cache.set("two", "Two"), cache.set("three", "Three")
    assert cache.get("one") is None and cache.get("three") == "Three"
    assert TitleCache(cache.to_json()).get("two") == "Two"

    # Asked once per command, kept on disk; a failure pauses asking.
    with tempfile.TemporaryDirectory() as d:
        file = Path(d) / "titles.json"
        asked = []
        now = [0.0]
        long = "cd a && make && make test && make install"
        t = Titles(file, ask=lambda c: asked.append(c) or "Builds and installs the project.", clock=lambda: now[0])
        assert t.title("ls") == "" and asked == []
        assert t.title(long) == "Builds and installs the project"
        assert t.title(long) == "Builds and installs the project" and len(asked) == 1
        assert Titles(file, ask=lambda c: 1 / 0).title(long) == "Builds and installs the project"

        def boom(c):
            raise RuntimeError("down")
        t = Titles(None, ask=boom, clock=lambda: now[0])
        assert t.title(long) == ""
        t.ask = lambda c: "Builds it"
        assert t.title(long) == ""  # paused
        now[0] = 61
        assert t.title(long) == "Builds it"
    print("ok titles")


if __name__ == "__main__":
    main()
