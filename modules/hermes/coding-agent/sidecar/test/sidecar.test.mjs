// The sidecar's logic without a VM: the protocol, the network policy, Pi's
// event stream, the image's identity, and a whole session against a fake VM.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { fileURLToPath } from "node:url";
import { after, test } from "node:test";

import { Peer } from "../src/protocol.mjs";
import { Grants, NetworkPolicy, ambiguousPath, describeRequest, normalizeGrant } from "../src/policy.mjs";
import { PiProgress } from "../src/pi-events.mjs";
import { buildConfig, imageId, ensureImage } from "../src/image.mjs";
import { DEFAULTS, REFUSED, Session, bootVm, brokerResponse, guard, piAdvisor, piArgv, piFacts, piSettings } from "../src/session.mjs";
import { ACTIONS as BROKER_ACTIONS, Broker, InvalidAction, MAX_BODY, validateAction } from "../src/broker.mjs";
import environment, { ACTIONS as PROMPT_ACTIONS, SECTION, renderEnvironment } from "../../pi/extensions/sandbox-environment/index.js";
import { FolderTooLarge, copyFolder } from "../src/folders.mjs";

function peerPair() {
  const toSidecar = new PassThrough();
  const fromSidecar = new PassThrough();
  const peer = new Peer(toSidecar, fromSidecar);
  const lines = [];
  let buffer = "";
  fromSidecar.setEncoding("utf8");
  fromSidecar.on("data", (chunk) => {
    buffer += chunk;
    let i;
    while ((i = buffer.indexOf("\n")) >= 0) {
      lines.push(JSON.parse(buffer.slice(0, i)));
      buffer = buffer.slice(i + 1);
    }
  });
  return { peer, lines, write: (message) => toSidecar.write(JSON.stringify(message) + "\n"), end: () => toSidecar.end() };
}

// A guest tree as the Nix store has it: read-only.
function readOnlyGuest() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-guest-"));
  fs.mkdirSync(path.join(dir, "node_modules"));
  fs.copyFileSync(new URL("../../pi/settings.json", import.meta.url), path.join(dir, "settings.json"));
  fs.copyFileSync(new URL("../../pi/advisor.json", import.meta.url), path.join(dir, "advisor.json"));
  fs.writeFileSync(path.join(dir, "node_modules", "x.js"), "");
  fs.chmodSync(path.join(dir, "node_modules", "x.js"), 0o444);
  fs.chmodSync(path.join(dir, "node_modules"), 0o555);
  return dir;
}
const GUEST = readOnlyGuest();
after(() => {
  fs.chmodSync(path.join(GUEST, "node_modules"), 0o755);
  fs.rmSync(GUEST, { recursive: true, force: true });
});

const tick = () => new Promise((resolve) => setImmediate(resolve));

async function until(predicate, what) {
  for (let i = 0; i < 200; i++) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail(`timed out waiting for ${what}`);
}

test("peer: commands reach their handler, split across chunks", async () => {
  const { peer, write } = peerPair();
  const seen = [];
  peer.on("stop", (message) => seen.push(message));
  write({ type: "stop", why: "user" });
  await until(() => seen.length === 1, "the stop");
  assert.equal(seen[0].why, "user");
});

test("peer: a request resolves with its reply, and rejects when the plugin goes", async () => {
  const { peer, lines, write, end } = peerPair();
  const answer = peer.request("approve", { host: "example.com" });
  await until(() => lines.length === 1, "the request");
  assert.deepEqual(lines[0], { host: "example.com", id: 1, kind: "approve", type: "request" });
  write({ type: "reply", id: 1, allow: true });
  assert.equal((await answer).allow, true);
  const pending = peer.request("approve", {});
  end();
  await assert.rejects(pending, /peer closed/);
});

test("peer: a request without a reply in time rejects", async () => {
  const { peer } = peerPair();
  await assert.rejects(peer.request("approve", {}, { timeoutMs: 20 }), /no reply/);
});

test("grants: host, wildcard, method and path boundaries", () => {
  const grants = new Grants([
    "opencode.ai",
    { host: "*.github.com" },
    { host: "api.example.com", method: "get", pathPrefix: "/repos/a" },
  ]);
  const at = (host, method = "GET", p = "/") => grants.covers({ host, method, path: p }) !== null;
  assert.ok(at("opencode.ai", "POST", "/inference/go/openai/v1/chat"));
  assert.ok(!at("evil-opencode.ai"));
  assert.ok(!at("opencode.ai.evil.com"));
  assert.ok(at("api.github.com"));
  assert.ok(!at("github.com"), "a wildcard is subdomains only");
  assert.ok(at("api.example.com", "GET", "/repos/a"));
  assert.ok(at("api.example.com", "GET", "/repos/a/issues"));
  assert.ok(!at("api.example.com", "GET", "/repos/ab"));
  assert.ok(!at("api.example.com", "POST", "/repos/a"));
  assert.throws(() => normalizeGrant({ host: "a b" }));
  assert.throws(() => normalizeGrant({ host: "x.com", pathPrefix: "relative" }));
  assert.ok(grants.revoke("opencode.ai"));
  assert.ok(!at("opencode.ai"));
});

test("grants: paths match as parsed, never decoded; ambiguous ones match no path grant", () => {
  const grants = new Grants([{ host: "api.example.com", pathPrefix: "/repos/a" }, "whole.example"]);
  const at = (url) => grants.covers(describeRequest(new Request(url))) !== null;
  assert.ok(at("https://api.example.com/repos/a/x"));
  assert.ok(at("https://api.example.com/repos/a/./x/../y"), "dot segments are resolved by the parser");
  assert.ok(!at("https://api.example.com/repos/a/../b"));
  assert.ok(!at("https://api.example.com/repos/a/%2e%2E/b"), "encoded dot segments too");
  for (const sneaky of ["/repos/a/..%2Fb", "/repos/a%2F..%2F..%2Fadmin", "/repos/a/x%5C..%5Cy", "/repos/a/%2E%2e%2fz", "/repos/a/.%2e"]) {
    assert.ok(!at(`https://api.example.com${sneaky}`), sneaky);
  }
  assert.ok(!at("https://api.example.com/repos/%61/x"), "an encoded letter is another path, never a match");
  assert.equal(describeRequest(new Request("https://api.example.com/repos/a%2Fb")).path, "/repos/a%2Fb");
  assert.ok(at("https://whole.example/x%2F..%2Fy"), "a host grant does not look at the path");
  for (const bad of ["/a/../b", "/a/%2e%2e", "/a%2fb", "/a\\b", "/a b"]) {
    assert.throws(() => normalizeGrant({ host: "x.com", pathPrefix: bad }), undefined, bad);
  }
  assert.equal(ambiguousPath("/@scope%2Fpkg"), true);
  assert.equal(ambiguousPath("/simple/requests/"), false);
});

