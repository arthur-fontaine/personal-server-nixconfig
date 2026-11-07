"""The tinyfish plugin: Hermes' own web_search tool answered by TinyFish Search.

A stand-in for api.search.tinyfish.ai on loopback; Hermes' config selects the
backend (web.search_backend: tinyfish, as agent/tools.nix writes it), and the
search goes through tools.web_tools.web_search_tool, as the model's call does.
Run from the plugins directory, as checks/default.nix does.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

home = Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR") or None))
os.environ["HERMES_HOME"] = str(home)
(home / "config.yaml").write_text(
    "web:\n  search_backend: tinyfish\n  keyless_fallback: false\n  keyless_rescue: false\n  cache_enabled: false\n"
)

import tinyfish  # noqa: E402

seen: list[dict] = []


class Fake(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        query = parse_qs(urlparse(self.path).query)
        seen.append({"key": self.headers.get("X-API-Key"), "query": query})
        if self.headers.get("X-API-Key") != "good-key":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"error":"invalid api key"}')
            return
        body = {
            "query": query["query"][0],
            "results": [
                {"position": i + 1, "site_name": "example.org", "title": f"Result {i + 1}",
                 "snippet": f"Snippet {i + 1}", "url": f"https://example.org/{i + 1}"}
                for i in range(10)
            ],
            "total_results": 10, "page": 0,
        }
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def check(name: str, got, want) -> None:
    if got != want:
        raise AssertionError(f"{name}: got {got!r}, want {want!r}")
    print(f"ok  {name}")


def main() -> None:
    server = HTTPServer(("127.0.0.1", 0), Fake)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    tinyfish.ENDPOINT = f"http://127.0.0.1:{server.server_port}/"

    from agent import web_search_registry
    from tools.web_tools import web_search_tool

    web_search_registry.register_provider(tinyfish.make_provider())

    os.environ.pop("TINYFISH_API_KEY", None)
    out = json.loads(web_search_tool("no key"))
    check("no key: a clear error", (out["success"], "TINYFISH_API_KEY" in out.get("error", "")), (False, True))
    check("no key: no request", seen, [])

    os.environ["TINYFISH_API_KEY"] = "good-key"
    out = json.loads(web_search_tool("hermes agent", limit=3))
    check("search: succeeds", out["success"], True)
    check("search: the query and key reach TinyFish", (seen[-1]["query"]["query"], seen[-1]["key"]),
          (["hermes agent"], "good-key"))
    web = out["data"]["web"]
    check("search: limited to what was asked", len(web), 3)
    check("search: Hermes' row shape", web[0],
          {"title": "Result 1", "url": "https://example.org/1", "description": "Snippet 1", "position": 1})

    os.environ["TINYFISH_API_KEY"] = "revoked"
    out = json.loads(web_search_tool("bad key"))
    check("bad key: fails with TinyFish's status", (out["success"], "401" in out.get("error", "")), (False, True))

    server.shutdown()


if __name__ == "__main__":
    main()
