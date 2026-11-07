"""Files past Telegram's limits, as `[fichier: <url>]` links (docs/app-protocol.md §7).

The app uploads what TDLib cannot send (> 2 GB) to gofile.io, or to
SwissTransfer with an Infomaniak token; Hermes fetches those links into
~/.hermes/files, and sends what the bot cannot (> 50 MB) the same way.

gofile.io: uploading is its official API (any account, guests included).
Reading a share page through the API is Premium-only; its own website reads
it with a guest token and a per-4-hours "website token", which is what
open-source downloaders do (ltsdw/gofile-downloader). That part is not an API
contract: when it breaks, the error says to open the link in Hermes' Chrome.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import time
from pathlib import Path
from urllib.parse import unquote, urlparse

MARK = re.compile(r"\[fichier:\s*(\S+?)\s*\]")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
# The salt in gofile.io's website code (dist/js/global.js), as ltsdw/gofile-downloader reads it.
GOFILE_SALT = os.environ.get("GOFILE_WEBSITE_SALT", "12af056dacea0b")
BOT_UPLOAD_LIMIT = 50 * 1024 * 1024
CHUNK = 1 << 20


class BigFileError(RuntimeError):
    pass


def links(text: str) -> list[str]:
    return MARK.findall(text or "")


def _client():
    import httpx

    return httpx.Client(follow_redirects=True, timeout=httpx.Timeout(30.0, read=300.0),
                        headers={"User-Agent": UA})


def _safe_name(name: str) -> str:
    name = Path(unquote(name or "")).name.strip() or "file"
    return re.sub(r"[^\w.\- ()\[\]]+", "_", name)[:200]


def _unique(directory: Path, name: str) -> Path:
    path = directory / name
    n = 1
    while path.exists():
        path = directory / f"{Path(name).stem} ({n}){Path(name).suffix}"
        n += 1
    return path


def _stream(client, url: str, directory: Path, name: str | None, headers=None, cookies=None) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    with client.stream("GET", url, headers=headers or {}, cookies=cookies) as response:
        if response.status_code >= 400:
            raise BigFileError(f"HTTP {response.status_code} for {url}")
        if not name:
            disposition = response.headers.get("content-disposition", "")
            match = re.search(r"filename\*?=(?:UTF-8'')?\"?([^\";]+)", disposition)
            name = match.group(1) if match else Path(urlparse(str(response.url)).path).name
        if (response.headers.get("content-type") or "").startswith("text/html"):
            raise BigFileError(f"{url} is a web page, not a file: open it in the browser")
        target = _unique(directory, _safe_name(name))
        part = target.with_name(target.name + ".part")
        with open(part, "wb") as f:
            for chunk in response.iter_bytes(CHUNK):
                f.write(chunk)
        os.replace(part, target)
        return target


# ── gofile.io ────────────────────────────────────────────────────────────

class Gofile:
    def __init__(self, state: Path):
        self.state = Path(state)

    def token(self, client) -> str:
        try:
            saved = json.loads(self.state.read_text())
            if saved.get("token"):
                return saved["token"]
        except (OSError, ValueError):
            pass
        body = client.post("https://api.gofile.io/accounts", json={},
                           headers=self._web_headers("")).json()
        if body.get("status") != "ok":
            raise BigFileError(f"gofile.io: no guest account ({body.get('status')})")
        data = body["data"]
        self.state.parent.mkdir(parents=True, exist_ok=True)
        self.state.write_text(json.dumps({"token": data["token"], "root": data.get("rootFolder")}))
        os.chmod(self.state, 0o600)
        return data["token"]

    @staticmethod
    def website_token(token: str, now: float | None = None) -> str:
        slot = int(now if now is not None else time.time()) // 14400
        return hashlib.sha256(f"{UA}::en-US::{token}::{slot}::{GOFILE_SALT}".encode()).hexdigest()

    def _web_headers(self, token: str) -> dict:
        return {"X-Website-Token": self.website_token(token), "X-BL": "en-US",
                "Origin": "https://gofile.io", "Referer": "https://gofile.io/"}

    def fetch(self, url: str, directory: Path) -> list[Path]:
        code = urlparse(url).path.rstrip("/").split("/")[-1]
        with _client() as client:
            token = self.token(client)
            headers = {"Authorization": f"Bearer {token}", **self._web_headers(token)}
            body = client.get(f"https://api.gofile.io/contents/{code}", params={"cache": "true"},
                              headers=headers).json()
            if body.get("status") != "ok":
                raise BigFileError(f"gofile.io refused the listing ({body.get('status')}): "
                                   "open the link in the browser and download it there")
            data = body["data"]
            files = [data] if data.get("type") == "file" else [c for c in (data.get("children") or {}).values()
                                                               if c.get("type") == "file"]
            out = []
            for item in files:
                out.append(_stream(client, item["link"], directory, item.get("name"),
                                   headers={"Authorization": f"Bearer {token}"},
                                   cookies={"accountToken": token}))
            return out

    def upload(self, path: Path) -> str:
        import httpx

        with httpx.Client(timeout=httpx.Timeout(60.0, write=None, read=600.0), headers={"User-Agent": UA}) as client:
            token = self.token(client)
            with open(path, "rb") as f:
                body = client.post("https://upload.gofile.io/uploadfile",
                                   headers={"Authorization": f"Bearer {token}"},
                                   files={"file": (path.name, f)}).json()
        if body.get("status") != "ok":
            raise BigFileError(f"gofile.io upload failed ({body.get('status')})")
        return body["data"]["downloadPage"]


# ── SwissTransfer ────────────────────────────────────────────────────────

def swisstransfer_fetch(url: str, directory: Path, token: str | None) -> list[Path]:
    """A SwissTransfer link: its container through the web app's API, then
    each file. Without a token, the public link API the website uses."""
    link = urlparse(url).path.rstrip("/").split("/")[-1]
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    with _client() as client:
        response = client.get(f"https://www.swisstransfer.com/api/links/{link}", headers=headers)
        if response.status_code >= 400:
            raise BigFileError(f"SwissTransfer: HTTP {response.status_code}: open the link in the browser")
        data = response.json().get("data") or response.json()
        container = data.get("container") or data
        host = data.get("downloadHost") or "www.swisstransfer.com"
        out = []
        for item in container.get("files") or []:
            file_url = f"https://{host}/api/download/{link}/{item['UUID']}"
            out.append(_stream(client, file_url, directory, item.get("fileName"), headers=headers))
        if not out:
            raise BigFileError("SwissTransfer: no file in that link")
        return out


def fetch(url: str, directory: Path, gofile: Gofile, swisstransfer_token: str | None = None) -> list[Path]:
    host = (urlparse(url).hostname or "").lower()
    if host.endswith("gofile.io") and "/d/" in url:
        return gofile.fetch(url, directory)
    if host.endswith("swisstransfer.com"):
        return swisstransfer_fetch(url, directory, swisstransfer_token)
    if urlparse(url).scheme not in ("http", "https"):
        raise BigFileError("only http(s) links")
    with _client() as client:
        return [_stream(client, url, directory, None)]