test("policy: denies what no grant covers, audits without headers or query", async () => {
  const audit = [];
  const policy = new NetworkPolicy({ grants: ["opencode.ai"], audit: (e) => audit.push(e) });
  const request = (url, method = "GET") => new Request(url, { method, headers: { authorization: "Bearer PLACEHOLDER" } });
  assert.equal(await policy.isRequestAllowed(request("https://opencode.ai/inference/go/openai/v1/chat", "POST")), true);
  assert.equal(await policy.isRequestAllowed(request("https://example.com/x?token=abc")), false);
  assert.deepEqual(audit.map((e) => [e.request.host, e.decision, e.by, e.outcome]), [
    ["opencode.ai", "allow", "grant", "allowed by a grant"],
    ["example.com", "deny", "policy", "refused: 403"],
  ]);
  assert.deepEqual(audit[0].request, { method: "POST", scheme: "https", host: "opencode.ai", path: "/inference/go/openai/v1/chat" });
  assert.equal(audit[0].grant.host, "opencode.ai");
  assert.ok(!JSON.stringify(audit).includes("PLACEHOLDER"));
  assert.ok(!JSON.stringify(audit).includes("token=abc"));
  assert.deepEqual(describeRequest({ url: "not a url", method: "get" }).host, "");
});

test("policy: an approver can allow once or add a grant for the session", async () => {
  const asked = [];
  const answers = [{ allow: true }, { allow: true, grant: { host: "pypi.org", method: "GET" } }, { allow: false }];
  const policy = new NetworkPolicy({
    grants: [],
    approve: async (what) => {
      asked.push(what);
      return answers.shift();
    },
  });
  const get = (url) => policy.isRequestAllowed(new Request(url));
  assert.equal(await get("https://files.example/a"), true);
  assert.equal(await get("https://pypi.org/simple/x"), true);
  assert.equal(await get("https://pypi.org/simple/y"), true, "the grant now covers it, no question");
  assert.equal(await get("https://files.example/a"), false);
  assert.equal(asked.length, 3);
  assert.deepEqual(asked[0], { host: "files.example", method: "GET", path: "/a", scheme: "https", ambiguous: false });
  const failing = new NetworkPolicy({ approve: async () => { throw new Error("gone"); } });
  assert.equal(await failing.isRequestAllowed(new Request("https://x.example/")), false);
});

function gate() {
  let open;
  const opened = new Promise((resolve) => { open = resolve; });
  return { open, opened };
}

test("policy: concurrent requests to one host make one question", async () => {
  const asked = [];
  let release = gate();
  let answer = { allow: true, grant: { host: "pypi.org" }, by: "owner" };
  const audit = [];
  const policy = new NetworkPolicy({
    audit: (e) => audit.push(e),
    approve: async (what) => { asked.push(what); await release.opened; return answer; },
  });
  const get = (url, method = "GET") => policy.isRequestAllowed(new Request(url, { method }));
  const all = Promise.all([get("https://pypi.org/a"), get("https://pypi.org/b"), get("https://pypi.org/a", "POST")]);
  await tick();
  assert.equal(asked.length, 1, "the others wait on the first question");
  release.open();
  assert.deepEqual(await all, [true, true, true], "a host grant covers them all");
  assert.deepEqual(audit.map((e) => e.by), ["owner", "grant", "grant"]);
  assert.equal(audit[0].outcome, "allowed, and granted for the session");
  assert.deepEqual(audit[0].grant, { host: "pypi.org", method: null, pathPrefix: null });

  // Allowed once: the identical request rides along, another path asks anew.
  asked.length = 0;
  release = gate();
  answer = { allow: true, by: "owner" };
  const once = Promise.all([get("https://files.example/x"), get("https://files.example/x"), get("https://files.example/y")]);
  await tick();
  assert.equal(asked.length, 1);
  release.open();
  assert.deepEqual(await once, [true, true, true]);
  assert.deepEqual(asked.map((w) => w.path), ["/x", "/y"]);

  // Refused: every request waiting on that host is refused with it.
  asked.length = 0;
  release = gate();
  answer = { allow: false, by: "timeout" };
  const refused = Promise.all([get("https://evil.example/a"), get("https://evil.example/b")]);
  await tick();
  release.open();
  assert.deepEqual(await refused, [false, false]);
  assert.equal(asked.length, 1);
  assert.deepEqual(audit.slice(-2).map((e) => [e.decision, e.by]), [["deny", "timeout"], ["deny", "timeout"]]);
});

test("policy: addresses and bare names are refused without a question; a bad grant refuses", async () => {
  const asked = [];
  const policy = new NetworkPolicy({ approve: async (w) => { asked.push(w); return { allow: true, grant: { host: "a b" } }; } });
  for (const url of ["https://1.2.3.4/", "http://localhost/", "https://intranet/", "https://[::1]/", "https://printer.local/"]) {
    assert.equal(await policy.isRequestAllowed(new Request(url)), false, url);
  }
  assert.equal(asked.length, 0);
  assert.equal(await policy.isRequestAllowed(new Request("https://ok.example/")), false, "an invalid grant is a refusal");
  assert.equal(policy.grants.list().length, 0);
  assert.equal((await policy.isRequestAllowed(new Request("https://ok.example/a%2Fb"))), false);
  assert.equal(asked.at(-1).ambiguous, true, "Hermes is told the path is ambiguous");
});

test("session: Pi's requests become network questions to the plugin, and grants are reported", async () => {
  const { peer, lines, write } = peerPair();
  const workdir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-session-"));
  const session = new Session({ id: "q", task: "t", workdir, stateDir: workdir, guestDir: GUEST, branch: "sandbox/q" },
    { gondolin: {}, peer, env: {} });
  const allowed = session.policy.isRequestAllowed(new Request("https://pypi.org/simple/x"));
  await until(() => lines.some((l) => l.type === "request"), "the question");
  const request = lines.find((l) => l.type === "request");
  assert.deepEqual([request.kind, request.session, request.host, request.method, request.path], ["network", "q", "pypi.org", "GET", "/simple/x"]);
  write({ type: "reply", id: request.id, allow: true, by: "guard", grant: { host: "pypi.org", method: "GET", pathPrefix: "/simple" } });
  assert.equal(await allowed, true);
  const grants = lines.filter((l) => l.type === "grants").at(-1).grants;
  assert.ok(grants.some((g) => g.host === "pypi.org" && g.pathPrefix === "/simple"));
  fs.rmSync(workdir, { recursive: true, force: true });
});

