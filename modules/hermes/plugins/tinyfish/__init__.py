"""tinyfish: web_search, web_fetch and view_image through TinyFish, ported
from Arthur's Pi extension web (nixconfig, modules/home/programs/pi/
extensions/web: tinyfish.ts, index.ts), with its formatting, limits and
messages.

- web_search: TinySearch (https://api.search.tinyfish.ai), ranked results
  with title, URL, snippet, date; domain filters, freshness, news or papers,
  language, page. It replaces Hermes' own web_search (``override``, granted
  by agent/tools.nix with ``plugins.entries.tinyfish.allow_tool_override``),
  whose backends take only a query.
- web_fetch: up to 10 pages as Markdown through TinyFish's Fetch API, with
  each page's image URLs and links on request; a page is cut at 40,000
  characters, and the model is told so.
- view_image: an image from a URL, returned to the model as an image (PNG,
  JPEG, GIF, WebP; over 3.5 MB through macOS's sips, a JPEG at most 1568 px
  wide). On a route that cannot take images in a tool result, the image is
  saved and its path given, for vision_analyze.

The key is TINYFISH_API_KEY, from the secrets file (/etc/hermes/secrets.env).
"""

from __future__ import annotations

import base64
import json
import logging
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlencode

logger = logging.getLogger(__name__)

SEARCH_URL = "https://api.search.tinyfish.ai"
FETCH_URL = "https://api.fetch.tinyfish.ai"
KEY_ENV = "TINYFISH_API_KEY"
TIMEOUT = 60.0
# Over this the image is shrunk before the model sees it (its limit is 5 MB,
# and it scales anything past ~1568 px down anyway).
MAX_IMAGE_BYTES = 3_500_000
MAX_DOWNLOAD_BYTES = 30_000_000
MAX_PAGE_CHARS = 40_000
MAX_IMAGES = 60
MAX_LINKS = 200


def search_url(p: dict) -> str:
    """Only the given parameters, domains comma-joined."""
    params = {}
    for key in ("query", "purpose", "location", "language", "include_domains", "exclude_domains",
                "recency_minutes", "domain_type", "page"):
        value = p.get(key)
        if isinstance(value, list):
            value = ",".join(str(v) for v in value)
        if value is not None and value != "":
            params[key] = str(value)
    return f"{SEARCH_URL}?{urlencode(params)}"


def format_search(query: str, results: list) -> str:
    if not results:
        return f'No results for "{query}".'
    out = []
    for r in results:
        meta = " · ".join(str(x) for x in (r.get("site_name"), r.get("publisher"), r.get("date")) if x)
        parts = [f"{r.get('position')}. {r.get('title')}", r.get("url"), meta, r.get("snippet")]
        out.append("\n   ".join(str(x) for x in parts if x))
    return "\n\n".join(out)


def format_fetch(results: list, errors: list, max_chars: int = MAX_PAGE_CHARS) -> str:
    """Pages can be long: the model gets the start, and is told where it was cut."""
    parts = []
    for r in results:
        where = r.get("final_url") or r.get("url")
        head = "\n".join(x for x in (f"# {r.get('title') or where}", where, r.get("published_date") or "",
                                     r.get("description") or "") if x)
        text = r.get("text") or ""
        if len(text) > max_chars:
            text = f"{text[:max_chars]}\n\n[… cut at {max_chars} of {len(text)} characters]"
        links = r.get("image_links") or []
        images = ""
        if links:
            more = f"\n[… {len(links) - MAX_IMAGES} more]" if len(links) > MAX_IMAGES else ""
            images = f"\n\n## Images ({len(links)})\n" + "\n".join(links[:MAX_IMAGES]) + more
        parts.append(f"{head}\n\n{text}{images}")
    for e in errors:
        parts.append(f"# Could not fetch {e.get('url')}\n{e.get('message') or e.get('error') or e.get('code') or 'unknown error'}")
    return "\n\n---\n\n".join(parts)


IMAGE_TYPES = {"image/png", "image/jpeg", "image/gif", "image/webp"}


