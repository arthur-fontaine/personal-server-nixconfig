// The guest's network policy: a mutable set of grants, checked on every HTTP
// request the guest makes (Gondolin's isRequestAllowed, which sees the method,
// URL and headers, never the body). createHttpHooks freezes its own
// allowedHosts, so it is left at its "*" default and every decision is made
// here, where grants can be added while the VM runs.
//
// A grant is { host, method?, pathPrefix? }: host is exact ("opencode.ai") or
// a wildcard of subdomains ("*.example.com", not example.com itself); no
// method means any method, no pathPrefix any path. What no grant covers goes
// to `approve`, an async callback: Pi asks Hermes for access, and Hermes'
// approval system decides (allow once, allow with a grant for the session,
// or refuse). Requests to a host already asked about wait for that answer.
//
// Paths are compared as the URL parser leaves them: dot segments resolved,
// a backslash turned into "/", everything else still percent-encoded. Never decoded:
// /repos/a%2F..%2Fb decoded would pass for a path under /repos/a while the
// server reads another. A path still holding an encoded "/", backslash or "." (or
// a dot segment, which the parser should already have resolved) is matched
// by no path grant: only a grant for the whole host, or a question, lets it
// through.

export function normalizeGrant(grant) {
  if (typeof grant === "string") grant = { host: grant };
  const host = String(grant?.host ?? "").trim().toLowerCase().replace(/\.$/, "");
  if (!host || !/^(\*\.)?[a-z0-9.-]+$/.test(host) || host.includes("..")) {
    throw new Error(`invalid grant host: ${JSON.stringify(grant?.host)}`);
  }
  const method = grant.method ? String(grant.method).toUpperCase() : null;
  if (method !== null && !/^[A-Z]+$/.test(method)) throw new Error(`invalid grant method: ${grant.method}`);
  const pathPrefix = grant.pathPrefix ? String(grant.pathPrefix) : null;
  if (pathPrefix !== null && (!pathPrefix.startsWith("/") || canonicalPath(pathPrefix) !== pathPrefix ||
      ambiguousPath(pathPrefix))) {
    throw new Error(`invalid grant path: ${pathPrefix}`);
  }
  return { host, method, pathPrefix };
}

function canonicalPath(path) {
  try {
    return new URL(path, "http://h").pathname;
  } catch {
    return null;
  }
}

// What a server may read as another path than the one a prefix was checked
// against.
export function ambiguousPath(path) {
  return /%(2f|5c|2e)/i.test(path) || path.includes("\\") ||
    path.split("/").some((segment) => segment === "." || segment === "..");
}

function hostMatches(pattern, host) {
  if (pattern.startsWith("*.")) return host.endsWith(pattern.slice(1));
  return host === pattern;
}

// A path prefix matches on segment boundaries: /repos/a covers /repos/a and
// /repos/a/x, not /repos/ab.
function pathMatches(prefix, path) {
  if (prefix === null) return true;
  if (ambiguousPath(path)) return false;
  if (path === prefix) return true;
  const base = prefix.endsWith("/") ? prefix : prefix + "/";
  return path.startsWith(base);
}

export class Grants {
  constructor(initial = []) {
    this.entries = [];
    for (const grant of initial) this.add(grant);
  }

  add(grant) {
    const normalized = normalizeGrant(grant);
    const key = JSON.stringify(normalized);
    if (!this.entries.some((entry) => JSON.stringify(entry) === key)) this.entries.push(normalized);
    return normalized;
  }

  revoke(grant) {
    const key = JSON.stringify(normalizeGrant(grant));
    const before = this.entries.length;
    this.entries = this.entries.filter((entry) => JSON.stringify(entry) !== key);
    return this.entries.length !== before;
  }

  list() {
    return this.entries.map((entry) => ({ ...entry }));
  }

  covers({ host, method, path }) {
    return this.entries.find((entry) =>
      hostMatches(entry.host, host) &&
      (entry.method === null || entry.method === method) &&
      pathMatches(entry.pathPrefix, path)) ?? null;
  }
}