test("broker: hermes.sandbox is answered on the host, never asked about, and nothing else is touched", async () => {
  const { peer, lines } = peerPair();
  const workdir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-session-"));
  const audit = () => fs.readFileSync(path.join(workdir, "audit.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
  const session = new Session({ id: "b", task: "t", workdir, stateDir: workdir, guestDir: GUEST, branch: "sandbox/b" },
    { gondolin: {}, peer, env: {} });
  assert.ok(session.policy.grants.list().some((g) => g.host === "hermes.sandbox"), "in the initial allow set");
  assert.ok(session.policy.grants.list().some((g) => g.host === "opencode.ai"));
  const answer = await brokerResponse(new Request("https://hermes.sandbox/v1/actions", { method: "POST", body: "{}" }), session.config, session.policy);
  assert.equal(answer.status, 503, "no broker given");
  const unauthorized = await brokerResponse(new Request("https://hermes.sandbox/v1/actions", { method: "POST", body: "{}" }), session.config, session.policy, session.broker);
  assert.equal(unauthorized.status, 401);
  assert.equal(await brokerResponse(new Request("https://example.com/"), session.config, session.policy), undefined);
  session.policy.revokeGrant("hermes.sandbox");
  assert.equal((await brokerResponse(new Request("https://hermes.sandbox/"), session.config, session.policy)).status, 403);
  assert.ok(!lines.some((l) => l.type === "request"), "never a question about the broker");
  const network = audit().filter((e) => e.event === "network");
  assert.deepEqual(network.map((e) => [e.request.host, e.decision, e.by]), [["hermes.sandbox", "allow", "grant"], ["hermes.sandbox", "allow", "grant"], ["hermes.sandbox", "deny", "policy"]]);
  assert.ok(network.every((e) => e.session === "b" && e.time));
  fs.rmSync(workdir, { recursive: true, force: true });
});

test("guard: a refusal tells Pi what it means; what it lets through is admitted once", async () => {
  const audit = [];
  const policy = new NetworkPolicy({ grants: ["opencode.ai", "hermes.sandbox"], localHosts: ["hermes.sandbox"], audit: (e) => audit.push(e) });
  const config = { brokerHost: "hermes.sandbox" };
  const refused = await guard(new Request("https://example.com/x?q=1"), config, policy);
  assert.equal(refused.status, 403);
  assert.equal(await refused.text(), REFUSED);
  assert.match(REFUSED, /not granted for this sandbox session; ask Hermes with request_host_action, once/);
  assert.equal(policy.admit(new Request("https://example.com/x")), false, "never admitted without a decision");
  assert.equal(await guard(new Request("https://opencode.ai/v1/chat", { method: "POST", body: "{}" }), config, policy), undefined);
  // Gondolin's isRequestAllowed sees the request with its secrets put in.
  const sent = new Request("https://opencode.ai/v1/chat?k=v", { method: "POST", headers: { authorization: "Bearer real" } });
  assert.equal(policy.admit(sent), true);
  assert.equal(policy.admit(sent), false, "once per decision");
  const broker = await guard(new Request("https://hermes.sandbox/v1/actions", { method: "POST", body: "{}" }), config, policy);
  assert.equal(broker.status, 503, "the broker's host is answered here (no broker given), never let out");
  const network = audit.filter((e) => e.event === "network");
  assert.deepEqual(network.slice(0, 4).map((e) => [e.request.host, e.decision, e.by]),
    [["example.com", "deny", "policy"], ["example.com", "deny", "policy"], ["opencode.ai", "allow", "grant"], ["opencode.ai", "deny", "policy"]]);
});

test("environment: Pi's prompt section, from the session's own facts", async () => {
  const config = {
    branch: "sandbox/e1", brokerHost: "hermes.sandbox",
    grants: ["api.anthropic.com", { host: "pypi.org", method: "get", pathPrefix: "/simple" }],
  };
  const facts = piFacts(config);
  const text = renderEnvironment(facts);
  assert.match(text, /\/workspace\/repo, on branch sandbox\/e1/);
  assert.match(text, /At the start: api\.anthropic\.com, pypi\.org \(GET \/simple only\), hermes\.sandbox \(Hermes' broker\)\./);
  assert.ok(!text.includes("opencode"), "no host the session was not given");
  assert.match(text, /not granted for this sandbox/);
  assert.ok(text.includes(REFUSED.split(";")[0].slice(0, 40)), "names the refusal Pi will see");
  assert.match(text, /read-only under \/host\/<name>/);
  assert.deepEqual(Object.keys(PROMPT_ACTIONS), Object.keys(BROKER_ACTIONS), "one line per action the broker takes");
  const words = text.split(/\s+/).filter(Boolean).length;
  assert.ok(words <= 350, `${words} words`);

  // The extension: a section through before_agent_start, only with the facts.
  const agentDir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-agent-"));
  const saved = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;
  try {
    const handlers = [];
    environment({ on: (event, handler) => handlers.push([event, handler]) });
    assert.deepEqual(handlers, [], "no facts, no section");
    fs.writeFileSync(path.join(agentDir, "sandbox.json"), JSON.stringify(facts));
    environment({ on: (event, handler) => handlers.push([event, handler]) });
    assert.deepEqual(handlers.map(([event]) => event), ["before_agent_start"]);
    const event = { systemPromptOptions: { sections: {} } };
    handlers[0][1](event);
    assert.equal(event.systemPromptOptions.sections[SECTION], text);
    assert.match(SECTION, /^[a-z][a-z0-9_-]*$/, "a name Pi accepts (core/system-prompt.js)");
  } finally {
    if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = saved;
    fs.rmSync(agentDir, { recursive: true, force: true });
  }
});

test("pi events: counters, last answer, framing across chunks", () => {
  const progress = new PiProgress();
  const lines = [
    { type: "session", id: "s1" },
    { type: "tool_execution_start", toolName: "bash" },
    { type: "turn_end" },
    { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "Done: added tests." }], usage: { totalTokens: 120, cost: { total: 0.0012 } } } },
    { type: "agent_settled", aborted: false },
  ].map((e) => JSON.stringify(e) + "\n").join("");
  progress.push("not json\n" + lines.slice(0, 37));
  progress.push(lines.slice(37));
  assert.equal(progress.sessionId, "s1");
  assert.equal(progress.lastText, "Done: added tests.");
  assert.deepEqual(progress.snapshot(), { turns: 1, tool_calls: 1, last_tool: "bash", tokens: 120, cost: 0.0012, errors: [] });
  assert.ok(progress.settled);
});

test("pi argv: headless JSON mode, no project config, a task never read as a file", () => {
  const argv = piArgv({ task: "@etc/passwd fix it" });
  assert.deepEqual(argv.slice(2, 6), ["--mode", "json", "--print", "--no-approve"]);
  assert.equal(argv.at(-2), "--");
  assert.equal(argv.at(-1), " @etc/passwd fix it");
});

test("pi settings: the image's, under the session's model and thinking; the extensions it names exist", () => {
  const pi = fileURLToPath(new URL("../../pi", import.meta.url));
  const baked = JSON.parse(fs.readFileSync(path.join(pi, "settings.json"), "utf8"));
  for (const extension of baked.extensions) {
    assert.ok(extension.startsWith("/opt/pi/"));
    assert.ok(fs.existsSync(path.join(pi, extension.slice("/opt/pi/".length), "index.js")), extension);
  }
  assert.deepEqual(piSettings(pi, { model: "opencode-go/other-model", thinking: "max" }),
    { ...baked, defaultProvider: "opencode-go", defaultModel: "other-model", defaultThinkingLevel: "max" });
  // pi-advisor-flow, from the guest's node_modules by path: an npm: source
  // would be installed at startup, which Pi cannot do offline.
  assert.deepEqual(baked.packages, ["/opt/pi/node_modules/pi-advisor-flow"]);
  const lock = fs.readFileSync(path.join(pi, "pnpm-lock.yaml"), "utf8");
  assert.match(lock, /\n {6}pi-advisor-flow:\n {8}specifier: 0\.14\.4\n/, "pinned");
});

// pi-advisor-flow 0.14.4's keys and values, as its src/config/schema.ts,
// defaults.ts and model-stream.ts take them (read, never run, here).
const ADVISOR_KEYS = new Set([
  "advisor", "advisorEffort", "executor", "executorEffort", "advisorDisableSameModel", "contextMaxChars",
  "advisorSessionSummary", "advisorMaxCallsPerSession", "advisorRedactSecrets", "advisorToolResultMaxBytes",
  "alwaysOn", "simpleMode", "gateFailureMode", "advisorHerdrIntegration", "advisorScoutEnabled",
  "advisorJevFilterEnabled", "advisorToolsEnabled",
]);
const EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max"];

test("advisor: the image's advisor.json, headless and bounded, the session's model as executor", () => {
  const pi = fileURLToPath(new URL("../../pi", import.meta.url));
  const baked = JSON.parse(fs.readFileSync(path.join(pi, "advisor.json"), "utf8"));
  for (const key of Object.keys(baked)) assert.ok(ADVISOR_KEYS.has(key), `pi-advisor-flow knows ${key}`);
  assert.equal(baked.alwaysOn, true, "active without /advisor, which -p never runs");
  assert.equal(baked.simpleMode, false, "Simple mode would lift the call budget");
  assert.equal(baked.advisorDisableSameModel, false, "the advisor is the executor's model");
  assert.equal(baked.gateFailureMode, "block-tool", "a failed or spent gate never aborts the run");
  assert.ok(EFFORTS.includes(baked.advisorEffort) && EFFORTS.includes(baked.executorEffort));
  assert.equal(baked.advisorRedactSecrets, true);
  for (const key of ["advisorHerdrIntegration", "advisorScoutEnabled", "advisorJevFilterEnabled"]) {
    assert.equal(baked[key], false, `${key}: nothing but the model`);
  }
  assert.ok(baked.advisor.startsWith("opencode-go/"), "the one provider the guest reaches");

  const advisor = piAdvisor(pi, {
    model: "opencode-go/other", thinking: "low",
    advisor: { enable: true, model: "opencode-go/big", effort: "high", maxCalls: 2, contextMaxChars: 1000 },
  });
  assert.deepEqual(advisor, { ...baked, executor: "opencode-go/other", executorEffort: "low", advisor: "opencode-go/big",
    advisorEffort: "high", advisorMaxCallsPerSession: 2, contextMaxChars: 1000 });
  assert.deepEqual(piAdvisor(pi, { model: "m/x", thinking: "high" }),
    { ...baked, executor: "m/x", executorEffort: "high" }, "the image's values when Hermes sets none");
  const off = piAdvisor(pi, { model: "m/x", thinking: "high", advisor: { enable: false } });
  assert.equal(off.alwaysOn, false);
  assert.equal(off.advisorToolsEnabled, false);
});

test("image: identity follows the guest tree, builds once, never half", async () => {
  const a = buildConfig({ guestDir: "/nix/store/a-guest" });
  assert.notEqual(imageId(a), imageId(buildConfig({ guestDir: "/nix/store/b-guest" })));
  assert.ok(a.alpine.rootfsPackages.includes("nodejs-current"));
  assert.deepEqual(a.postBuild.copy, [{ src: "/nix/store/a-guest", dest: "/opt/pi" }]);
  assert.equal(a.postBuild.commands, undefined, "commands would need Docker on macOS");
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-image-"));
  let builds = 0;
  const fake = {
    buildAssets: async (config, { outputDir }) => {
      builds += 1;
      const staged = config.postBuild.copy[0].src;
      assert.notEqual(staged, GUEST, "a writable copy, not the store path");
      fs.writeFileSync(path.join(staged, "node_modules", "probe"), "writable");
      fs.mkdirSync(outputDir, { recursive: true });
      fs.writeFileSync(path.join(outputDir, "manifest.json"), "{}");
    },
    verifyAssets: (dir) => fs.existsSync(path.join(dir, "manifest.json")),
  };
  const first = await ensureImage({ stateDir, guestDir: GUEST, ...fake });
  const again = await ensureImage({ stateDir, guestDir: GUEST, ...fake });
  assert.deepEqual([first.built, again.built, builds], [true, false, 1]);
  await assert.rejects(ensureImage({ stateDir, guestDir: GUEST + "/node_modules", buildAssets: async () => { throw new Error("offline"); }, verifyAssets: () => false }));
  assert.deepEqual(fs.readdirSync(path.join(stateDir, "images")), [path.basename(first.dir)], "a failed build leaves nothing");
  assert.ok(!fs.existsSync(path.join(GUEST, "node_modules", "probe")));
  fs.rmSync(stateDir, { recursive: true, force: true });
});

// A guest that answers the commands a session runs, with a Pi that commits.
class FakeVm {
  static last = null;
  constructor(options) {
    this.options = options;
    this.files = new Map();
    this.commands = [];
    this.closed = false;
    FakeVm.last = this;
    this.fs = {
      writeFile: async (p, data) => { this.files.set(p, Buffer.from(data)); },
      readFile: async (p) => this.files.get(p),
    };
  }
  static async create(options) { return new FakeVm(options); }
  async close() { this.closed = true; }
  exec(argv, options = {}) {
    this.commands.push({ argv, options });
    const done = (stdout = "", exitCode = 0) => Promise.resolve({ exitCode, stdout, stderr: "" });
    const command = argv.filter((a) => !a.startsWith("-c") && !a.includes("=") && a !== "-C" && a !== "/workspace/repo");
    if (argv[0] === "node") {
      const events = [
        { type: "session", id: "pi-1" },
        { type: "tool_execution_start", toolName: "edit" },
        { type: "turn_end" },
        { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "I changed README." }] } },
        { type: "agent_settled", aborted: false },
      ];
      const result = { exitCode: 0, stdout: "", stderr: "" };
      const proc = Promise.resolve(result);
      proc.output = async function* () {
        for (const e of events) yield { stream: "stdout", text: JSON.stringify(e) + "\n" };
      };
      return proc;
    }
    const sub = command[1];
    if (sub === "rev-parse") return done(this.commits ? "head0000" : "base0000");
    if (sub === "status") { this.commits = 1; return done(" M README.md"); }
    if (sub === "rev-list") return done("1");
    if (sub === "bundle") { this.files.set("/tmp/out.bundle", Buffer.from("BUNDLE")); return done(); }
    return done();
  }
}

