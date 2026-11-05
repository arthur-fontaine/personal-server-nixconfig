// Hermes' broker, as the guest reaches it: POST https://hermes.sandbox/v1/actions,
// answered by this process (Gondolin's onRequest), never by the network.
//
// Pi asks Hermes for something at its boundary (a host, a folder of this
// Mac, a push, the owner's answer, a command here) with a TYPED action; the
// plugin's approval system decides, as for one of Hermes' own tool calls.
// What comes in is untrusted: a bearer token generated per session (checked
// in constant time, revoked when Pi is done), a small JSON body, and a schema
// per action that rejects any field it does not name. No action has a field
// for Pi's reasons: the action is judged, never Pi's case for it.
//
// What goes back is minimal: {ok, status: allowed|denied|timeout|error,
// result?}, never the reviewer's reasons. A denial (or a timeout) is final
// for the session: the same action asked again gets the same answer, and
// nobody is asked twice.

import crypto from "node:crypto";

import { normalizeGrant } from "./policy.mjs";

export const BROKER_PATH = "/v1/actions";
export const MAX_BODY = 16 * 1024;
// Questions waiting at once for one session; more get a 429.
export const MAX_OPEN = 4;

const HOST = /^(\*\.)?[a-z0-9.-]{1,253}$/i;
const METHOD = /^[A-Za-z]{1,16}$/;
const BRANCH = /^sandbox\/[A-Za-z0-9._\/-]{1,200}$/;
const CONTROL = /[\u0000-\u001f\u007f]/;

export class InvalidAction extends Error {}

function text(value, name, { max, min = 1, line = true } = {}) {
  if (typeof value !== "string") throw new InvalidAction(`${name}: expected a string`);
  if (value.length < min || value.length > max) throw new InvalidAction(`${name}: ${min} to ${max} characters`);
  if (value.includes("\u0000") || (line && CONTROL.test(value))) {
    throw new InvalidAction(`${name}: no control characters`);
  }
  return value;
}

// A branch git would take, under sandbox/.
function branchName(value) {
  const branch = text(value, "branch", { max: 210 });
  if (!BRANCH.test(branch) || branch.includes("..") || branch.includes("//") || branch.endsWith("/") ||
      branch.endsWith(".") || branch.split("/").some((part) => part.startsWith(".") || part.endsWith(".lock"))) {
    throw new InvalidAction("branch: a branch name under sandbox/");
  }
  return branch;
}

// Each action's fields: [name, required, check]. Nothing else is accepted.
export const ACTIONS = {
  request_host: [
    ["host", true, (v) => {
      const host = text(v, "host", { max: 253 });
      if (!HOST.test(host)) throw new InvalidAction("host: a host name");
      return host.toLowerCase().replace(/\.$/, "");
    }],
    ["method", false, (v) => {
      if (!METHOD.test(String(v)) || typeof v !== "string") throw new InvalidAction("method: an HTTP method");
      return v.toUpperCase();
    }],
    ["pathPrefix", false, (v) => text(v, "pathPrefix", { max: 300 })],
  ],
  request_folder: [
    ["path", true, (v) => text(v, "path", { max: 1024 })],
  ],
  git_push: [
    ["branch", true, branchName],
  ],
  ask_user: [
    ["question", true, (v) => text(v, "question", { max: 1000, line: false })],
    ["choices", true, (v) => {
      if (!Array.isArray(v) || v.length < 2 || v.length > 4) throw new InvalidAction("choices: 2 to 4 strings");
      const choices = v.map((c, i) => text(c, `choices[${i}]`, { max: 64 }));
      if (new Set(choices).size !== choices.length) throw new InvalidAction("choices: each one different");
      return choices;
    }],
  ],
  shell: [
    ["command", true, (v) => text(v, "command", { max: 4000, line: false })],
    ["cwd", false, (v) => text(v, "cwd", { max: 1024 })],
  ],
};

// {action, ...fields} -> {action, args}, or InvalidAction.
export function validateAction(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    throw new InvalidAction("expected a JSON object");
  }
  const { action, ...fields } = body;
  if (typeof action !== "string" || !Object.hasOwn(ACTIONS, action)) {
    throw new InvalidAction(`action: one of ${Object.keys(ACTIONS).join(", ")}`);
  }
  const spec = ACTIONS[action];
  const known = new Set(spec.map(([name]) => name));
  const unknown = Object.keys(fields).filter((name) => !known.has(name));
  if (unknown.length) throw new InvalidAction(`unknown field(s) for ${action}: ${unknown.join(", ")}`);
  const args = {};
  for (const [name, required, check] of spec) {
    if (fields[name] === undefined || fields[name] === null) {
      if (required) throw new InvalidAction(`${name}: required for ${action}`);
      continue;
    }
    args[name] = check(fields[name]);
  }
  if (action === "request_host") {
    try {
      const grant = normalizeGrant(args);
      args.host = grant.host;
    } catch (error) {
      throw new InvalidAction(error.message);
    }
  }
  return { action, args };
}

