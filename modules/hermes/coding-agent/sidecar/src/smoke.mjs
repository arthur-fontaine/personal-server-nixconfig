// `hermes-sandbox smoke`: boots the guest as a session would, with a made-up
// key, and checks what the isolation promises: the guest's environment holds
// the placeholder, never the key; a host without a grant gets our 403; the
// granted one goes through; the broker answers on the host, only with the
// session's token, and not once it is revoked; Pi's environment section
// renders from a session's facts; Pi starts. Needs network for the image build and
// the granted request, not a real key.

import crypto from "node:crypto";

import { Broker } from "./broker.mjs";
import { NetworkPolicy } from "./policy.mjs";
import { DEFAULTS, REFUSED, bootVm, piFacts } from "./session.mjs";
import { PI_CLI, PI_DIR, ensureImage } from "./image.mjs";

const FETCH = `fetch(process.argv[1]).then((r) => console.log(r.status), (e) => console.log("error " + (e.cause?.code ?? e.message)))`;
const FETCH_TEXT = `fetch(process.argv[1]).then(async (r) => console.log(r.status, (await r.text()).trim()), (e) => console.log("error " + e.message))`;
// The prompt section Pi gets: its extension, as the image has it, from a session's facts.
const ENVIRONMENT = `import("${PI_DIR}/extensions/sandbox-environment/index.js").then((m) => {
  const handlers = []; process.env.PI_CODING_AGENT_DIR = process.argv[1]; m.default({ on: (e, h) => handlers.push(h) });
  const event = { systemPromptOptions: { sections: {} } }; handlers.forEach((h) => h(event));
  console.log(event.systemPromptOptions.sections[m.SECTION] ?? "none") }, (e) => console.log("error " + e.message))`;
// POSTs an action to the broker: with the guest's token, or none ("-").
const ACTION = `const [url, token, body] = process.argv.slice(1);
fetch(url, { method: "POST", body, headers: { "content-type": "application/json",
  ...(token === "-" ? {} : { authorization: "Bearer " + process.env[token] }) } })
  .then(async (r) => console.log(r.status, (await r.json()).status), (e) => console.log("error " + e.message))`;

export async function smoke({ gondolin, stateDir, guestDir, log = (line) => process.stdout.write(`${line}\n`) }) {
  const config = { ...DEFAULTS, id: "smoke", memory: "1G" };
  const key = `smoke-${crypto.randomBytes(12).toString("hex")}`;
  const audit = [];
  const policy = new NetworkPolicy({
    grants: [...config.grants, config.brokerHost],
    localHosts: [config.brokerHost],
    audit: (entry) => audit.push(entry),
  });
  const image = await ensureImage({
    stateDir, guestDir,
    buildAssets: gondolin.buildAssets, verifyAssets: gondolin.verifyAssets,
    log: (line) => process.stderr.write(`${line}\n`),
  });
  const token = crypto.randomBytes(32).toString("base64url");
  const broker = {
    token,
    // No Hermes here: every action is refused, as a timeout would.
    handler: new Broker({ token, perform: async () => ({ status: "denied", by: "smoke" }), audit: (e) => audit.push(e) }),
  };
  const { vm, env } = await bootVm({ gondolin, imageDir: image.dir, config, key, policy, broker });
  let ok = true;
  const check = (name, pass, detail) => {
    ok &&= pass;
    log(`${pass ? "ok  " : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
  };
  try {
    const printed = (await vm.exec(["sh", "-c", `printenv ${config.secretName}`], { env })).stdout.trim();
    check("the guest sees a placeholder", printed !== "" && printed !== key && printed === env[config.secretName]);
    const all = (await vm.exec(["sh", "-c", "env; cat /proc/1/environ 2>/dev/null"], { env })).stdout;
    check("the key is nowhere in the guest's environment", !all.includes(key));
    const denied = (await vm.exec(["node", "-e", FETCH_TEXT, "https://example.com/"], { env })).stdout.trim();
    check("a host without a grant gets 403, saying what to do", denied === `403 ${REFUSED.trim()}`, denied);
    const allowed = (await vm.exec(["node", "-e", FETCH, "https://opencode.ai/"], { env })).stdout.trim();
    check("opencode.ai goes through", /^\d+$/.test(allowed) && allowed !== "403", allowed);
    const url = `https://${config.brokerHost}/v1/actions`;
    const post = async (tokenVar, body) =>
      (await vm.exec(["node", "-e", ACTION, url, tokenVar, JSON.stringify(body)], { env })).stdout.trim();
    const action = { action: "ask_user", question: "smoke?", choices: ["yes", "no"] };
    const anonymous = await post("-", action);
    check("the broker refuses a call without its token", anonymous === "401 error", anonymous);
    const answered = await post("HERMES_BROKER_TOKEN", action);
    check("the broker answers the session's token", answered === "200 denied", answered);
    const invalid = await post("HERMES_BROKER_TOKEN", { ...action, justification: "trust me" });
    check("the broker rejects an unknown field", invalid === "400 error", invalid);
    broker.handler.revoke();
    const revoked = await post("HERMES_BROKER_TOKEN", action);
    check("a revoked token gets 401", revoked === "401 error", revoked);
    await vm.exec(["mkdir", "-p", "/tmp/agent"], { env });
    await vm.fs.writeFile("/tmp/agent/sandbox.json", JSON.stringify(piFacts({ ...config, branch: "sandbox/smoke" })));
    const section = (await vm.exec(["node", "-e", ENVIRONMENT, "/tmp/agent"], { env })).stdout.trim();
    check("Pi's environment section renders in the guest", section.includes("on branch sandbox/smoke") &&
      section.includes(config.grants[0]), section.slice(0, 200));
    const version = await vm.exec(["node", PI_CLI, "--version"], { env });
    check("Pi starts", version.exitCode === 0, version.stdout.trim() || version.stderr.trim().slice(-200));
    check("the policy logged both decisions",
      audit.some((e) => e.request?.host === "example.com" && e.decision === "deny") &&
      audit.some((e) => e.request?.host === "opencode.ai" && e.decision === "allow"));
    check("the guest gets the broker's address and its token",
      env.HERMES_BROKER_TOKEN === token && env.HERMES_BROKER_URL === url);
  } finally {
    await vm.close();
  }
  return ok;
}
