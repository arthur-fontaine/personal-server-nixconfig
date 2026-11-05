// sandbox-environment: tells Pi where it runs, as a <sandbox_environment>
// section of its system prompt. Without it Pi only learns of its walls from
// request_host_action's description, and meets a 403 as a network fault to
// debug.
//
// Ours rather than <agentDir>/APPEND_SYSTEM.md: a trusted project's
// .pi/APPEND_SYSTEM.md replaces that file (Pi's docs/configuration.md), and
// the repository is untrusted content. The section is rendered from the
// facts the session writes (<agentDir>/sandbox.json: its branch, its initial
// grants), so it never claims a host or a branch the session does not have.
// No facts file (Pi started outside a session), no section.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const SECTION = "sandbox_environment";
export const FACTS = "sandbox.json";

// What request_host_action may ask for: the broker's actions
// (sidecar/src/broker.mjs ACTIONS; its tests keep the two lists equal).
export const ACTIONS = {
  request_host: "a network host for this session (narrowest method and pathPrefix you need)",
  request_folder: "a read-only copy of a host folder, under /host/<name>",
  git_push: "push your branch to the repository's origin",
  ask_user: "a question for the user, with 2 to 4 choices",
  shell: "a command on the HOST, run only if the user says yes; never for what you can do in this VM",
};

function grantText(grant) {
  if (typeof grant === "string") return grant;
  const scope = [grant.method, grant.pathPrefix].filter(Boolean).join(" ");
  return scope ? `${grant.host} (${scope} only)` : grant.host;
}

export function renderEnvironment({ repo, branch, hosts = [], broker, hostFiles }) {
  const granted = [...hosts.map(grantText), ...(broker ? [`${broker} (Hermes' broker)`] : [])];
  return [
    "You run headless in an isolated Linux VM that Hermes, the user's assistant, started for one task. No human",
    "watches this session or answers your messages.",
    "",
    "Work",
    `- The repository is ${repo}, on branch ${branch}. Commit your work there: your committed branch is the result,`,
    "  and Hermes shows the user its diff.",
    `- No files of the host machine are here. If you need a folder of it, ask for it: it arrives read-only under ${hostFiles}/<name>.`,
    "- No secrets exist in this VM: do not look for credentials. The model's key is handled outside it.",
    "",
    "Network",
    `- Only the hosts granted for this session answer. At the start: ${granted.join(", ") || "none"}.`,
    "- Any other request is paused while Hermes decides, then answered. A \"403 Forbidden: not granted for this sandbox",
    "  session…\", a \"403 Forbidden: blocked by policy…\" or a plain 403 from a host not granted means NOT GRANTED. It is",
    "  not a network fault: do not retry, change proxies, DNS or curl flags, or debug it. Ask once with",
    "  request_host_action (request_host, with the narrowest method and pathPrefix); if denied, work without it.",
    "- Package registries (npm, PyPI, crates.io, GitHub) are blocked until granted: prefer what is already installed,",
    "  and ask once for the registry's host only if you really need it.",
    "- A denial or a timeout is final for this session. A request that stays blocked a long time may be the user deciding.",
    "",
    "request_host_action asks Hermes for one of these, one per call:",
    ...Object.entries(ACTIONS).map(([action, what]) => `- ${action}: ${what}`),
    "",
    "Finish with a short summary of what you did and what is left.",
  ].join("\n");
}

export function readFacts(agentDir = process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), ".pi", "agent")) {
  try {
    return JSON.parse(fs.readFileSync(path.join(agentDir, FACTS), "utf8"));
  } catch {
    return null;
  }
}

export default function (pi) {
  const facts = readFacts();
  if (!facts) return;
  const text = renderEnvironment(facts);
  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.sections[SECTION] = text;
  });
}
