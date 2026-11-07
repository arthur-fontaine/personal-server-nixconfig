"""The tinyfish plugin: web_search, web_fetch and view_image, with the Pi
extension web's tests (tests/tinyfish.test.ts), then the tools loaded through
Hermes' real plugin loader and dispatched through its registry, against a
stand-in for TinyFish (and an image server) on loopback.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PLUGINS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PLUGINS))

home = Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR") or None))
os.environ.update(HOME=str(home), HERMES_HOME=str(home / ".hermes"))

import tinyfish  # noqa: E402

PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 64
seen: list = []


class Fake(BaseHTTPRequestHandler):
    def _send(self, status: int, body: bytes, kind: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/img"):
            kind = "application/octet-stream" if "octet" in self.path else "image/svg+xml" if "svg" in self.path else "image/png"
            return self._send(200, b"<svg" if "svg" in self.path else PNG, kind)
        query = parse_qs(urlparse(self.path).query)
        seen.append({"key": self.headers.get("X-API-Key"), "query": query})
        if self.headers.get("X-API-Key") != "good-key":
            return self._send(401, b'{"error":"invalid api key"}')
        results = [{"position": 1, "site_name": "zed.dev", "title": "Zed", "snippet": "An editor", "url": "https://zed.dev"}]
        self._send(200, json.dumps({"results": results}).encode())

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append({"key": self.headers.get("X-API-Key"), "body": body})
        page = {"url": body["urls"][0], "title": "A", "text": "x" * 50_000, "image_links": ["https://a.dev/1.png"],
                "links": ["https://a.dev/b"]}
        self._send(200, json.dumps({"results": [page], "errors": [{"url": "https://b.dev", "message": "timeout"}]}).encode())

    def log_message(self, *args):
        pass


def check(name: str, ok: bool) -> None:
    assert ok, name
    print("ok ", name)


def pure() -> None:
    url = urlparse(tinyfish.search_url({"query": "zed git panel", "include_domains": ["zed.dev", "github.com"], "page": 0}))
    q = parse_qs(url.query)
    check("searchUrl: only the given parameters, domains comma-joined",
          f"{url.scheme}://{url.netloc}" == "https://api.search.tinyfish.ai" and q["query"] == ["zed git panel"]
          and q["include_domains"] == ["zed.dev,github.com"] and q["page"] == ["0"] and "purpose" not in q)
    text = tinyfish.format_search("q", [{"position": 1, "title": "Zed", "url": "https://zed.dev", "site_name": "zed.dev", "snippet": "An editor"}])
    check("formatSearch lists results", text == "1. Zed\n   https://zed.dev\n   zed.dev\n   An editor")
    check("formatSearch says when there are none", tinyfish.format_search("q", []) == 'No results for "q".')
    text = tinyfish.format_fetch([{"url": "https://a.dev", "title": "A", "text": "x" * 50, "image_links": ["https://a.dev/1.png"]}],
                                 [{"url": "https://b.dev", "message": "timeout"}], 10)
    check("formatFetch cuts long pages, lists images and failures",
          "[… cut at 10 of 50 characters]" in text and "## Images (1)\nhttps://a.dev/1.png" in text
          and "# Could not fetch https://b.dev\ntimeout" in text)
    webp = bytearray(12)
    webp[8:12] = b"WEBP"
    check("imageType trusts a readable declared type, else the signature",
          tinyfish.image_type("image/png; charset=binary", b"") == "image/png"
          and tinyfish.image_type("application/octet-stream", b"\xff\xd8\xff\xe0") == "image/jpeg"
          and tinyfish.image_type(None, bytes(webp)) == "image/webp"
          and tinyfish.image_type("image/svg+xml", b"<svg") is None)
    check("apiError explains the statuses worth acting on",
          "TINYFISH_API_KEY" in tinyfish.api_error(401, "") and "500: boom" in tinyfish.api_error(500, "boom"))


def through_hermes(port: int) -> None:
    hermes_home = home / ".hermes"
    shutil.copytree(PLUGINS / "tinyfish", hermes_home / "plugins" / "tinyfish")
    (hermes_home / "config.yaml").write_text(json.dumps({"plugins": {
        "enabled": ["tinyfish"], "entries": {"tinyfish": {"allow_tool_override": True}}}}))
    from hermes_cli.plugins import discover_plugins, get_plugin_manager
    from tools.registry import registry

    discover_plugins(force=True)
    check("loaded by Hermes' plugin loader", "tinyfish" in get_plugin_manager()._plugins)
    mod = sys.modules[get_plugin_manager()._plugins["tinyfish"].module.__name__] \
        if hasattr(get_plugin_manager()._plugins["tinyfish"], "module") else tinyfish
    for m in {mod, tinyfish}:
        m.SEARCH_URL = f"http://127.0.0.1:{port}/"
        m.FETCH_URL = f"http://127.0.0.1:{port}/fetch"
        m._native_images = lambda: True
    entry = registry.get_entry("web_search")
    check("web_search is TinyFish's, with its parameters", "include_domains" in json.dumps(entry.schema))

    def call(name, args):
        return registry.dispatch(name, args)

    os.environ.pop("TINYFISH_API_KEY", None)
    check("no key: a clear error", "No TinyFish API key" in call("web_search", {"query": "x"}))
    os.environ["TINYFISH_API_KEY"] = "bad"
    check("bad key: TinyFish's status explained", "TinyFish answered 401" in call("web_search", {"query": "x"}))
    os.environ["TINYFISH_API_KEY"] = "good-key"
    out = call("web_search", {"query": "zed", "include_domains": ["zed.dev"]})
    check("search: results, the key and filters sent",
          out.startswith("1. Zed") and seen[-1]["key"] == "good-key" and seen[-1]["query"]["include_domains"] == ["zed.dev"])
    out = call("web_fetch", {"urls": ["https://a.dev"], "images": True, "links": True})
    check("fetch: Markdown cut at 40k, images, links, failures",
          "[… cut at 40000 of 50000 characters]" in out and "## Images (1)" in out and "## Links of https://a.dev" in out
          and "# Could not fetch https://b.dev" in out and seen[-1]["body"]["format"] == "markdown")
    out = call("view_image", {"url": f"http://127.0.0.1:{port}/img.png"})
    check("view_image: the image, to the model", isinstance(out, dict) and out["content"][1]["image_url"]["url"].startswith("data:image/png;base64,"))
    out = call("view_image", {"url": f"http://127.0.0.1:{port}/img-octet"})
    check("view_image: a PNG served as octet-stream", isinstance(out, dict))
    check("view_image: SVG refused", "Not an image the model can read" in call("view_image", {"url": f"http://127.0.0.1:{port}/img-svg"}))
    for m in {mod, tinyfish}:
        m._native_images = lambda: False
    out = call("view_image", {"url": f"http://127.0.0.1:{port}/img.png"})
    check("view_image: saved for vision_analyze when the route takes no images", "vision_analyze" in out)


def main() -> None:
    httpd = HTTPServer(("127.0.0.1", 0), Fake)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        pure()
        through_hermes(httpd.server_address[1])
    finally:
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