def image_type(content_type: Optional[str], data: bytes) -> Optional[str]:
    """A readable declared type, else the file's own signature (servers often say octet-stream)."""
    declared = (content_type or "").split(";")[0].strip().lower()
    if declared in IMAGE_TYPES:
        return declared
    if data[:4] == b"\x89PNG":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:3] == b"GIF":
        return "image/gif"
    if data[8:12] == b"WEBP":
        return "image/webp"
    return None


def api_error(status: int, body: str) -> str:
    why = {
        401: f"the TinyFish API key is missing or invalid ({KEY_ENV} in the secrets file)",
        402: "TinyFish's free daily allowance is used up",
        429: "TinyFish's rate limit was hit; wait a minute",
    }
    return f"TinyFish answered {status}: {why.get(status, body[:300])}"


def _key() -> str:
    key = os.environ.get(KEY_ENV, "").strip()
    if not key:
        raise RuntimeError(f"No TinyFish API key: {KEY_ENV} is not in the secrets file "
                           "(the bootstrap's TinyFish step; https://agent.tinyfish.ai/api-keys)")
    return key


def _error(message: str) -> str:
    return json.dumps({"error": message}, ensure_ascii=False)


def web_search(args: dict, **_: Any) -> str:
    import httpx

    query = str((args or {}).get("query") or "").strip()
    if not query:
        return _error("query is required")
    try:
        res = httpx.get(search_url({**args, "query": query}), headers={"X-API-Key": _key()}, timeout=TIMEOUT)
    except (RuntimeError, httpx.HTTPError) as error:
        return _error(str(error))
    if res.status_code != 200:
        return _error(api_error(res.status_code, res.text))
    return format_search(query, (res.json() or {}).get("results") or [])


def web_fetch(args: dict, **_: Any) -> str:
    import httpx

    urls = [str(u) for u in (args or {}).get("urls") or [] if u][:10]
    if not urls:
        return _error("urls is required (1 to 10)")
    body = {"urls": urls, "format": "markdown", "purpose": args.get("purpose"),
            "image_links": bool(args.get("images")), "links": bool(args.get("links"))}
    try:
        res = httpx.post(FETCH_URL, json=body, headers={"X-API-Key": _key()}, timeout=TIMEOUT)
    except (RuntimeError, httpx.HTTPError) as error:
        return _error(str(error))
    if res.status_code != 200:
        return _error(api_error(res.status_code, res.text))
    data = res.json() or {}
    results = data.get("results") or []
    text = format_fetch(results, data.get("errors") or [])
    if args.get("links"):
        for r in results:
            if r.get("links"):
                text += f"\n\n## Links of {r.get('url')}\n" + "\n".join(r["links"][:MAX_LINKS])
    return text


def shrink(data: bytes) -> bytes:
    """Too big for the model: macOS's sips turns it into a JPEG at most 1568 px wide."""
    with tempfile.TemporaryDirectory(prefix="hermes-view-image-") as d:
        src, out = Path(d) / "in", Path(d) / "out.jpg"
        src.write_bytes(data)
        subprocess.run(["/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", "80", "-Z", "1568",
                        str(src), "--out", str(out)], check=True, capture_output=True, timeout=60)
        return out.read_bytes()


def _native_images() -> bool:
    try:
        from tools.vision_tools import _should_use_native_vision_fast_path

        return bool(_should_use_native_vision_fast_path())
    except Exception:  # noqa: BLE001 - outside Hermes, or its gate moved
        return False


def _saved(data: bytes, mime: str) -> str:
    try:
        from hermes_constants import get_hermes_home

        folder = Path(get_hermes_home()) / "cache" / "view_image"
    except Exception:  # noqa: BLE001
        folder = Path(tempfile.gettempdir()) / "hermes-view-image"
    folder.mkdir(parents=True, exist_ok=True)
    fd, path = tempfile.mkstemp(dir=folder, suffix="." + mime.split("/")[1])
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    return path


