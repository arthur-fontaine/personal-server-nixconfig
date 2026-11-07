/* direct.js, without a browser: the thread parsing, the inbox, the composer
 * lookup and the send path, driven by stand-ins for the page.
 *
 *   node modules/hermes/agent/skills/instagram/direct.test.mjs
 *
 * The fixture shapes come from a real inbox payload and a real DM page
 * (`slide_messages.edges[].node.igd_snippet`, `last_activity_timestamp_ms`,
 * `[role="button"]` rows, an svg labelled "Send"). Nothing is sent anywhere:
 * click, execCommand and the fetch hook are recorded, not performed.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "direct.js"), "utf8");

const failures = [];
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `\n     got  ${JSON.stringify(got)}\n     want ${JSON.stringify(want)}`}`);
  if (!ok) failures.push(name);
};

// ── the page, as the script sees it ────────────────────────────────────────
const state = { clicks: 0, sends: 0, pressedAt: null, typed: null, backspace: false, range: false, ignoreClicks: false };
const sendIcon = { getAttribute: (k) => (k === "aria-label" ? "Send" : null), closest: () => sendButtonNode };
const sendButtonNode = {
  // Like the app: `.click()` and mouse events do nothing, a primary mouse
  // pointer pressed and released on the button sends and empties the box.
  click: () => { state.clicks++; },
  dispatchEvent: (event) => {
    if (event.type === "pointerdown" && event.pointerType === "mouse" && event.isPrimary) {
      state.down = event instanceof globalThis.PointerEvent;
    }
    if (event.type === "pointerup" && state.down && event.pointerType === "mouse") {
      state.down = false;
      state.pressedAt = { x: event.clientX, y: event.clientY };
      if (!state.ignoreClicks && box.textContent) {
        state.sends++;
        box.textContent = "";
      }
    }
    return true;
  },
  getBoundingClientRect: () => ({ left: 1200, top: 850, width: 30, height: 30 }),
};

const box = {
  tagName: "DIV",
  textContent: "",
  focus: () => {},
  closest: () => null,
  // The page's own Backspace handling: it, and only it, empties the node.
  dispatchEvent: (event) => {
    if (event.type !== "keydown") return true;
    state.backspace = true;
    state.clearedWithSelection = state.range;
    if (event.key === "Backspace" && state.range) box.textContent = "";
    return true;
  },
};

// Invented rows: app shape, no real person or message.
const rowTexts = [
  "Azur Vous : à tout à l’heure · 1h",
  "Zoé, Nino et Sam a partagé un post. · 11m",
  "Camille 2 nouveaux messages · 17m Non lu",
];
const rowNode = (text) => ({ innerText: text });

globalThis.getSelection = () => ({ removeAllRanges: () => {}, addRange: () => {} });
globalThis.location = { href: "https://www.instagram.com/direct/t/1000000000000001/" };
globalThis.MouseEvent = class { constructor(type, init = {}) { this.type = type; Object.assign(this, init); } };
globalThis.PointerEvent = class extends globalThis.MouseEvent {};
globalThis.KeyboardEvent = class { constructor(type, init = {}) { this.type = type; Object.assign(this, init); } };
globalThis.document = {
  title: "(2) Instagram • Messages",
  execCommand: (command, _ui, text) => {

    if (command !== "insertText") return false;
    state.typed = text;
    box.textContent = text;
    return true;
  },
  querySelector: (s) => (s.includes("textbox") || s.includes("contenteditable") ? box : null),
  querySelectorAll: (s) => {
    if (s === '[role="button"]') return rowTexts.map(rowNode);
    if (s === "[aria-label], [title]") return [sendIcon];
    return [];
  },
  body: { innerText: "Zoé\nOn se voit toujours à 20 h ?\n+ older messages above" },
  createRange: () => ({ selectNodeContents: () => (state.range = true) }),
};

// ── what the app fetched, shaped like the real inbox response ──────────────
let payload = {
  data: {
    inbox: {
      threads: [
        {
          id: "1000000000000001",
          thread_id: "340282366841710300949128000000000000001",
          thread_title: "Zoé, Nino et Sam",
          marked_as_unread: false,
          last_activity_timestamp_ms: "1767225600123",
          users: [{ username: "nino.dupont" }, { username: "zoe.martin" }, { username: "sam.leroy" }],
          slide_messages: { edges: [{ node: { igd_snippet: "a partagé un post.", text_body: "" } }] },
        },
        {
          id: "1000000000000002",
          thread_id: "340282366841710300949128000000000000002",
          thread_title: "Camille",
          marked_as_unread: true,
          last_activity_timestamp_ms: "1767222000456",
          users: [{ username: "camille.exemple" }],
          // A release that previews with `text_body` and no snippet.
          slide_messages: { edges: [{ node: { text_body: "2 nouveaux messages" } }] },
        },
        {
          // No id, only the 128-bit form: still identifiable.
          thread_id: "340282366841710300949128000000000000003",
          thread_title: "Azur",
          users: [{ username: "azur.exemple" }],
          items: [{ text: "à tout à l’heure", timestamp: 1767210000000000 }],
        },
      ],
    },
  },
};
let fetches = 0;
globalThis.fetch = (url) => {
  fetches++;
  return Promise.resolve({ clone: () => ({ json: () => Promise.resolve(payload) }) });
};

// ── install ────────────────────────────────────────────────────────────────
check("installs", eval(source), "installed");
check("installs once", eval(source), "already installed");
const ig = globalThis.__ig;

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
globalThis.fetch("https://www.instagram.com/api/graphql");
await settle();
await settle();
check("hook saw the request", fetches, 1);

// ── the inbox, from the app's own traffic ──────────────────────────────────
const inbox = ig.inbox();
check("thread count", inbox.count, 3);
check("unread from the title", inbox.unread, "2");
check("newest first", inbox.threads.map((t) => t.name), ["Zoé, Nino et Sam", "Camille", "Azur"]);

const [group, camille, azur] = inbox.threads;
check("numeric id, the one the URL takes", group.id, "1000000000000001");
check("the 128-bit id is kept apart", group.v2, "340282366841710300949128000000000000001");
check("participants", group.users, ["nino.dupont", "zoe.martin", "sam.leroy"]);
check("a group says so", group.group, true);
check("a one-to-one thread does not", camille.group, false);
check("preview from slide_messages", group.text, "a partagé un post.");
check("absolute time, in ms", group.at, 1767225600123);
check("unread flag", [group.unread, camille.unread], [false, true]);
check("text_body as the preview", camille.text, "2 nouveaux messages");
check("id falls back to the 128-bit form", azur.id, "340282366841710300949128000000000000003");
check("microseconds normalised to ms", azur.at, 1767210000000);
check("items preview", azur.text, "à tout à l’heure");
check("row texts come along", inbox.rows[2], "Camille 2 nouveaux messages · 17m Non lu");
check("no page dump when threads exist", inbox.page, undefined);

// ── diag ───────────────────────────────────────────────────────────────────
const diag = ig.diag();
check("diag: threads found", diag.fromTraffic, 3);
check("diag: rows seen", diag.rows, 3);
check("diag: composer found", diag.composer, true);
check("diag: send button found by its svg label", diag.sendButton, true);
check("diag: one URL per capture", diag.responses.length, 1);
check("diag: the captured shape, for when the walk finds nothing",
  ["data", "data.inbox", "data.inbox.threads[]", "data.inbox.threads[0].slide_messages"]
    .every((path) => diag.shape.includes(path)), true);

// ── reading the open thread ────────────────────────────────────────────────
const thread = ig.thread();
check("thread id from the URL", thread.id, "1000000000000001");
check("thread text", thread.text.includes("On se voit toujours"), true);

// ── the thread the page has open: who said what ────────────────────────────
// Instagram stamps items in microseconds and names their author by `user_id`;
// `viewer_id` is the app saying which of them is the user.
const openPayload = {
  data: {
    viewer_id: "4242",
    thread: {
      id: "1000000000000001",
      thread_id: "340282366841710300949128000000000000001",
      thread_title: "Zoé, Nino et Sam",
      users: [{ pk: "4242", username: "azur.exemple" }, { pk: "7", username: "zoe.martin" }],
      items: [
        { item_id: "1", user_id: "7", timestamp: 1767225000000000, item_type: "text", text: "Bubble tea ?" },
        { item_id: "2", user_id: "4242", timestamp: 1767225600000000, item_type: "text", text: "?" },
        { item_id: "3", user_id: "7", timestamp: 1767225660000000, item_type: "like" },
      ],
    },
  },
};
// The response the hook's own fetch returns: swap what it answers with.
payload = openPayload;
globalThis.fetch("https://www.instagram.com/api/graphql/thread");
await settle();
await settle();

const open = ig.thread();
check("thread: id from the URL", open.id, "1000000000000001");
check("thread: the user, as the app named them", open.me, "4242");
check("thread: each message with its sender", open.messages, [
  { sender: "zoe.martin", me: false, text: "Bubble tea ?", at: 1767225000000 },
  { sender: "me", me: true, text: "?", at: 1767225600000 },
  { sender: "zoe.martin", me: false, text: "❤️", at: 1767225660000 },
]);

// ── sending ────────────────────────────────────────────────────────────────
check("empty send refused", await ig.send("   "), { sent: false, reason: "empty text" });

const sent = await ig.send("On se retrouve à 20 h 30 ?");
check("typed into the box", state.typed, "On se retrouve à 20 h 30 ?");
check("pressed the page's Send button as a mouse", state.sends, 1);
check("at its centre", state.pressedAt, { x: 1215, y: 865 });
check("and nothing that could send it twice", state.clicks, 0);
check("reported how", sent.how, "the page's Send button");
check("reported sent", sent.sent, true);
check("where the button is, for a real click", ig.sendPoint(), { found: true, x: 1215, y: 865 });

// When the app ignores the press too, the text stays in the box, and the
// answer must say so (with the point to click) instead of claiming it went.
state.ignoreClicks = true;
const refused = await ig.send("On se retrouve à 20 h 30 ?");
check("a click that was ignored is not a send", refused.sent, false);
check("it asks for a real click", refused.needsRealClick, true);
check("with the button's point", refused.point, { found: true, x: 1215, y: 865 });
state.ignoreClicks = false;

// ── a draft that must not be sent can be emptied ───────────────────────────
const cleared = await ig.clear();
check("cleared the box", cleared.cleared, true);
check("selected the draft first", state.range, true);
check("let the page's own Backspace handle it", state.backspace, true);
check("the selection was in place when it did", state.clearedWithSelection, true);

// ── no thread open: say so instead of typing into nothing ──────────────────
const keep = globalThis.document.querySelector;
globalThis.document.querySelector = () => null;
check("no composer", await ig.send("hello"), { sent: false, reason: "no message box on this page: open the thread first" });
globalThis.document.querySelector = keep;

if (failures.length) {
  console.error(`\ndirect.js: ${failures.length} check(s) failed`);
  process.exit(1);
}
console.log("\ndirect.js: all checks passed");