test("session: bundle in, Pi headless, bundle out, the key never in the guest", async () => {
  const workdir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-session-"));
  const stateDir = path.join(workdir, "state");
  const bundleIn = path.join(workdir, "in.bundle");
  fs.writeFileSync(bundleIn, "IN");
  const { peer, lines } = peerPair();
  const secret = "real-key-value";
  const gondolin = {
    VM: FakeVm,
    MemoryProvider: class {},
    ReadonlyProvider: class { constructor(backend) { this.backend = backend; } },
    buildAssets: async (_c, { outputDir }) => {
      fs.mkdirSync(outputDir, { recursive: true });
      fs.writeFileSync(path.join(outputDir, "manifest.json"), "{}");
    },
    verifyAssets: () => true,
    createHttpHooks: ({ secrets, isRequestAllowed, onRequest }) => ({
      httpHooks: { isRequestAllowed, secrets, onRequest },
      env: { OPENCODE_API_KEY: "PLACEHOLDER" },
    }),
  };
  const session = new Session(
    { id: "abc", task: "fix the README", workdir, stateDir, guestDir: GUEST, bundleIn, bundleRef: "refs/heads/main", branch: "sandbox/abc" },
    { gondolin, peer, env: { OPENCODE_GO_API_KEY: secret } },
  );
  const result = await session.run();
  const vm = FakeVm.last;
  assert.equal(result.status, "finished");
  assert.equal(result.commits, 1);
  assert.equal(result.base, "base0000");
  assert.equal(result.summary, "I changed README.");
  assert.equal(fs.readFileSync(result.bundle, "utf8"), "BUNDLE");
  assert.equal(vm.files.get("/tmp/in.bundle").toString(), "IN");
  assert.ok(vm.closed);
  assert.equal(vm.options.dns.mode, "synthetic");
  assert.equal(vm.options.allowWebSockets, false);
  assert.deepEqual(Object.keys(vm.options.vfs.mounts), ["/workspace", "/host"]);
  assert.ok(vm.options.vfs.mounts["/host"] instanceof gondolin.ReadonlyProvider, "folders Pi gets are read-only");
  assert.equal(vm.options.httpHooks.secrets.OPENCODE_API_KEY.value, secret);
  assert.deepEqual(vm.options.httpHooks.secrets.OPENCODE_API_KEY.hosts, ["opencode.ai"]);
  assert.equal((await vm.options.httpHooks.onRequest(new Request("https://hermes.sandbox/v1/actions", { method: "POST" }))).status, 401,
    "the broker, its token revoked once Pi is done");
  assert.ok(!JSON.stringify(vm.options.env).includes(secret));
  assert.ok(!JSON.stringify(vm.commands).includes(secret));
  const fetch = vm.commands.find((c) => c.argv.includes("fetch"));
  assert.deepEqual(fetch.argv.slice(-2), ["/tmp/in.bundle", "refs/heads/main"]);
  const pi = vm.commands.find((c) => c.argv[0] === "node");
  assert.equal(pi.options.env.OPENCODE_API_KEY, "PLACEHOLDER");
  assert.equal(pi.options.env.HERMES_BROKER_TOKEN, session.broker.token);
  assert.equal(pi.options.env.HERMES_BROKER_URL, "https://hermes.sandbox/v1/actions");
  assert.deepEqual([pi.options.env.GIT_CONFIG_KEY_0, pi.options.env.GIT_CONFIG_VALUE_0], ["safe.directory", "*"], "Pi's git takes the repository");
  const settings = JSON.parse(vm.files.get("/root/.pi/agent/settings.json").toString());
  assert.deepEqual([settings.defaultProvider, settings.defaultModel, settings.defaultThinkingLevel], ["opencode-go", "deepseek-v4.1-flash", "high"]);
  assert.deepEqual(settings.extensions, ["/opt/pi/extensions/request-host-action", "/opt/pi/extensions/sandbox-environment"]);
  assert.deepEqual(JSON.parse(vm.files.get("/root/.pi/agent/sandbox.json").toString()), {
    repo: "/workspace/repo", branch: "sandbox/abc", hosts: [{ host: "opencode.ai" }], broker: "hermes.sandbox", hostFiles: "/host",
  });
  const advisor = JSON.parse(vm.files.get("/root/.pi/agent/advisor.json").toString());
  assert.deepEqual([advisor.executor, advisor.advisor, advisor.alwaysOn], ["opencode-go/deepseek-v4.1-flash", "opencode-go/deepseek-v4.1-flash", true]);
  assert.ok(lines.some((l) => l.type === "done" && l.result.status === "finished"));
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(workdir, "result.json"), "utf8")).commits, 1);
  const audit = fs.readFileSync(path.join(workdir, "audit.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
  assert.deepEqual(audit.map((a) => a.event), ["start", "pi", "end", "network", "action"]);
  assert.ok(!fs.readFileSync(path.join(workdir, "audit.jsonl"), "utf8").includes(secret));
  fs.rmSync(workdir, { recursive: true, force: true });
});