def view_image(args: dict, **_: Any):
    import httpx

    url = str((args or {}).get("url") or "")
    if not url.startswith(("http://", "https://")):
        return _error("url must be an http(s) URL")
    try:
        with httpx.stream("GET", url, follow_redirects=True, timeout=TIMEOUT,
                          headers={"User-Agent": "Mozilla/5.0 (Macintosh) Hermes", "Accept": "image/*"}) as res:
            if res.status_code != 200:
                return _error(f"The image answered {res.status_code} {res.reason_phrase}")
            length = int(res.headers.get("content-length") or 0)
            if length > MAX_DOWNLOAD_BYTES:
                return _error(f"The image is {round(length / 1e6)} MB, too big to download")
            chunks, size = [], 0
            for chunk in res.iter_bytes():
                size += len(chunk)
                if size > MAX_DOWNLOAD_BYTES:
                    return _error("The image is over 30 MB, too big to download")
                chunks.append(chunk)
            content_type = res.headers.get("content-type")
    except httpx.HTTPError as error:
        return _error(f"Could not download the image ({type(error).__name__})")
    data = b"".join(chunks)
    mime = image_type(content_type, data)
    if not mime:
        return _error(f"Not an image the model can read ({content_type or 'no type'}); PNG, JPEG, GIF and WebP work")
    if len(data) > MAX_IMAGE_BYTES:
        try:
            data, mime = shrink(data), "image/jpeg"
        except (OSError, subprocess.SubprocessError) as error:
            return _error(f"The image is too big and could not be shrunk ({error})")
    text = f"{url} ({mime}, {round(len(data) / 1024)} KB)"
    if not _native_images():
        path = _saved(data, mime)
        return f"{text}\nThis model cannot see images in a tool result: saved as {path}; look at it with vision_analyze."
    data_url = f"data:{mime};base64,{base64.b64encode(data).decode()}"
    return {"_multimodal": True, "text_summary": text,
            "content": [{"type": "text", "text": text}, {"type": "image_url", "image_url": {"url": data_url}}]}


WEB_SEARCH = {
    "name": "web_search",
    "description": ("Search the live web (TinyFish). Returns ranked results with title, URL and snippet. "
                    "Use web_fetch to read a result, and view_image to look at an image."),
    "parameters": {"type": "object", "required": ["query"], "properties": {
        "query": {"type": "string", "description": "The search query"},
        "purpose": {"type": "string", "description": "Why you are searching, in a sentence; improves results"},
        "include_domains": {"type": "array", "items": {"type": "string"}, "description": "Only these domains, e.g. github.com"},
        "exclude_domains": {"type": "array", "items": {"type": "string"}, "description": "Never these domains"},
        "recency_minutes": {"type": "integer", "minimum": 1, "description": "Only results from the last N minutes"},
        "domain_type": {"type": "string", "enum": ["web", "news", "research_paper"]},
        "language": {"type": "string", "description": "Result language code, e.g. en, fr"},
        "page": {"type": "integer", "minimum": 0, "maximum": 10, "description": "Results page, from 0"},
    }},
}
WEB_FETCH = {
    "name": "web_fetch",
    "description": ("Read web pages as clean Markdown (TinyFish), up to 10 URLs at once. "
                    "Set images to also list the page's image URLs, to open with view_image."),
    "parameters": {"type": "object", "required": ["urls"], "properties": {
        "urls": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 10, "description": "http(s) URLs"},
        "purpose": {"type": "string", "description": "Why you are reading these pages, in a sentence"},
        "images": {"type": "boolean", "description": "Also list the <img> URLs of each page"},
        "links": {"type": "boolean", "description": "Also list the links of each page"},
    }},
}
VIEW_IMAGE = {
    "name": "view_image",
    "description": "Download an image from a URL (PNG, JPEG, GIF or WebP) and look at it.",
    "parameters": {"type": "object", "required": ["url"], "properties": {
        "url": {"type": "string", "description": "The image's http(s) URL"},
    }},
}


def register(ctx) -> None:
    ctx.register_tool(name="web_search", toolset="web", schema=WEB_SEARCH, handler=web_search, emoji="🔎",
                      override=True)
    ctx.register_tool(name="web_fetch", toolset="web", schema=WEB_FETCH, handler=web_fetch, emoji="🌐")
    ctx.register_tool(name="view_image", toolset="web", schema=VIEW_IMAGE, handler=view_image, emoji="🖼️")
