// The sidecar's logic without a VM: the protocol, the network policy, Pi's
// event stream, the image's identity, and a whole session against a fake VM.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { after, test } from "node:test";

import { Peer } from "../src/protocol.mjs";
import { Grants, NetworkPolicy, ambiguousPath, describeRequest, normalizeGrant } from "../src/policy.mjs";
import { PiProgress } from "../src/pi-events.mjs";
import { buildConfig, imageId, ensureImage } from "../src/image.mjs";
import { Session, brokerResponse, piArgv } from "../src/session.mjs";

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
  assert.deepEqual(audit.map((e) => [e.host, e.decision]), [["opencode.ai", "allow"], ["example.com", "deny"]]);
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
  assert.equal(answer.status, 503);
  assert.equal(await brokerResponse(new Request("https://example.com/"), session.config, session.policy), undefined);
  session.policy.revokeGrant("hermes.sandbox");
  assert.equal((await brokerResponse(new Request("https://hermes.sandbox/"), session.config, session.policy)).status, 403);
  assert.ok(!lines.some((l) => l.type === "request"), "never a question about the broker");
  assert.deepEqual(audit().map((e) => [e.host, e.decision]), [["hermes.sandbox", "allow"], ["hermes.sandbox", "deny"]]);
  fs.rmSync(workdir, { recursive: true, force: true });
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

test("pi argv: headless JSON mode, model and thinking, no project config, a task never read as a file", () => {
  const argv = piArgv({ task: "@etc/passwd fix it", model: "opencode-go/deepseek-v4.1-flash", thinking: "high" });
  assert.deepEqual(argv.slice(2, 10), ["--mode", "json", "--print", "--model", "opencode-go/deepseek-v4.1-flash", "--thinking", "high", "--no-approve"]);
  assert.equal(argv.at(-2), "--");
  assert.equal(argv.at(-1), " @etc/passwd fix it");
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
  assert.deepEqual(Object.keys(vm.options.vfs.mounts), ["/workspace"]);
  assert.equal(vm.options.httpHooks.secrets.OPENCODE_API_KEY.value, secret);
  assert.deepEqual(vm.options.httpHooks.secrets.OPENCODE_API_KEY.hosts, ["opencode.ai"]);
  assert.equal((await vm.options.httpHooks.onRequest(new Request("https://hermes.sandbox/x"))).status, 503);
  assert.ok(!JSON.stringify(vm.options.env).includes(secret));
  assert.ok(!JSON.stringify(vm.commands).includes(secret));
  const fetch = vm.commands.find((c) => c.argv.includes("fetch"));
  assert.deepEqual(fetch.argv.slice(-2), ["/tmp/in.bundle", "refs/heads/main"]);
  const pi = vm.commands.find((c) => c.argv[0] === "node");
  assert.equal(pi.options.env.OPENCODE_API_KEY, "PLACEHOLDER");
  assert.ok(pi.argv.includes("opencode-go/deepseek-v4.1-flash"));
  assert.equal(pi.argv[pi.argv.indexOf("--thinking") + 1], "high");
  assert.ok(lines.some((l) => l.type === "done" && l.result.status === "finished"));
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(workdir, "result.json"), "utf8")).commits, 1);
  const audit = fs.readFileSync(path.join(workdir, "audit.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
  assert.deepEqual(audit.map((a) => a.event), ["start", "pi", "end", "network"]);
  assert.ok(!fs.readFileSync(path.join(workdir, "audit.jsonl"), "utf8").includes(secret));
  fs.rmSync(workdir, { recursive: true, force: true });
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
      VM: RefusedVm, MemoryProvider: class {},
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
