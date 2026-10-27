"""Assertions for run.sh, on what the model received and what unii logged."""

import json
import os
import sys

work = sys.argv[1]
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def text_of(content):
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


with open(os.path.join(work, "requests.jsonl")) as f:
    requests = [json.loads(line) for line in f if line.strip()]
# Agent turns carry tools; compactions and Hermes' title generation do not.
turns = [r for r in requests if r.get("tools") and "Compaction:" not in text_of(r["messages"][-1].get("content"))]
second = [r for r in turns if any("What number" in text_of(m.get("content")) for m in r["messages"])]

check(len(second) >= 2, "the second turn made a zoom call, then answered")
if second:
    first_request = second[0]["messages"]
    users = [m for m in first_request if m.get("role") == "user"]
    view = text_of(users[0].get("content")) if users else ""
    check(len(users) == 1, "the request holds one user message: nothing carried over but the view")
    check("<chat>" in view and "the number is 7" in view, "the view shows the first turn")
    check(any(t["function"]["name"] == "zoom" for t in second[0].get("tools", [])), "zoom is among the tools")
    final = second[-1]["messages"]
    check(any(m.get("role") == "tool" and "the number is 7" in text_of(m.get("content")) for m in final),
          "zoom(0, 1) returned the first message whole")

with open(os.path.join(work, "second.txt")) as f:
    check("The number is 7." in f.read(), "Hermes answered from its memory")

log = os.path.join(work, "hermes", "unii", "volumes", "main", "messages.jsonl")
with open(log) as f:
    kinds = [json.loads(line)["kind"] for line in f]
check(kinds[:2] == ["user", "hermes"] and "tool" in kinds and "echo" in kinds,
      f"the main volume logged both turns word for word ({kinds})")

if failures:
    with open(os.path.join(work, "stderr.log")) as f:
        print(f.read()[-4000:])
    sys.exit(1)