test("session: another provider's key, under Pi's name for it, to its hosts only", async () => {
  let hooks;
  const gondolin = {
    VM: FakeVm,
    MemoryProvider: class {},
    createHttpHooks: (options) => {
      hooks = options;
      return { httpHooks: {}, env: { [Object.keys(options.secrets)[0]]: "PLACEHOLDER" } };
    },
  };
  const config = { ...DEFAULTS, id: "p", secretName: "ANTHROPIC_API_KEY", secretHosts: ["api.anthropic.com"], keyEnv: "ANTHROPIC_API_KEY" };
  const policy = new NetworkPolicy({ grants: ["api.anthropic.com", "hermes.sandbox"] });
  const { env } = await bootVm({ gondolin, imageDir: "/nowhere", config, key: "sk-ant-real", policy });
  assert.deepEqual(hooks.secrets, { ANTHROPIC_API_KEY: { hosts: ["api.anthropic.com"], value: "sk-ant-real" } });
  assert.equal(env.ANTHROPIC_API_KEY, "PLACEHOLDER");
  assert.ok(!("OPENCODE_API_KEY" in env));
});

test("session: Pi exiting 0 after its model refused every call is a failure", async () => {
  const workdir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-session-"));
  const { peer } = peerPair();
  class RefusedVm extends FakeVm {
    static async create(options) { return new RefusedVm(options); }
    exec(argv, options) {
      if (argv[0] !== "node") return super.exec(argv, options);
      const proc = Promise.resolve({ exitCode: 0, stdout: "", stderr: "" });
      proc.output = async function* () {
        yield { stream: "stdout", text: JSON.stringify({ type: "message_end", message: { role: "assistant", content: [], stopReason: "error", errorMessage: "401: Invalid credential" } }) + "\n" };
      };
      return proc;
    }
  }
  const session = new Session({ id: "r", task: "t", workdir, stateDir: path.join(workdir, "state"), guestDir: GUEST, branch: "sandbox/r" }, {
    gondolin: {
      VM: RefusedVm, MemoryProvider: class {}, ReadonlyProvider: class {},
      buildAssets: async (_c, { outputDir }) => { fs.mkdirSync(outputDir, { recursive: true }); fs.writeFileSync(path.join(outputDir, "manifest.json"), "{}"); },
      verifyAssets: () => true,
      createHttpHooks: () => ({ httpHooks: {}, env: { OPENCODE_API_KEY: "P" } }),
    },
    peer, env: { OPENCODE_GO_API_KEY: "k" },
  });
  const result = await session.run();
  assert.equal(result.status, "failed");
  assert.match(result.error, /401/);
  fs.rmSync(workdir, { recursive: true, force: true });
});

test("session: no key is a clear failure, and nothing boots", async () => {
  const workdir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-session-"));
  const { peer } = peerPair();
  FakeVm.last = null;
  const session = new Session({ id: "x", task: "t", workdir, stateDir: workdir, guestDir: GUEST, branch: "sandbox/x" },
    { gondolin: { VM: FakeVm }, peer, env: {} });
  const result = await session.run();
  assert.equal(result.status, "failed");
  assert.match(result.error, /OPENCODE_GO_API_KEY/);
  assert.equal(FakeVm.last, null);
  fs.rmSync(workdir, { recursive: true, force: true });
});

