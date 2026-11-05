// One sandboxed Pi session: boot the VM, bring the repository in as a git
// bundle, run Pi headless, bring its branch out as a git bundle, close the VM.
//
// The VM has no host mount: /workspace is a MemoryProvider in this process,
// and files cross only through vm.fs, as git bundles, which carry objects and
// refs, never hooks or config. The guest's environment holds no secret: the
// OpenCode key is a Gondolin secret, a placeholder in the guest that the host
// swaps for the real value in the headers of requests to opencode.ai only.
// The guest does get one value of its own: the broker's token, which only
// this process checks (broker.mjs), and which stops working when Pi is done.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import { BROKER_PATH, Broker } from "./broker.mjs";
import { copyFolder } from "./folders.mjs";
import { NetworkPolicy, describeRequest, normalizeGrant, unaskable } from "./policy.mjs";
import { PiProgress } from "./pi-events.mjs";
import { PI_CLI, PI_DIR, ensureImage } from "./image.mjs";

const REPO = "/workspace/repo";
const GIT = ["git", "-c", "safe.directory=*", "-c", "core.hooksPath=/dev/null", "-C", REPO];
const STDERR_TAIL = 4000;

export const DEFAULTS = {
  model: "opencode-go/deepseek-v4.1-flash",
  // The model takes off, high or max; medium would be clamped to high.
  thinking: "high",
  memory: "3G",
  cpus: 2,
  timeoutSeconds: 7200,
  secretName: "OPENCODE_API_KEY",
  keyEnv: "OPENCODE_GO_API_KEY",
  grants: ["opencode.ai"],
  secretHosts: ["opencode.ai"],
  // Hermes' broker, as the guest names it: answered by this process, never
  // looked up nor reached anywhere (brokerResponse). Always in the grants.
  brokerHost: "hermes.sandbox",
  // How long a question about a host may wait for Hermes' answer (its
  // approval system has its own, shorter timeout; this is the backstop).
  approvalTimeoutSeconds: 300,
  // The broker's actions wait for the owner, then may run (a push, a
  // command): their backstop is longer.
  actionTimeoutSeconds: 900,
};

// What the guest is given to reach the broker; the token comes from the
// plugin (HERMES_SANDBOX_TOKEN), a new one per session.
export const BROKER_ENV = { url: "HERMES_BROKER_URL", token: "HERMES_BROKER_TOKEN" };
// Pi's side of the broker (guest/extensions), loaded explicitly: the
// repository's own .pi/ stays ignored.
export const BROKER_EXTENSION = `${PI_DIR}/extensions/request-host-action/index.js`;
// Folders of this Mac Pi asked for and Hermes gave: read-only copies.
export const HOST_FILES = "/host";

export function piArgv({ task, model, thinking }) {
  // Pi reads a leading @ as a file to attach.
  const message = task.startsWith("@") ? ` ${task}` : task;
  return [
    "node", PI_CLI,
    "--mode", "json", "--print",
    "--model", model, "--thinking", thinking,
    // The repository is the task's subject, not configuration: its .pi/
    // settings and extensions are ignored.
    "--no-approve",
    "--extension", BROKER_EXTENSION,
    "--", message,
  ];
}

export function guestEnv(secretEnv, broker = null) {
  return {
    ...secretEnv,
    ...(broker ? { [BROKER_ENV.url]: broker.url, [BROKER_ENV.token]: broker.token } : {}),
    HOME: "/root",
    PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    // Gondolin's TLS interception CA; Node trusts only its own bundle.
    NODE_EXTRA_CA_CERTS: "/etc/gondolin/mitm/ca.crt",
    PI_OFFLINE: "1",
    PI_SKIP_VERSION_CHECK: "1",
    PI_TELEMETRY: "0",
    GIT_AUTHOR_NAME: "Pi (sandbox)",
    GIT_AUTHOR_EMAIL: "pi@sandbox.invalid",
    GIT_COMMITTER_NAME: "Pi (sandbox)",
    GIT_COMMITTER_EMAIL: "pi@sandbox.invalid",
  };
}