// What a request is, for a decision and the audit log: never its headers
// (they carry the secrets' placeholders) nor its query (it may carry data).
export function describeRequest(request) {
  let url;
  try {
    url = new URL(request.url);
  } catch {
    return { host: "", method: String(request.method ?? "").toUpperCase(), path: "", scheme: "" };
  }
  return {
    host: url.hostname.toLowerCase().replace(/\.$/, ""),
    method: String(request.method ?? "GET").toUpperCase(),
    // As parsed, never decoded (see the top of this file).
    path: url.pathname,
    scheme: url.protocol.replace(/:$/, ""),
  };
}

// Hosts never worth a question: an address or a single label is no name the
// owner can judge, and Pi's work needs names (the image itself needs no host
// but the granted ones: Pi runs offline, its telemetry and update check off).
export function unaskable(host) {
  return !host.includes(".") || /^[0-9.]+$/.test(host) || host.startsWith("[") || host.endsWith(".localhost") ||
    host.endsWith(".local") || host.endsWith(".internal");
}

const DENIED = { allow: false };

export class NetworkPolicy {
  constructor({ grants = [], audit = () => {}, approve = null, onGrants = () => {}, localHosts = [] } = {}) {
    this.grants = grants instanceof Grants ? grants : new Grants(grants);
    this.audit = audit;
    // async ({host, method, path, scheme, ambiguous}) =>
    //   { allow: bool, grant?: Grant, by?: string, reason?: string }
    this.approve = approve;
    this.onGrants = onGrants;
    // Answered on the host (the broker): allowed by a grant or refused,
    // never asked about.
    this.localHosts = new Set(localHosts.map((host) => host.toLowerCase()));
    // host -> the pending question's answer: one question per host at a time.
    this.asking = new Map();
    this.isRequestAllowed = this.isRequestAllowed.bind(this);
  }

  addGrant(grant) {
    const added = this.grants.add(grant);
    this.onGrants(this.grants.list());
    return added;
  }

  revokeGrant(grant) {
    const removed = this.grants.revoke(grant);
    if (removed) this.onGrants(this.grants.list());
    return removed;
  }

  #log(what, decision, by, reason) {
    this.audit({ event: "network", decision, by, reason, ...what });
    return decision === "allow";
  }

  async isRequestAllowed(request) {
    const what = describeRequest(request);
    if (!what.host || (what.scheme !== "https" && what.scheme !== "http")) {
      return this.#log(what, "deny", "policy", "malformed");
    }
    what.ambiguous = ambiguousPath(what.path);
    // Requests to a host already being asked about wait for that answer
    // (Pi often fires several at once): one question, not one per request.
    for (;;) {
      if (this.grants.covers(what)) return this.#log(what, "allow", "grant", "covered");
      const pending = this.asking.get(what.host);
      if (!pending) break;
      const answer = await pending;
      if (!answer.allow) return this.#log(what, "deny", answer.by ?? "approval", "the question it waited on was refused");
      if (!answer.grant && answer.method === what.method && answer.path === what.path) {
        return this.#log(what, "allow", answer.by ?? "approval", "the same request, allowed once");
      }
      // Allowed with a grant (checked again above) or once for another
      // request: this one gets its own question.
    }
    if (!this.approve) return this.#log(what, "deny", "policy", "no grant");
    if (this.localHosts.has(what.host)) return this.#log(what, "deny", "policy", "Hermes' own host, not granted");
    if (unaskable(what.host)) return this.#log(what, "deny", "policy", "not a host name to ask about");
    const question = this.#ask(what);
    this.asking.set(what.host, question);
    let answer;
    try {
      answer = await question;
    } finally {
      this.asking.delete(what.host);
    }
    return this.#log(what, answer.allow ? "allow" : "deny", answer.by ?? "approval", answer.reason ?? "");
  }

  // Never rejects: a failure is a refusal.
  async #ask(what) {
    let answer;
    try {
      answer = await this.approve({ ...what });
    } catch (error) {
      return { ...DENIED, by: "error", reason: `approval failed: ${error.message}` };
    }
    const out = {
      allow: answer?.allow === true,
      by: typeof answer?.by === "string" ? answer.by : "approval",
      reason: typeof answer?.reason === "string" ? answer.reason.slice(0, 500) : "",
      method: what.method,
      path: what.path,
      grant: null,
    };
    if (out.allow && answer.grant) {
      try {
        out.grant = this.addGrant(answer.grant);
      } catch (error) {
        return { ...DENIED, by: out.by, reason: error.message };
      }
    }
    return out;
  }
}
