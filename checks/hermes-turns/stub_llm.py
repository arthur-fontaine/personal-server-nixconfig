"""A scripted OpenAI-compatible model for the end-to-end check.

It logs every request to $STUB_LOG and answers:
- a compaction ("Compaction:" task) with a short line;
- a turn asking "what number" with a zoom(0, 1) call, then, once the zoom
  result is in, with the number found in it;
- any other turn with "Noted.".

    python3 stub_llm.py <port> <log>
"""

import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[2]


def text_of(content):
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


def reply_for(body):
    messages = body.get("messages", [])
    last_user = next((text_of(m.get("content")) for m in reversed(messages) if m.get("role") == "user"), "")
    if "Compaction:" in last_user:
        return {"content": "user: a short summary line"}
    zoomed = [text_of(m.get("content")) for m in messages if m.get("role") == "tool"]
    if "what number" in last_user.lower():
        if not zoomed:
            return {"tool_calls": [{"id": "call_zoom", "type": "function",
                                    "function": {"name": "zoom", "arguments": json.dumps({"id": 0, "n": 1})}}]}
        found = re.search(r"number is (\d+)", " ".join(zoomed))
        return {"content": f"The number is {found.group(1) if found else 'unknown'}."}
    return {"content": "Noted."}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, data, status=200):
        raw = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._json({"object": "list", "data": [{"id": "stub-model", "object": "model", "owned_by": "stub"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        with open(LOG, "a") as f:
            f.write(json.dumps(body) + "\n")
        message = {"role": "assistant", **reply_for(body)}
        finish = "tool_calls" if "tool_calls" in message else "stop"
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        created = int(time.time())
        if not body.get("stream"):
            self._json({"id": "stub", "object": "chat.completion", "created": created, "model": "stub-model",
                        "choices": [{"index": 0, "message": message, "finish_reason": finish}], "usage": usage})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        delta = dict(message)
        if "tool_calls" in delta:
            delta["tool_calls"] = [{**c, "index": i} for i, c in enumerate(delta["tool_calls"])]
        for chunk in (
            {"choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": finish}], "usage": usage},
        ):
            chunk.update({"id": "stub", "object": "chat.completion.chunk", "created": created, "model": "stub-model"})
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
