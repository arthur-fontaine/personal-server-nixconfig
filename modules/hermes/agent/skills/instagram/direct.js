/* direct.js — read and write Instagram DMs through the page's own app.
 *
 * Loaded into instagram.com as a document-start script:
 *
 *   SCRIPT = open('<skill dir>/direct.js').read()
 *   cdp('Page.addScriptToEvaluateOnNewDocument', source=SCRIPT)
 *   goto_url('https://www.instagram.com/direct/inbox/')
 *   wait_for_load()
 *   print(js('__ig.inbox()'))
 *
 * It answers from the app's own traffic: Instagram renames and re-signs its
 * DM endpoints between releases, so instead of calling them this hooks fetch
 * and XMLHttpRequest and walks every JSON body for thread objects. Nothing is
 * reimplemented and nothing is signed here — the page does the talking, as it
 * does for the user, which is also why this is not an unofficial client.
 *
 * Everything is a read except ig.send(): opening a thread marks it seen, and
 * the user then gets no notification on their phone.
 */
(() => {
  "use strict";
  if (typeof globalThis === "undefined") return "no globalThis";

  const VERSION = 3;
  const ig = (globalThis.__ig = globalThis.__ig || {});
  if (ig.version === VERSION) return "already installed";
  ig.version = VERSION;

  // ── the page's own DM traffic ─────────────────────────────────────────────
  const INTERESTING = /direct|inbox|thread|graphql/i;
  const MAX_RESPONSES = 40;
  const responses = [];

  // Who the user is, out of whatever the app says about itself: `viewer_id`
  // on an inbox payload, `viewer.pk` on a thread's. Without it an item's
  // sender stays unknown rather than guessed.
  let viewer = null;
  const noteViewer = (node, depth) => {
    if (viewer || !node || typeof node !== "object" || depth > 12) return;
    if (!Array.isArray(node)) {
      const id = node.viewer_id != null
        ? node.viewer_id
        : node.viewer && typeof node.viewer === "object"
          ? node.viewer.pk ?? node.viewer.pk_id ?? node.viewer.id
          : null;
      if (id != null) {
        viewer = String(id);
        return;
      }
    }
    for (const value of Array.isArray(node) ? node : Object.values(node)) noteViewer(value, depth + 1);
  };

  const keep = (url, body) => {
    if (!body || typeof body !== "object") return;
    try {
      if (JSON.stringify(body).length > 4e6) return; // a media payload, not a thread
    } catch (e) {
      return;
    }
    responses.push({ url: String(url), at: Date.now(), body });
    if (responses.length > MAX_RESPONSES) responses.shift();
    noteViewer(body, 0);
  };

  const hookFetch = () => {
    const original = globalThis.fetch;
    if (typeof original !== "function" || original.__ig) return;
    const wrapped = function (input, init) {
      const pending = original.call(this, input, init);
      try {
        const url = String((input && input.url) || input);
        if (INTERESTING.test(url)) {
          pending
            .then((r) => r.clone().json().then((j) => keep(url, j)).catch(() => {}))
            .catch(() => {});
        }
      } catch (e) {}
      return pending;
    };
    wrapped.__ig = true;
    globalThis.fetch = wrapped;
  };

  const hookXHR = () => {
    const X = globalThis.XMLHttpRequest;
    if (typeof X !== "function" || X.prototype.__ig) return;
    const { open, send } = X.prototype;
    X.prototype.open = function (method, url, ...rest) {
      this.__igUrl = String(url);
      return open.call(this, method, url, ...rest);
    };
    X.prototype.send = function (...args) {
      this.addEventListener("load", () => {
        try {
          const url = this.__igUrl || "";
          if (INTERESTING.test(url)) keep(url, JSON.parse(this.responseText));
        } catch (e) {}
      });
      return send.apply(this, args);
    };
    X.prototype.__ig = true;
  };

  // ── threads, out of whatever the app fetched ──────────────────────────────
  // A thread's numeric `id` is what /direct/t/<id>/ takes; `thread_id` is the
  // 128-bit form the same payload carries. Either alone identifies one.
  const NUMERIC = /^\d{6,}$/;
  const idOf = (o) => {
    if (o.id != null && NUMERIC.test(String(o.id))) return String(o.id);
    if (o.thread_id != null && NUMERIC.test(String(o.thread_id))) return String(o.thread_id);
    if (o.threadId != null && NUMERIC.test(String(o.threadId))) return String(o.threadId);
    return null;
  };
  const v2Of = (o) =>
    o.thread_id != null && String(o.thread_id) !== idOf(o) ? String(o.thread_id) : null;

  // Every object in these payloads carries a numeric id — users, media, posts
  // — so a thread is one that also names itself a thread, and then its id is
  // the numeric one /direct/t/<id>/ takes.
  const isThread = (o) =>
    o.thread_id != null || o.threadId != null || o.thread_v2_id != null ||
    o.thread_subtype != null || o.thread_key != null || o.slide_messages != null;

  const looksLikeThread = (o) =>
    Boolean(o) && typeof o === "object" && !Array.isArray(o) && isThread(o) && idOf(o) !== null;

  const walk = (node, out, depth) => {
    if (!node || typeof node !== "object" || depth > 14 || out.length > 200) return;
    if (looksLikeThread(node)) {
      out.push(node);
      return;
    }
    const values = Array.isArray(node) ? node : Object.values(node);
    for (const value of values) walk(value, out, depth + 1);
  };

  const usernames = (t) => {
    const list = Array.isArray(t.users) ? t.users : Object.values(t.users || {});
    return list.map((u) => u && (u.username || u.full_name)).filter(Boolean);
  };

  const nameOf = (t) => {
    const title = t.thread_title || t.title;
    if (title && String(title).trim()) return String(title).trim();
    return usernames(t).join(", ");
  };

  // The inbox payload previews each thread in `slide_messages` (edges[].node:
  // igd_snippet, text_body); a thread opened on its own carries `items`.
  const previewOf = (t) => {
    const edges = (t.slide_messages && t.slide_messages.edges) || [];
    for (const edge of edges) {
      const node = (edge && edge.node) || {};
      const text = node.igd_snippet || node.text_body || node.text;
      if (text) return String(text);
    }
    const items = [t.items, t.messages].find((v) => Array.isArray(v) && v.length) || [];
    const item = items[0] || t.last_permanent_item || {};
    return String(item.igd_snippet || item.text || item.title || "");
  };

  // Milliseconds since the epoch, whatever unit the payload used.
  const atOf = (t) => {
    const ms = Number(t.last_activity_timestamp_ms || t.last_activity_at_ms || 0);
    if (ms > 0) return ms;
    const items = [t.items, t.messages].find((v) => Array.isArray(v) && v.length) || [];
    const raw = Number(((items[0] || t.last_permanent_item || {}).timestamp) || 0);
    if (!raw) return null;
    return raw > 1e14 ? Math.round(raw / 1000) : raw; // microseconds, else ms
  };

  const fromTraffic = () => {
    const found = [];
    for (const { body } of responses) walk(body, found, 0);
    const byId = new Map();
    for (const t of found) {
      const id = idOf(t);
      const entry = {
        id,
        v2: v2Of(t),
        name: nameOf(t),
        users: usernames(t),
        // The notification worker names a thread's sender only when it is one
        // person: a group has the title, not who in it wrote.
        group: Boolean(t.is_group || t.thread_subtype === "IGD_GROUP" || usernames(t).length > 1),
        text: previewOf(t).replace(/\s+/g, " ").slice(0, 300),
        at: atOf(t),
        unread: Boolean(t.marked_as_unread || t.read_state === 0 || t.has_newer),
      };
      const seen = byId.get(id);
      // A later body is fresher; a missing field keeps what an earlier one had.
      byId.set(id, seen ? { ...seen, ...entry, name: entry.name || seen.name, text: entry.text || seen.text } : entry);
    }
    return [...byId.values()];
  };

  const document_ = () => globalThis.document || null;
  // The page renders from its own state: what it shows a moment later is the
  // answer, not what the DOM says the instant a key is dispatched.
  const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // The inbox renders its rows as [role="button"] with the whole row as text
  // ("Camille 2 nouveaux messages · 17m Non lu"); they carry no thread id, so
  // they are what to read when the traffic is empty or to confirm it.
  const rows = (limit) => {
    const doc = document_();
    if (!doc || typeof doc.querySelectorAll !== "function") return [];
    return [...doc.querySelectorAll('[role="button"]')]
      .map((el) => String((el.innerText || "").replace(/\s+/g, " ").trim()))
      .filter((text) => text.length > 1 && text.length < 300)
      .slice(0, limit || 40);
  };

  const visible = () => {
    const doc = document_();
    if (!doc || typeof doc.querySelector !== "function") return "";
    const main = doc.querySelector('[role="main"]') || doc.body;
    return String((main && (main.innerText || main.textContent)) || "").replace(/\n{3,}/g, "\n\n");
  };

  // ── what a thread shows, and how to answer in it ──────────────────────────
  const composer = () => {
    const doc = document_();
    if (!doc) return null;
    const selectors = [
      'div[role="textbox"][contenteditable="true"]',
      'textarea[placeholder*="essage"]',
      'textarea[aria-label*="essage"]',
      'div[contenteditable="true"]',
    ];
    for (const selector of selectors) {
      const found = doc.querySelector(selector);
      if (found) return found;
    }
    return null;
  };

  // The composer's icons are emoji, voice clip, photo and GIF; "Send" replaces
  // them once there is text to send, and it is the svg's label, not the
  // button's. So look for the label, and click its clickable ancestor.
  const SEND = /^(send|send message|envoyer|envoyer le message)$/i;
  const sendButton = () => {
    const doc = document_();
    if (!doc || typeof doc.querySelectorAll !== "function") return null;
    const labelled = [...doc.querySelectorAll('[aria-label], [title]')].find((el) => {
      const label = (el.getAttribute("aria-label") || el.getAttribute("title") || "").trim();
      return SEND.test(label);
    });
    if (!labelled) return null;
    return labelled.closest('[role="button"], button, [role="link"]') || labelled;
  };

  // What is still typed in the box, and where the button is on screen.
  const draft = (box) => String(box.value ?? box.textContent ?? "").trim();
  const pointOf = (el) => {
    const rect = el && typeof el.getBoundingClientRect === "function" ? el.getBoundingClientRect() : null;
    if (!rect || (!rect.width && !rect.height)) return null;
    return { x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2) };
  };

  // Where to click, for a caller that can send a real pointer (SKILL.md,
  // "sending"): the app's own handler ignores a scripted click.
  ig.sendPoint = () => {
    const button = sendButton();
    if (!button) return { found: false, reason: "no Send button on this page: the text is not typed yet" };
    const point = pointOf(button);
    if (!point) return { found: false, reason: "the Send button has no box on screen" };
    return { found: true, ...point };
  };

  const insert = (box, text) => {
    if (box.tagName === "TEXTAREA") {
      const setter = Object.getOwnPropertyDescriptor(globalThis.HTMLTextAreaElement.prototype, "value")?.set;
      setter?.call(box, text);
      box.dispatchEvent(new Event("input", { bubbles: true }));
      return;
    }
    box.focus();
    const doc = document_();
    // execCommand drives React's onChange; textContent does not.
    if (doc && doc.execCommand) {
      doc.execCommand("insertText", false, text);
      if (String(box.textContent || "").includes(text)) return;
    }
    box.textContent = text;
    box.dispatchEvent(new Event("input", { bubbles: true }));
  };

  // ── the surface the skill calls ───────────────────────────────────────────
  ig.responses = () => responses.map(({ url, at }) => ({ url, at }));

  // Key paths of the first captured body: what to read when a release renames
  // something and the thread walk finds nothing (SKILL.md, "when it is empty").
  const shape = (node, prefix, out, depth) => {
    if (!node || typeof node !== "object" || depth > 3 || out.length > 60) return out;
    for (const [key, value] of Object.entries(node)) {
      const path = prefix ? `${prefix}.${key}` : key;
      out.push(Array.isArray(value) ? `${path}[]` : path);
      if (Array.isArray(value)) {
        if (value.length && typeof value[0] === "object") shape(value[0], `${path}[0]`, out, depth + 1);
      } else if (value && typeof value === "object") {
        shape(value, path, out, depth + 1);
      }
    }
    return out;
  };

  ig.diag = () => ({
    url: String(globalThis.location?.href || ""),
    title: String(document_()?.title || ""),
    fromTraffic: fromTraffic().length,
    rows: rows(400).length,
    responses: ig.responses(),
    shape: responses.length ? shape(responses[0].body, "", [], 0) : [],
    composer: Boolean(composer()),
    sendButton: Boolean(sendButton()),
  });

  ig.inbox = () => {
    const threads = fromTraffic().sort((a, b) => (b.at || 0) - (a.at || 0));
    const pageRows = rows();
    return {
      count: threads.length,
      unread: (String(document_()?.title || "").match(/\((\d+)\)/) || [])[1] || "0",
      threads: threads.slice(0, 60),
      // Row texts, for when the traffic came back empty or to confirm names.
      rows: pageRows.slice(0, 25),
      page: threads.length === 0 ? visible().slice(0, 600) : undefined,
    };
  };

  // The open thread's messages, each with the sender the payload names: read
  // in order, a transcript cannot tell the user's own line from the others'.
  const itemText = (item) => {
    if (item.text) return String(item.text);
    const kind = item.item_type || "";
    if (kind === "link") return String((item.link || {}).text || "[link]");
    if (kind === "reel_share") return `[replied to a story] ${(item.reel_share || {}).text || ""}`.trim();
    if (kind === "action_log") return String((item.action_log || {}).description || "");
    return {
      voice_media: "[voice message]", like: "❤️", media: "[photo]", raven_media: "[photo]",
      animated_media: "[GIF]", media_share: "[shared post]", clip: "[shared reel]", story_share: "[shared story]",
    }[kind] || (kind ? `[${kind}]` : "");
  };

  const openThread = () => {
    const found = [];
    for (const { body } of responses) walk(body, found, 0);
    const withItems = found.filter((t) => Array.isArray(t.items) && t.items.length);
    return withItems.length ? withItems[withItems.length - 1] : null;
  };

  ig.thread = () => {
    const opened = openThread();
    const id = (String(globalThis.location?.href || "").match(/\/direct\/t\/(\d+)/) || [])[1]
      || (opened ? idOf(opened) : null);
    const out = { id, me: viewer, messages: null, text: visible().slice(-4000) };
    if (!opened) return out;
    const users = new Map(
      (Array.isArray(opened.users) ? opened.users : Object.values(opened.users || {}))
        .map((u) => [String(u.pk ?? u.pk_id ?? u.id ?? ""), u.username || u.full_name || ""]),
    );
    out.messages = opened.items.map((item) => {
      // Instagram stamps items in microseconds.
      const raw = Number(item.timestamp || 0);
      const at = raw ? (raw > 1e14 ? Math.round(raw / 1000) : raw) : null;
      const uid = String(item.user_id ?? "");
      const mine = Boolean(viewer) && uid === viewer;
      return {
        sender: mine ? "me" : users.get(uid) || "someone",
        me: mine,
        text: itemText(item),
        at,
      };
    }).filter((m) => m.text);
    return out;
  };

  // Type and click Send. Nothing else clicks anything: the app's own button
  // sends, with the app's own request.
  ig.send = async (text) => {
    if (!text || !String(text).trim()) return { sent: false, reason: "empty text" };
    const box = composer();
    if (!box) return { sent: false, reason: "no message box on this page: open the thread first" };
    insert(box, String(text));
    const button = sendButton();
    if (!button) {
      return { sent: false, reason: "typed, but no Send button appeared: press Enter yourself or check the box" };
    }
    if (!draft(box)) {
      return { sent: false, reason: "the text did not reach the box: open the thread and try again" };
    }
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
      button.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }));
    }
    button.click();
    await pause(700);
    // Read back, never assume: the app empties the box when it sends, and
    // ignores a scripted click on this button (it wants a real pointer).
    if (!draft(box)) {
      return { sent: true, how: "the page's Send button", after: visible().slice(-400) };
    }
    return {
      sent: false,
      reason: "the text is still in the box: the app ignored the scripted click",
      needsRealClick: true,
      point: ig.sendPoint(),
    };
  };

  // Empty the box again, without sending: what a draft that must not be sent
  // needs.
  ig.clear = async () => {
    const box = composer();
    if (!box) return { cleared: false, reason: "no message box on this page" };
    box.focus();
    const doc = document_();
    if (box.tagName === "TEXTAREA") {
      const setter = Object.getOwnPropertyDescriptor(globalThis.HTMLTextAreaElement.prototype, "value")?.set;
      setter?.call(box, "");
      box.dispatchEvent(new Event("input", { bubbles: true }));
      await pause(250);
      return { cleared: String(box.value || "").trim() === "" };
    }
    // React owns this node: emptying textContent, or execCommand("delete"),
    // is undone by its next render. Select the contents and let its own
    // Backspace handling remove them, as a person would.
    const selection = typeof globalThis.getSelection === "function"
      ? globalThis.getSelection()
      : typeof doc?.getSelection === "function" ? doc.getSelection() : null;
    if (doc && doc.createRange && selection) {
      const range = doc.createRange();
      range.selectNodeContents(box);
      selection.removeAllRanges();
      selection.addRange(range);
    }
    box.dispatchEvent(new KeyboardEvent("keydown", {
      key: "Backspace", code: "Backspace", keyCode: 8, which: 8, bubbles: true, cancelable: true,
    }));
    await pause(250);
    return { cleared: String(box.textContent || "").trim() === "" };
  };

  hookFetch();
  hookXHR();
  return "installed";
})();
