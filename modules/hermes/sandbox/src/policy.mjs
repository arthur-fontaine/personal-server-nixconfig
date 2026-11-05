// The guest's network policy: a mutable set of grants, checked on every HTTP
// request the guest makes (Gondolin's isRequestAllowed, which sees the method,
// URL and headers, never the body). createHttpHooks freezes its own
// allowedHosts, so it is left at its "*" default and every decision is made
// here, where grants can be added while the VM runs.
//
// A grant is { host, method?, pathPrefix? }: host is exact ("opencode.ai") or
// a wildcard of subdomains ("*.example.com", not example.com itself); no
// method means any method, no pathPrefix any path. Stage 1 only has the
// static grants; stage 2 sets `approve`, an async callback asking Hermes
// about what no grant covers, whose answer may add a grant for the session.
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

export class NetworkPolicy {
  constructor({ grants = [], audit = () => {}, approve = null } = {}) {
    this.grants = grants instanceof Grants ? grants : new Grants(grants);
    this.audit = audit;
    // async ({host, method, path, scheme}) => { allow: bool, grant?: Grant }
    this.approve = approve;
    this.isRequestAllowed = this.isRequestAllowed.bind(this);
  }

  async isRequestAllowed(request) {
    const what = describeRequest(request);
    if (!what.host || (what.scheme !== "https" && what.scheme !== "http")) {
      this.audit({ event: "network", decision: "deny", reason: "malformed", ...what });
      return false;
    }
    const grant = this.grants.covers(what);
    if (grant) {
      this.audit({ event: "network", decision: "allow", reason: "grant", ...what });
      return true;
    }
    if (!this.approve) {
      this.audit({ event: "network", decision: "deny", reason: "no grant", ...what });
      return false;
    }
    let answer;
    try {
      answer = await this.approve(what);
    } catch (error) {
      this.audit({ event: "network", decision: "deny", reason: `approval failed: ${error.message}`, ...what });
      return false;
    }
    const allow = answer?.allow === true;
    if (allow && answer.grant) {
      try {
        this.grants.add(answer.grant);
      } catch (error) {
        this.audit({ event: "network", decision: "deny", reason: error.message, ...what });
        return false;
      }
    }
    this.audit({ event: "network", decision: allow ? "allow" : "deny", reason: "approval", ...what });
    return allow;
  }
}