test("session: a stop before boot ends it as stopped", async () => {
  const workdir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-session-"));
  const { peer } = peerPair();
  const session = new Session({ id: "y", task: "t", workdir, stateDir: workdir, guestDir: GUEST, branch: "sandbox/y" }, {
    gondolin: {
      VM: FakeVm,
      buildAssets: async () => { session.stop(); throw new Error("interrupted"); },
      verifyAssets: () => false,
    },
    peer,
    env: { OPENCODE_GO_API_KEY: "k" },
  });
  const result = await session.run();
  assert.equal(result.status, "stopped");
  await tick();
  fs.rmSync(workdir, { recursive: true, force: true });
});

// The broker: its token, its schemas, its sizes, its answers.

const TOKEN = "t".repeat(43);

function post(body, { token = TOKEN, type = "application/json", url = "https://hermes.sandbox/v1/actions", method = "POST" } = {}) {
  const headers = { "content-type": type };
  if (token !== null) headers.authorization = `Bearer ${token}`;
  return new Request(url, { method, headers, ...(method === "POST" ? { body: typeof body === "string" ? body : JSON.stringify(body) } : {}) });
}

function broker(perform = async () => ({ status: "allowed", by: "guard", reason: "secret reasoning", result: { x: 1 } })) {
  const audit = [];
  const calls = [];
  const b = new Broker({ token: TOKEN, perform: async (action, args) => { calls.push([action, args]); return perform(action, args); }, audit: (e) => audit.push(e) });
  return { b, audit, calls };
}

test("broker: the session's token only, compared in constant time, and none once revoked", async () => {
  const { b, audit, calls } = broker();
  const action = { action: "ask_user", question: "Which?", choices: ["a", "b"] };
  for (const token of [null, "", "x", TOKEN + "x", TOKEN.slice(1), `${TOKEN}=`]) {
    const response = await b.handle(post(action, { token }));
    assert.equal(response.status, 401, `token ${JSON.stringify(token)}`);
    assert.deepEqual(await response.json(), { ok: false, status: "error", result: { error: "unauthorized" } });
  }
  const basic = new Request("https://hermes.sandbox/v1/actions", { method: "POST", headers: { authorization: `Basic ${TOKEN}`, "content-type": "application/json" }, body: JSON.stringify(action) });
  assert.equal((await b.handle(basic)).status, 401);
  assert.equal(calls.length, 0);
  const ok = await b.handle(post(action));
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), { ok: true, status: "allowed", result: { x: 1 } });
  b.revoke();
  assert.equal((await b.handle(post(action))).status, 401, "revoked: every later call");
  assert.equal(calls.length, 1);
  assert.ok(!JSON.stringify(audit).includes(TOKEN), "the token is never audited");
  assert.throws(() => new Broker({ token: "short", perform: async () => ({}) }));
});

test("broker: a revocation while an action waits answers 401, whatever was decided", async () => {
  let release;
  const { b, audit } = broker(() => new Promise((resolve) => { release = resolve; }));
  const pending = b.handle(post({ action: "shell", command: "ls" }));
  await until(() => release, "the action to be asked");
  b.revoke();
  release({ status: "allowed", by: "owner", result: { exit_code: 0, output: "x" } });
  const response = await pending;
  assert.equal(response.status, 401);
  assert.equal(audit.at(-1).outcome, "the session ended first");
});

