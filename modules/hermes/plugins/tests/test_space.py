"""space: Hermes is told once, at its next turn, of a big folder about to freeze."""

from __future__ import annotations

import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import space  # noqa: E402

GB = 1024 ** 3


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="space-test-"))
    now = time.time()
    report = work / "report.json"
    report.write_text(json.dumps({"upcoming": {"groups": [
        {"path": "/Users/hermes/workspace/build", "bytes": 3 * GB, "files": 900, "freezes_at": now + 3600},
        {"path": "/Users/hermes/workspace/tiny", "bytes": 10, "files": 1, "freezes_at": now + 60},
        {"path": "/Users/hermes/workspace/later", "bytes": 9 * GB, "files": 2, "freezes_at": now + 20 * 3600},
    ]}}))
    space.STATE.update(config={"report": str(report), "home": "/Users/hermes", "notice_bytes": GB,
                               "notice_window": 3 * 3600}, noticed={}, file=work / "noticed.json")
    out = space.pre_llm_call(session_id="s", user_message="hi")
    text = out["context"]
    assert text.startswith("[Resources notice, from this Mac, not the user]"), text
    assert "~/workspace/build (3.0 GB, 900 files, freezing in 59 min)" in text or "freezing in 60 min" in text, text
    assert "tiny" not in text and "later" not in text
    assert json.loads((work / "noticed.json").read_text()) == {"/Users/hermes/workspace/build": now + 3600}
    # Once per freeze time.
    assert space.pre_llm_call(session_id="s", user_message="again") is None
    # No report: nothing.
    space.STATE["config"]["report"] = str(work / "missing.json")
    assert space.pre_llm_call() is None
    print("ok space")


if __name__ == "__main__":
    main()
