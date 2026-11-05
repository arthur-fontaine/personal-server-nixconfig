// One sandboxed Pi session: boot the VM, bring the repository in as a git
// bundle, run Pi headless, bring its branch out as a git bundle, close the VM.
//
// The VM has no host mount: /workspace is a MemoryProvider in this process,
// and files cross only through vm.fs, as git bundles, which carry objects and
// refs, never hooks or config. The guest's environment holds no secret: the
// OpenCode key is a Gondolin secret, a placeholder in the guest that the host
// swaps for the real value in the headers of requests to opencode.ai only.

import fs from "node:fs";
import path from "node:path";

import { NetworkPolicy, describeRequest } from "./policy.mjs";
import { PiProgress } from "./pi-events.mjs";
import { PI_CLI, ensureImage } from "./image.mjs";

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
};

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
    "--", message,
  ];
}

export function guestEnv(secretEnv) {
  return {
    ...secretEnv,
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
export async function bootVm({ gondolin, imageDir, config, key, policy }) {
  const hooks = gondolin.createHttpHooks({
    secrets: { [config.secretName]: { hosts: config.secretHosts, value: key } },
    // Gondolin runs onRequest before isRequestAllowed (and on every
    // redirect hop): the broker's requests are answered here and never
    // leave; any other request passes on to the policy untouched.
    onRequest: (request) => brokerResponse(request, config, policy),
    isRequestAllowed: policy.isRequestAllowed,
  });
  const env = guestEnv(hooks.env);
  const vm = await gondolin.VM.create({
    sandbox: { imagePath: imageDir, ...(config.qemuPath ? { qemuPath: config.qemuPath } : {}) },
    httpHooks: hooks.httpHooks,
    dns: { mode: "synthetic" },
    allowWebSockets: false,
    vfs: { mounts: { "/workspace": new gondolin.MemoryProvider() } },
    env,
    memory: config.memory,
    cpus: config.cpus,
    sessionLabel: `hermes-sandbox ${config.id}`,
  });
  return { vm, env };
}

// The broker's answer. Its actions come in a later stage: until then every
// request to it gets a 503, or a 403 when its grant was revoked.
export async function brokerResponse(request, config, policy) {
  if (describeRequest(request).host !== config.brokerHost) return undefined;
  const allowed = await policy.isRequestAllowed(request);
  return new Response(allowed ? "the Hermes broker is not available yet\n" : "forbidden\n", {
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
    const booted = await bootVm({ gondolin, imageDir: image.dir, config, key, policy: this.policy });
    this.vm = booted.vm;
    const { vm, env } = booted;
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
    this.#checkStopped();

    this.setPhase("pi");
    this.audit({ event: "pi", model: config.model, thinking: config.thinking });
    const pi = await this.#runPi(vm, env);

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
