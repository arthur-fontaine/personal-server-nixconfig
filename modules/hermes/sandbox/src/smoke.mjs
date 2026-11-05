// `hermes-sandbox smoke`: boots the guest as a session would, with a made-up
// key, and checks what the isolation promises: the guest's environment holds
// the placeholder, never the key; a host without a grant gets 403; the
// granted one goes through; Pi starts. Needs network for the image build and
// the granted request, not a real key.

import crypto from "node:crypto";

import { NetworkPolicy } from "./policy.mjs";
import { DEFAULTS, bootVm } from "./session.mjs";
import { PI_CLI, ensureImage } from "./image.mjs";

const FETCH = `fetch(process.argv[1]).then((r) => console.log(r.status), (e) => console.log("error " + (e.cause?.code ?? e.message)))`;

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
  const { vm, env } = await bootVm({ gondolin, imageDir: image.dir, config, key, policy });
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
    const denied = (await vm.exec(["node", "-e", FETCH, "https://example.com/"], { env })).stdout.trim();
    check("a host without a grant gets 403", denied === "403", denied);
    const allowed = (await vm.exec(["node", "-e", FETCH, "https://opencode.ai/"], { env })).stdout.trim();
    check("opencode.ai goes through", /^\d+$/.test(allowed) && allowed !== "403", allowed);
    const broker = (await vm.exec(["node", "-e", FETCH, `https://${config.brokerHost}/v1/actions`], { env })).stdout.trim();
    check("the broker host is answered on the host", broker === "503", broker);
    const version = await vm.exec(["node", PI_CLI, "--version"], { env });
    check("Pi starts", version.exitCode === 0, version.stdout.trim() || version.stderr.trim().slice(-200));
    check("the policy logged both decisions",
      audit.some((e) => e.request.host === "example.com" && e.decision === "deny") &&
      audit.some((e) => e.request.host === "opencode.ai" && e.decision === "allow"));
  } finally {
    await vm.close();
  }
  return ok;
}