test("broker: path, method, JSON only, body size", async () => {
  const { b, calls } = broker();
  assert.equal((await b.handle(post({}, { url: "https://hermes.sandbox/v1/other" }))).status, 404);
  assert.equal((await b.handle(post({}, { method: "GET" }))).status, 405);
  assert.equal((await b.handle(post({ action: "shell", command: "ls" }, { type: "text/plain" }))).status, 415);
  assert.equal((await b.handle(post("{not json"))).status, 400);
  const big = { action: "shell", command: "x".repeat(MAX_BODY) };
  const tooLarge = await b.handle(post(big));
  assert.equal(tooLarge.status, 413);
  // A body without a length (streamed) is cut at the limit too.
  const stream = new ReadableStream({ start(c) { for (let i = 0; i < 20; i++) c.enqueue(new Uint8Array(1024).fill(32)); c.close(); } });
  const chunked = new Request("https://hermes.sandbox/v1/actions", { method: "POST", body: stream, duplex: "half", headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" } });
  assert.equal((await b.handle(chunked)).status, 413);
  assert.equal((await b.handle(post({ action: "shell", command: "ls" }, { type: "application/json; charset=utf-8" }))).status, 200);
  assert.equal(calls.length, 1);
});

test("broker: each action's schema, nothing unknown, no field for Pi's reasons", () => {
  const ok = [
    [{ action: "request_host", host: "PyPI.org" }, { host: "pypi.org" }],
    [{ action: "request_host", host: "api.github.com", method: "get", pathPrefix: "/repos/a" }, { host: "api.github.com", method: "GET", pathPrefix: "/repos/a" }],
    [{ action: "request_folder", path: "~/notes" }, { path: "~/notes" }],
    [{ action: "git_push", branch: "sandbox/20260101-000000-abcdef" }, { branch: "sandbox/20260101-000000-abcdef" }],
    [{ action: "ask_user", question: "Which one?\nReally.", choices: ["a", "b", "c"] }, { question: "Which one?\nReally.", choices: ["a", "b", "c"] }],
    [{ action: "shell", command: "ls -la", cwd: "/tmp" }, { command: "ls -la", cwd: "/tmp" }],
    [{ action: "shell", command: "ls", cwd: null }, { command: "ls" }],
  ];
  for (const [body, args] of ok) assert.deepEqual(validateAction(body), { action: body.action, args });
  const bad = [
    [null, /object/], [[], /object/], ["shell", /object/],
    [{ action: "rm" }, /action: one of/],
    [{ action: "__proto__" }, /action: one of/],
    [{ action: "shell", command: "ls", justification: "the user wants it" }, /unknown field.*justification/],
    [{ action: "git_push", branch: "sandbox/x", reason: "ok" }, /unknown field/],
    [{ action: "git_push", branch: "main" }, /branch/],
    [{ action: "git_push", branch: "sandbox/../main" }, /branch/],
    [{ action: "git_push", branch: "sandbox/x.lock" }, /branch/],
    [{ action: "git_push", branch: "sandbox/.x" }, /branch/],
    [{ action: "git_push" }, /required/],
    [{ action: "request_host", host: "a b" }, /host/],
    [{ action: "request_host", host: "x.com", method: "G3T" }, /method/],
    [{ action: "request_host", host: "x.com", pathPrefix: "/a/../b" }, /path/],
    [{ action: "request_host", host: "x.com", pathPrefix: "/a%2Fb" }, /path/],
    [{ action: "ask_user", question: "q", choices: ["only"] }, /choices/],
    [{ action: "ask_user", question: "q", choices: ["a", "b", "c", "d", "e"] }, /choices/],
    [{ action: "ask_user", question: "q", choices: ["a", "a"] }, /different/],
    [{ action: "ask_user", question: "q", choices: ["a", 2] }, /choices\[1\]/],
    [{ action: "ask_user", question: "", choices: ["a", "b"] }, /question/],
    [{ action: "shell", command: 42 }, /command/],
    [{ action: "shell", command: "x".repeat(4001) }, /command/],
    [{ action: "shell", command: "ls\u0000" }, /control/],
    [{ action: "request_folder", path: "/a\nb" }, /control/],
  ];
  for (const [body, message] of bad) assert.throws(() => validateAction(body), (e) => e instanceof InvalidAction && message.test(e.message), JSON.stringify(body));
});

test("broker: minimal answers, no reviewer's reason; a denial is final for the session", async () => {
  const answers = [
    { status: "denied", by: "owner", reason: "the owner tapped Deny, guard said high risk" },
    { status: "timeout", by: "timeout", reason: "no answer" },
    { status: "error", by: "broker", result: { error: "no such branch in /workspace/repo" } },
    { status: "weird", by: "x" },
  ];
  const { b, audit, calls } = broker(async () => answers.shift());
  const read = async (body) => { const r = await b.handle(post(body)); return [r.status, await r.json()]; };
  assert.deepEqual(await read({ action: "shell", command: "id" }), [200, { ok: false, status: "denied" }]);
  assert.deepEqual(await read({ action: "shell", command: "id" }), [200, { ok: false, status: "denied" }], "not asked again");
  assert.deepEqual(await read({ action: "shell", command: "whoami" }), [200, { ok: false, status: "timeout" }]);
  assert.deepEqual(await read({ action: "git_push", branch: "sandbox/x" }), [200, { ok: false, status: "error", result: { error: "no such branch in /workspace/repo" } }]);
  assert.deepEqual(await read({ action: "git_push", branch: "sandbox/y" }), [200, { ok: false, status: "error" }]);
  assert.equal(calls.length, 4);
  const lines = audit.filter((e) => e.event === "action");
  assert.deepEqual(lines.map((e) => [e.action, e.decision, e.by]), [
    ["shell", "denied", "owner"], ["shell", "denied", "final"], ["shell", "timeout", "timeout"],
    ["git_push", "error", "broker"], ["git_push", "error", "x"],
  ]);
  assert.deepEqual(lines[0].args, { command: "id" });
  assert.match(lines[0].reason, /guard said/, "the reviewer's reason is the audit's, never Pi's");
});

test("broker: at most a few actions wait at once", async () => {
  const releases = [];
  const { b } = broker(() => new Promise((resolve) => releases.push(resolve)));
  const waiting = [1, 2, 3, 4].map((n) => b.handle(post({ action: "shell", command: `echo ${n}` })));
  await until(() => releases.length === 4, "four questions");
  assert.equal((await b.handle(post({ action: "shell", command: "echo 5" }))).status, 429);
  releases.forEach((r) => r({ status: "allowed", by: "owner", result: {} }));
  assert.deepEqual((await Promise.all(waiting)).map((r) => r.status), [200, 200, 200, 200]);
});

test("folders: a read-only snapshot, links only inside it, bounded", async () => {
  const { MemoryProvider, ReadonlyProvider } = await import("@earendil-works/gondolin");
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-folder-")));
  const source = path.join(root, "my notes");
  fs.mkdirSync(path.join(source, "sub"), { recursive: true });
  fs.writeFileSync(path.join(source, "a.txt"), "A");
  fs.writeFileSync(path.join(source, "sub", "run.sh"), "#!/bin/sh\n", { mode: 0o755 });
  fs.symlinkSync("/etc/passwd", path.join(source, "link"));
  fs.writeFileSync(path.join(root, "outside.txt"), "secret");
  fs.symlinkSync("../outside.txt", path.join(source, "escape"));
  fs.symlinkSync("nowhere", path.join(source, "dangling"));
  fs.symlinkSync(path.join(source, "a.txt"), path.join(source, "sub", "a-link"));
  fs.symlinkSync("sub", path.join(source, "sub-link"));
  const memory = new MemoryProvider();
  const first = copyFolder(source, memory);
  assert.deepEqual(first, { name: "my_notes", files: 4, skipped: 3 }, "the links out of it are left out");
  const guest = new ReadonlyProvider(memory);
  assert.equal(guest.readFileSync("/my_notes/a.txt", "utf8"), "A");
  assert.equal(guest.readFileSync("/my_notes/sub/run.sh", "utf8"), "#!/bin/sh\n");
  for (const name of ["link", "escape", "dangling"]) {
    assert.throws(() => guest.lstatSync(`/my_notes/${name}`), `no ${name} comes in`);
  }
  assert.equal(guest.readlinkSync("/my_notes/sub/a-link"), "../a.txt", "relative, to the copy");
  assert.equal(guest.readFileSync("/my_notes/sub/a-link", "utf8"), "A");
  assert.equal(guest.readFileSync("/my_notes/sub-link/run.sh", "utf8"), "#!/bin/sh\n");
  assert.throws(() => guest.writeFileSync("/my_notes/a.txt", "B"));
  assert.throws(() => guest.mkdirSync("/x"));
  assert.equal(copyFolder(source, memory).name, "my_notes-2", "a second copy never overwrites the first");
  fs.writeFileSync(path.join(source, "a.txt"), "changed");
  assert.equal(guest.readFileSync("/my_notes/a.txt", "utf8"), "A", "a snapshot");
  assert.throws(() => copyFolder(source, memory, { files: 2, bytes: 1e9 }), FolderTooLarge);
  assert.throws(() => copyFolder(source, memory, { files: 100, bytes: 3 }), FolderTooLarge);
  assert.throws(() => copyFolder(path.join(source, "link"), memory), /resolved/);
  assert.throws(() => copyFolder("relative", memory));
  fs.rmSync(root, { recursive: true, force: true });
});

// A session whose Pi waits until the test says so, to call the broker
// meanwhile as the guest would.
class WaitingVm extends FakeVm {
  static gate = null;
  static async create(options) { return new WaitingVm(options); }
  exec(argv, options = {}) {
    if (argv[0] === "node") {
      const proc = new Promise((resolve) => { WaitingVm.gate = () => resolve({ exitCode: 0, stdout: "", stderr: "" }); });
      proc.output = async function* () {};
      return proc;
    }
    if (argv.includes("--verify") && argv.some((a) => a.startsWith("refs/heads/"))) {
      const exists = argv.some((a) => a.startsWith("refs/heads/sandbox/w^"));
      return Promise.resolve({ exitCode: exists ? 0 : 1, stdout: exists ? "pushsha" : "", stderr: "" });
    }
    if (argv.includes("bundle") && argv.includes("create")) {
      this.files.set(argv.at(-2), Buffer.from(`BUNDLE ${argv.at(-1)}`));
      return Promise.resolve({ exitCode: 0, stdout: "", stderr: "" });
    }
    if (argv[0] === "base64") {
      return Promise.resolve({ exitCode: 0, stdout: this.files.get(argv.at(-1)).toString("base64"), stderr: "" });
    }
    return super.exec(argv, options);
  }
}

test("session: the broker's actions reach the plugin typed, and their answers act here", async () => {
  const { MemoryProvider, ReadonlyProvider } = await import("@earendil-works/gondolin");
  const workdir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-session-")));
  const folder = path.join(workdir, "docs");
  fs.mkdirSync(folder);
  fs.writeFileSync(path.join(folder, "x.md"), "# x");
  const { peer, lines, write } = peerPair();
  WaitingVm.gate = null;
  const session = new Session({ id: "w", task: "t", workdir, stateDir: path.join(workdir, "state"), guestDir: GUEST, branch: "sandbox/w" }, {
    gondolin: {
      VM: WaitingVm, MemoryProvider, ReadonlyProvider,
      buildAssets: async (_c, { outputDir }) => { fs.mkdirSync(outputDir, { recursive: true }); fs.writeFileSync(path.join(outputDir, "manifest.json"), "{}"); },
      verifyAssets: () => true,
      createHttpHooks: ({ onRequest, isRequestAllowed }) => ({ httpHooks: { onRequest, isRequestAllowed }, env: { OPENCODE_API_KEY: "P" } }),
    },
    peer, env: { OPENCODE_GO_API_KEY: "k", HERMES_SANDBOX_TOKEN: TOKEN },
  });
  const running = session.run();
  await until(() => WaitingVm.gate, "Pi to start");
  const vm = WaitingVm.last;
  const call = async (body, token = TOKEN) => {
    const response = await vm.options.httpHooks.onRequest(post(body, { token }));
    return [response.status, await response.json()];
  };
  const requests = () => lines.filter((l) => l.type === "request").length;
  const answerNext = async (fields, before = requests()) => {
    await until(() => lines.filter((l) => l.type === "request").length > before, "a request");
    const request = lines.filter((l) => l.type === "request").at(-1);
    write({ type: "reply", id: request.id, ...fields });
    return request;
  };

  // request_host: the plugin's grant becomes the session's.
  let pending = call({ action: "request_host", host: "pypi.org", method: "GET", pathPrefix: "/simple" });
  let request = await answerNext({ status: "allowed", by: "guard", reason: "low risk", grant: { host: "pypi.org", method: "GET", pathPrefix: "/simple" } });
  assert.deepEqual([request.kind, request.session, request.action, request.args], ["action", "w", "request_host", { host: "pypi.org", method: "GET", pathPrefix: "/simple" }]);
  assert.deepEqual(await pending, [200, { ok: true, status: "allowed", result: { grant: { host: "pypi.org", method: "GET", pathPrefix: "/simple" } } }]);
  assert.ok(session.policy.grants.covers({ host: "pypi.org", method: "GET", path: "/simple/x" }));
  // Hermes may not grant more than was asked.
  pending = call({ action: "request_host", host: "files.example.com" });
  await answerNext({ status: "allowed", by: "owner", grant: { host: "*.example.com" } });
  assert.deepEqual(await pending, [200, { ok: false, status: "error" }]);
  assert.equal(session.policy.grants.covers({ host: "files.example.com", method: "GET", path: "/" }), null);
  // Never a question about what no one could judge.
  assert.deepEqual(await call({ action: "request_host", host: "localhost" }), [200, { ok: false, status: "denied" }]);

  // git_push: the branch must exist; it leaves as a bundle the plugin pushes.
  assert.deepEqual(await call({ action: "git_push", branch: "sandbox/nope" }), [200, { ok: false, status: "error", result: { error: "no such branch in /workspace/repo" } }]);
  const asked = requests();
  pending = call({ action: "git_push", branch: "sandbox/w" });
  await until(() => fs.existsSync(path.join(workdir, "push-1.bundle")), "the bundle on the host");
  const pushed = fs.readFileSync(path.join(workdir, "push-1.bundle"), "utf8");
  request = await answerNext({ status: "allowed", by: "owner", outcome: "pushed" }, asked);
  assert.equal(request.bundle, "push-1.bundle");
  assert.equal(pushed, "BUNDLE refs/heads/sandbox/w", "the plugin finds the guest's bundle on the host");
  assert.deepEqual(await pending, [200, { ok: true, status: "allowed", result: { pushed: "sandbox/w" } }]);
  assert.ok(!fs.existsSync(path.join(workdir, "push-1.bundle")), "the bundle is gone once pushed");

  // request_folder: the plugin names the resolved folder; it lands read-only.
  pending = call({ action: "request_folder", path: "~/docs" });
  request = await answerNext({ status: "allowed", by: "owner", folder: { path: folder } });
  assert.deepEqual(request.args, { path: "~/docs" });
  assert.deepEqual(await pending, [200, { ok: true, status: "allowed", result: { path: "/host/docs", files: 1 } }]);
  const mounted = vm.options.vfs.mounts["/host"];
  assert.ok(mounted instanceof ReadonlyProvider);
  assert.equal(mounted.readFileSync("/docs/x.md", "utf8"), "# x");

  // ask_user and shell: only what the schema says comes back.
  pending = call({ action: "ask_user", question: "Which?", choices: ["a", "b"] });
  await answerNext({ status: "allowed", by: "owner", result: { answer: "b", extra: "dropped" } });
  assert.deepEqual(await pending, [200, { ok: true, status: "allowed", result: { answer: "b" } }]);
  pending = call({ action: "shell", command: "uname" });
  await answerNext({ status: "allowed", by: "owner", result: { exit_code: 0, output: "x".repeat(5000) } });
  const [, shell] = await pending;
  assert.equal(shell.result.output.length, 4096);
  pending = call({ action: "shell", command: "id" });
  await answerNext({ status: "denied", by: "owner", reason: "no" });
  assert.deepEqual(await pending, [200, { ok: false, status: "denied" }]);

  // Pi done: the token is revoked, before the export.
  WaitingVm.gate();
  await running;
  assert.equal((await call({ action: "shell", command: "id" }))[0], 401);
  const audit = fs.readFileSync(path.join(workdir, "audit.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
  const actions = audit.filter((e) => e.event === "action");
  assert.deepEqual(actions.map((e) => [e.action, e.decision, e.by]), [
    ["request_host", "allowed", "guard"], ["request_host", "error", "error"], ["request_host", "denied", "policy"],
    ["git_push", "error", "broker"], ["git_push", "allowed", "owner"], ["request_folder", "allowed", "owner"],
    ["ask_user", "allowed", "owner"], ["shell", "allowed", "owner"], ["shell", "denied", "owner"], [null, "error", "broker"],
  ]);
  assert.ok(actions.every((e) => e.session === "w" && e.time && e.outcome));
  assert.ok(!fs.readFileSync(path.join(workdir, "audit.jsonl"), "utf8").includes(TOKEN));
  fs.rmSync(workdir, { recursive: true, force: true });
});

test("session: a stop revokes the broker's token at once", async () => {
  const { peer } = peerPair();
  const workdir = fs.mkdtempSync(path.join(os.tmpdir(), "sandbox-session-"));
  const session = new Session({ id: "s", task: "t", workdir, stateDir: workdir, guestDir: GUEST, branch: "sandbox/s" },
    { gondolin: {}, peer, env: { HERMES_SANDBOX_TOKEN: TOKEN } });
  const body = { action: "ask_user", question: "q", choices: ["a", "b"] };
  session.stop();
  const response = await brokerResponse(post(body), session.config, session.policy, session.broker);
  assert.equal(response.status, 401);
  fs.rmSync(workdir, { recursive: true, force: true });
});