// The VM and the guest's environment. Shared by sessions and the smoke test,
// so the smoke test checks what a session gets.
export async function bootVm({ gondolin, imageDir, config, key, policy, broker = null, hostFiles = null }) {
  const hooks = gondolin.createHttpHooks({
    secrets: { [config.secretName]: { hosts: config.secretHosts, value: key } },
    // Gondolin runs onRequest before isRequestAllowed (and on every
    // redirect hop): the broker's requests are answered here and never
    // leave; any other request passes on to the policy untouched.
    onRequest: (request) => brokerResponse(request, config, policy, broker),
    isRequestAllowed: policy.isRequestAllowed,
  });
  const env = guestEnv(hooks.env, broker ? { url: `https://${config.brokerHost}${BROKER_PATH}`, token: broker.token } : null);
  const mounts = { "/workspace": new gondolin.MemoryProvider() };
  // Filled while the VM runs (request_folder); the guest only reads it.
  if (hostFiles) mounts[HOST_FILES] = new gondolin.ReadonlyProvider(hostFiles);
  const vm = await gondolin.VM.create({
    sandbox: { imagePath: imageDir, ...(config.qemuPath ? { qemuPath: config.qemuPath } : {}) },
    httpHooks: hooks.httpHooks,
    dns: { mode: "synthetic" },
    allowWebSockets: false,
    vfs: { mounts },
    env,
    memory: config.memory,
    cpus: config.cpus,
    sessionLabel: `hermes-sandbox ${config.id}`,
  });
  return { vm, env };
}