function digest(value) {
  return crypto.createHash("sha256").update(String(value)).digest();
}

const STATUSES = new Set(["allowed", "denied", "timeout", "error"]);

function reply(httpStatus, status, result) {
  return new Response(JSON.stringify({ ok: status === "allowed", status, ...(result ? { result } : {}) }) + "\n", {
    status: httpStatus,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

async function readBody(request, max) {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export class Broker {
  // perform: async (action, args) => {status, result?, by, reason?, outcome?}
  // audit: (entry) => void, one line per call.
  constructor({ token, perform, audit = () => {}, maxBody = MAX_BODY, maxOpen = MAX_OPEN }) {
    if (typeof token !== "string" || token.length < 16) throw new Error("the broker needs a token");
    this.tokenDigest = digest(token);
    this.perform = perform;
    this.audit = audit;
    this.maxBody = maxBody;
    this.maxOpen = maxOpen;
    this.open = 0;
    this.revoked = false;
    // action and arguments -> the final answer (denied, timeout).
    this.final = new Map();
  }

  revoke() {
    this.revoked = true;
  }

  #authorized(request) {
    if (this.revoked) return false;
    const header = request.headers.get("authorization") ?? "";
    const match = /^Bearer ([A-Za-z0-9_\-.~+/=]{1,512})$/.exec(header);
    // Digests have one length, so the comparison's time says nothing.
    return crypto.timingSafeEqual(digest(match ? match[1] : ""), this.tokenDigest) && match !== null;
  }

  #refuse(httpStatus, outcome, error, action = null) {
    this.audit({ event: "action", action, decision: "error", by: "broker", outcome });
    return reply(httpStatus, "error", error ? { error } : undefined);
  }

  async handle(request) {
    const url = new URL(request.url);
    if (url.pathname !== BROKER_PATH) return this.#refuse(404, "404: not the broker's path", "not found");
    if (request.method !== "POST") return this.#refuse(405, "405: not a POST", "POST only");
    if (!this.#authorized(request)) return this.#refuse(401, "401: no valid token", "unauthorized");
    const type = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
    if (type !== "application/json") return this.#refuse(415, "415: not JSON", "application/json only");
    const raw = await readBody(request, this.maxBody);
    if (raw === null) return this.#refuse(413, "413: body too large", `at most ${this.maxBody} bytes`);
    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      return this.#refuse(400, "400: not JSON", "the body is not JSON");
    }
    let action;
    try {
      action = validateAction(body);
    } catch (error) {
      if (!(error instanceof InvalidAction)) throw error;
      const name = typeof body?.action === "string" && body.action.length <= 32 ? body.action : null;
      return this.#refuse(400, "400: invalid action", error.message, name);
    }
    const key = JSON.stringify([action.action, action.args]);
    const final = this.final.get(key);
    if (final) {
      this.audit({ event: "action", ...action, decision: final, by: "final", outcome: "refused again, without asking" });
      return reply(200, final);
    }
    if (this.open >= this.maxOpen) {
      this.audit({ event: "action", ...action, decision: "error", by: "broker", outcome: "429: too many at once" });
      return reply(429, "error", { error: `at most ${this.maxOpen} actions at once` });
    }
    this.open += 1;
    let answer;
    try {
      answer = await this.perform(action.action, action.args);
    } catch (error) {
      answer = { status: "error", by: "error", reason: String(error?.message ?? error).slice(0, 300) };
    } finally {
      this.open -= 1;
    }
    const status = STATUSES.has(answer?.status) ? answer.status : "error";
    // Revoked while it waited (Pi done, the session stopped): nothing more
    // reaches the guest, whatever was decided.
    if (this.revoked) {
      this.audit({ event: "action", ...action, decision: status, by: answer?.by ?? "approval",
        outcome: "the session ended first", ...(answer?.reason ? { reason: answer.reason } : {}) });
      return reply(401, "error", { error: "unauthorized" });
    }
    if (status === "denied" || status === "timeout") this.final.set(key, status);
    this.audit({
      event: "action",
      ...action,
      decision: status,
      by: answer?.by ?? "approval",
      outcome: answer?.outcome ?? status,
      ...(answer?.reason ? { reason: String(answer.reason).slice(0, 500) } : {}),
    });
    return reply(200, status, status === "allowed" || status === "error" ? answer?.result : undefined);
  }
}