// The broker's answer (broker.mjs), or a 403 when its grant was revoked, or
// a 503 when this VM has no broker.
export async function brokerResponse(request, config, policy, broker = null) {
  // The audit line is the policy's (by "grant" or "policy"); the broker's
  // own lines say what came of the action.
  if (describeRequest(request).host !== config.brokerHost) return undefined;
  const allowed = await policy.isRequestAllowed(request);
  if (allowed && broker) return broker.handler.handle(request);
  return new Response(allowed ? "the Hermes broker is not available\n" : "forbidden\n", {
    status: allowed ? 503 : 403,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

async function run(vm, argv, options = {}) {
  const result = await vm.exec(argv, options);
  if (result.exitCode !== 0) {
    throw new Error(`${argv.slice(0, 6).join(" ")}: exit ${result.exitCode}: ${result.stderr.trim().slice(-500)}`);
  }
  return result.stdout.trim();
}

export class Session {
  constructor(config, { gondolin, peer, env = process.env, now = () => Date.now() }) {
    this.config = { ...DEFAULTS, ...config };
    this.gondolin = gondolin;
    this.peer = peer;
    this.env = env;
    this.now = now;
    this.abort = new AbortController();
    this.stopReason = null;
    this.progress = new PiProgress();
    this.phase = "starting";
    this.vm = null;
    this.auditPath = path.join(this.config.workdir, "audit.jsonl");
    this.policy = new NetworkPolicy({
      grants: [...this.config.grants, this.config.brokerHost],
      // Never a question about the broker: it is Hermes itself.
      localHosts: [this.config.brokerHost],
      audit: (entry) => this.audit(entry),
      // Pi asks Hermes for access: its approval system decides (the
      // plugin's approval.py), and the answer may add a grant.
      approve: (what) => this.peer.request("network", { ...what, session: this.config.id }, {
        timeoutMs: (this.config.approvalTimeoutSeconds + 60) * 1000,
      }),
      onGrants: (grants) => this.peer.send("grants", { grants }),
    });
    // The broker's token: the plugin's (secrets.token_urlsafe, per session),
    // or one of its own when run without the plugin.
    const token = this.env.HERMES_SANDBOX_TOKEN || crypto.randomBytes(32).toString("base64url");
    this.broker = {
      token,
      handler: new Broker({ token, perform: (action, args) => this.#perform(action, args), audit: (e) => this.audit(e) }),
    };
    this.hostFiles = null;
    this.guestEnv = null;
    this.base = null;
    this.pushes = 0;
  }

  audit(entry) {
    const line = JSON.stringify({ time: new Date(this.now()).toISOString(), session: this.config.id, ...entry });
    fs.appendFileSync(this.auditPath, line + "\n", { mode: 0o600 });
  }

  setPhase(phase) {
    this.phase = phase;
    this.peer.send("phase", { phase });
  }

  stop(reason = "stopped") {
    if (this.stopReason) return;
    this.stopReason = reason;
    this.broker.handler.revoke();
    this.abort.abort();
  }

  async run() {
    const { config } = this;
    fs.mkdirSync(config.workdir, { recursive: true, mode: 0o700 });
    const started = this.now();
    const timer = setTimeout(() => this.stop("timeout"), config.timeoutSeconds * 1000);
    let result;
    try {
      result = await this.#run();
    } catch (error) {
      result = { status: this.stopReason ?? "failed", error: String(error?.message ?? error).slice(0, 2000) };
    } finally {
      clearTimeout(timer);
      this.broker.handler.revoke();
      if (this.vm) {
        this.setPhase("closing");
        await this.vm.close().catch(() => {});
      }
    }
    result = {
      id: config.id,
      ...result,
      progress: this.progress.snapshot(),
      summary: this.progress.lastText,
      seconds: Math.round((this.now() - started) / 1000),
    };
    fs.writeFileSync(path.join(config.workdir, "result.json"), JSON.stringify(result, null, 2), { mode: 0o600 });
    this.audit({ event: "end", status: result.status });
    this.peer.send("done", { result });
    return result;
  }

  async #run() {
    const { config, gondolin } = this;
    const key = this.env[config.keyEnv];
    if (!key) throw new Error(`${config.keyEnv} is not set: the OpenCode Go key, in the secrets file`);
    this.audit({ event: "start", grants: this.policy.grants.list() });
    this.peer.send("grants", { grants: this.policy.grants.list() });

    this.setPhase("image");
    const image = await ensureImage({
      stateDir: config.stateDir,
      guestDir: config.guestDir,
      buildAssets: gondolin.buildAssets,
      verifyAssets: gondolin.verifyAssets,
      log: (message) => this.peer.send("log", { level: "info", message }),
    });
    this.#checkStopped();

    this.setPhase("boot");
    this.hostFiles = new gondolin.MemoryProvider();
    const booted = await bootVm({
      gondolin, imageDir: image.dir, config, key, policy: this.policy, broker: this.broker, hostFiles: this.hostFiles,
    });
    this.vm = booted.vm;
    const { vm, env } = booted;
    this.guestEnv = env;
    this.#checkStopped();

    this.setPhase("repo");
    let base = null;
    if (config.bundleIn) {
      await vm.fs.writeFile("/tmp/in.bundle", fs.readFileSync(config.bundleIn));
    }
    // Pi's branch starts at the bundle's one ref (bundleRef, from
    // `git bundle list-heads`), with no remote pointing back anywhere.
    await run(vm, ["mkdir", "-p", REPO], { env });
    await run(vm, [...GIT, "init", "--quiet", "-b", config.branch], { env });
    if (config.bundleIn) {
      await run(vm, [...GIT, "fetch", "--quiet", "/tmp/in.bundle", config.bundleRef], { env });
      await run(vm, [...GIT, "reset", "--quiet", "--hard", "FETCH_HEAD"], { env });
      base = await run(vm, [...GIT, "rev-parse", "HEAD"], { env });
    }
    this.base = base;
    this.#checkStopped();

    this.setPhase("pi");
    this.audit({ event: "pi", model: config.model, thinking: config.thinking });
    const pi = await this.#runPi(vm, env);
    // Pi is done: nothing in the guest may ask Hermes for anything now.
    this.broker.handler.revoke();

    this.setPhase("export");
    const out = await this.#export(vm, env, base);
    // Pi exits 0 even when its model refused every call (a bad key, a
    // limit): an answer that ended in an error is a failure.
    const modelFailed = this.progress.lastStopReason === "error";
    const status = this.stopReason
      ?? (pi.exitCode === 0 && !this.progress.aborted && !modelFailed ? "finished" : "failed");
    const error = pi.exitCode !== 0 ? pi.stderr : modelFailed ? this.progress.errors.at(-1) : null;
    return {
      status,
      exit_code: pi.exitCode,
      ...(error ? { error } : {}),
      ...out,
    };
  }

  // One broker action, once its token and schema passed (broker.mjs):
  // what the plugin's approval system decides, and what comes of it here.
  // Returns {status, result?, by, reason?, outcome?}.
  async #perform(action, args) {
    if (action === "request_host") return this.#requestHost(args);
    if (action === "git_push") return this.#gitPush(args);
    if (action === "request_folder") return this.#requestFolder(args);
    const answer = await this.#ask(action, args);
    if (answer.status !== "allowed") return answer;
    if (action === "ask_user") {
      const choice = answer.result?.answer;
      if (!args.choices.includes(choice)) return { ...answer, status: "error", result: undefined, outcome: "a bad answer" };
      return { ...answer, result: { answer: choice }, outcome: "answered" };
    }
    if (action === "shell") {
      const r = answer.result ?? {};
      const result = {
        exit_code: Number.isInteger(r.exit_code) ? r.exit_code : null,
        ...(r.timed_out ? { timed_out: true } : {}),
        output: String(r.output ?? "").slice(0, 4096),
      };
      return { ...answer, result, outcome: r.timed_out ? "ran, timed out" : `ran, exit ${result.exit_code}` };
    }
    return { status: "error", by: "broker", reason: `no such action ${action}` };
  }

  // The plugin's answer: {status, by, reason, result?, grant?, folder?}.
  async #ask(action, args, extra = {}) {
    let answer;
    try {
      answer = await this.peer.request("action", { ...extra, session: this.config.id, action, args }, {
        timeoutMs: this.config.actionTimeoutSeconds * 1000,
      });
    } catch (error) {
      return { status: "error", by: "error", reason: `no answer: ${error.message}` };
    }
    const status = ["allowed", "denied", "timeout", "error"].includes(answer?.status) ? answer.status : "error";
    return {
      status,
      by: typeof answer?.by === "string" ? answer.by : "approval",
      reason: typeof answer?.reason === "string" ? answer.reason.slice(0, 500) : "",
      result: answer?.result && typeof answer.result === "object" ? answer.result : undefined,
      grant: answer?.grant,
      folder: answer?.folder,
      outcome: typeof answer?.outcome === "string" ? answer.outcome.slice(0, 200) : undefined,
    };
  }

  async #requestHost(args) {
    const grant = normalizeGrant(args);
    const bare = grant.host.replace(/^\*\./, "");
    if (unaskable(bare) || this.policy.localHosts.has(bare)) {
      return { status: "denied", by: "policy", reason: "not a host name to ask about", outcome: "refused" };
    }
    const same = JSON.stringify(grant);
    if (this.policy.grants.list().some((g) => JSON.stringify(g) === same)) {
      return { status: "allowed", by: "grant", outcome: "already granted", result: { grant } };
    }
    const answer = await this.#ask("request_host", grant);
    if (answer.status !== "allowed") return { ...answer, result: undefined };
    // Hermes grants what was asked, nothing wider.
    let given;
    try {
      given = normalizeGrant(answer.grant ?? {});
    } catch {
      given = null;
    }
    if (!given || JSON.stringify(given) !== same) {
      return { status: "error", by: "error", reason: "the answer granted something else", outcome: "nothing granted" };
    }
    this.policy.addGrant(given);
    return { ...answer, result: { grant: given }, outcome: "granted for the session" };
  }

  async #gitPush({ branch }) {
    const vm = this.vm;
    if (!vm || this.phase !== "pi") {
      return { status: "error", by: "broker", outcome: "not now", result: { error: "the session is not running Pi" } };
    }
    const env = this.guestEnv;
    const ref = `refs/heads/${branch}`;
    const exists = await vm.exec([...GIT, "rev-parse", "--verify", "--quiet", `${ref}^{commit}`], { env });
    if (exists.exitCode !== 0) {
      return { status: "error", by: "broker", outcome: "no such branch", result: { error: "no such branch in /workspace/repo" } };
    }
    // The branch leaves the VM as a bundle, as at the end of a session; the
    // plugin pushes it from the review clone, never from the guest.
    const name = `push-${++this.pushes}.bundle`;
    const hostPath = path.join(this.config.workdir, name);
    try {
      await run(vm, [...GIT, "bundle", "create", "--quiet", `/tmp/${name}`, ref], { env });
      fs.writeFileSync(hostPath, await vm.fs.readFile(`/tmp/${name}`), { mode: 0o600 });
      await vm.exec(["rm", "-f", `/tmp/${name}`], { env }).catch(() => {});
      const answer = await this.#ask("git_push", { branch }, { bundle: name, base: this.base });
      if (answer.status !== "allowed") return answer;
      return { ...answer, result: { pushed: branch }, outcome: answer.outcome ?? "pushed" };
    } finally {
      fs.rmSync(hostPath, { force: true });
    }
  }

  async #requestFolder(args) {
    const answer = await this.#ask("request_folder", args);
    if (answer.status !== "allowed") return answer;
    const source = answer.folder?.path;
    if (typeof source !== "string" || !this.hostFiles) {
      return { status: "error", by: "error", reason: "no folder to copy", outcome: "nothing copied" };
    }
    try {
      const copied = copyFolder(source, this.hostFiles);
      return {
        ...answer,
        result: { path: `${HOST_FILES}/${copied.name}`, files: copied.files, ...(copied.skipped ? { skipped: copied.skipped } : {}) },
        outcome: `copied ${copied.files} file(s) to ${HOST_FILES}/${copied.name}`,
      };
    } catch (error) {
      return {
        status: "error", by: answer.by, reason: answer.reason, outcome: `not copied: ${error.message}`,
        result: { error: error.name === "FolderTooLarge" ? `too large: ${error.message}` : "the folder could not be copied" },
      };
    }
  }

  #checkStopped() {
    if (this.stopReason) throw new Error(this.stopReason);
  }

  async #runPi(vm, env) {
    const { config } = this;
    const proc = vm.exec(piArgv(config), {
      cwd: REPO,
      env,
      stdout: "pipe",
      stderr: "pipe",
      signal: this.abort.signal,
    });
    let stderr = "";
    let lastProgress = 0;
    try {
      for await (const chunk of proc.output()) {
        if (chunk.stream === "stderr") {
          stderr = (stderr + chunk.text).slice(-STDERR_TAIL);
          continue;
        }
        const events = this.progress.push(chunk.text);
        const now = this.now();
        if (events.some((event) => event.type === "turn_end" || event.type === "tool_execution_start") &&
            now - lastProgress > 2000) {
          lastProgress = now;
          this.peer.send("progress", this.progress.snapshot());
        }
      }
      const result = await proc;
      return { exitCode: result.exitCode, stderr: stderr.trim() };
    } catch (error) {
      if (this.stopReason) return { exitCode: -1, stderr: stderr.trim() };
      throw error;
    }
  }

  // Pi's work as one branch: what it left uncommitted becomes a last commit.
  // The bundle holds the whole branch, base included, so the review clone
  // needs nothing else.
  async #export(vm, env, base) {
    const { config } = this;
    const status = await run(vm, [...GIT, "status", "--porcelain"], { env });
    if (status) {
      await run(vm, [...GIT, "add", "-A"], { env });
      await run(vm, [...GIT, "commit", "--quiet", "--no-verify", "-m", "sandbox: uncommitted changes"], { env });
    }
    const head = await vm.exec([...GIT, "rev-parse", "--verify", "--quiet", "HEAD"], { env });
    if (head.exitCode !== 0) return { branch: config.branch, base, head: null, commits: 0, bundle: null };
    const headSha = head.stdout.trim();
    const range = base ? `${base}..${config.branch}` : config.branch;
    const commits = Number(await run(vm, [...GIT, "rev-list", "--count", range], { env }));
    if (commits === 0) return { branch: config.branch, base, head: headSha, commits, bundle: null };
    await run(vm, [...GIT, "bundle", "create", "--quiet", "/tmp/out.bundle", config.branch], { env });
    const bundle = path.join(config.workdir, "out.bundle");
    fs.writeFileSync(bundle, await vm.fs.readFile("/tmp/out.bundle"), { mode: 0o600 });
    return { branch: config.branch, base, head: headSha, commits, bundle };
  }
}
