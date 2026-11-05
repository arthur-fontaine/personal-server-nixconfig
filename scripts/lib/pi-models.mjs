// Pi's own providers and models, for the bootstrap's coding-agent step,
// read offline from the pi-ai the guest image runs (pkgs/hermes-sandbox.nix,
// its passthru guest): no running Pi, no key, no network.
//
//   node pi-models.mjs <pi-ai dir> providers
//       id<TAB>label<TAB>Pi's key variable<TAB>secrets-file variable<TAB>hosts (comma-separated)
//   node pi-models.mjs <pi-ai dir> models <provider>    its chat model ids, one per line
//   node pi-models.mjs <pi-ai dir> levels <provider> <model>
//       the thinking levels Pi supports for it, one per line (every level for a model
//       the catalog does not know: one typed in)
//
// Only providers a static API key works for: the guest gets a placeholder the
// host swaps for the key, which cannot stand in for a login's refreshing
// token. So no OAuth-only provider, none whose key is not one variable
// (Bedrock's AWS credentials), none whose address must be filled in (Azure,
// Vertex, Cloudflare: "{…}" in their baseUrl), and not GitHub Copilot, whose
// token is exchanged for short-lived ones.

import path from "node:path";
import { pathToFileURL } from "node:url";

const [root, command, ...args] = process.argv.slice(2);
const load = (file) => import(pathToFileURL(path.join(root, "dist", file)).href);
const all = await load("providers/all.js");
const { findEnvKeys } = await load("env-api-keys.js");
const { getSupportedThinkingLevels } = await load("models.js");

const LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const EXCLUDED = new Set(["github-copilot"]);
// Where Hermes keeps a key for the same service under another name
// (hermes-agent's hermes_cli/auth.py), the secrets file has it under Hermes'
// name: one key typed once serves both.
const HERMES_NAMES = { "opencode-go": "OPENCODE_GO_API_KEY", opencode: "OPENCODE_ZEN_API_KEY", google: "GOOGLE_API_KEY" };

// pi-ai's env-api-keys keeps its table private; asking findEnvKeys with an
// environment that has every variable returns the provider's whole list.
const everyVariable = new Proxy({}, { get: () => "set", has: () => true });

function keyVariable(id) {
  const names = findEnvKeys(id, everyVariable) ?? [];
  // Anthropic lists its OAuth and auth tokens first; the API key is the one.
  return names.find((name) => name.endsWith("_API_KEY")) ?? names[0] ?? "";
}

function hostsOf(models) {
  const hosts = new Set();
  for (const model of models) {
    if (!model.baseUrl || model.baseUrl.includes("{")) return null;
    const url = new URL(model.baseUrl);
    if (url.protocol !== "https:") return null;
    hosts.add(url.hostname);
  }
  return hosts.size ? [...hosts] : null;
}

function providers() {
  const rows = [];
  for (const provider of all.builtinProviders()) {
    if (EXCLUDED.has(provider.id) || !provider.auth?.apiKey) continue;
    const variable = keyVariable(provider.id);
    const hosts = hostsOf(all.getBuiltinModels(provider.id));
    if (!variable || !hosts) continue;
    rows.push([provider.id, provider.name, variable, HERMES_NAMES[provider.id] ?? variable, hosts.join(",")]);
  }
  return rows.map((row) => row.join("\t"));
}

function models(provider) {
  return all.getBuiltinModels(provider).map((model) => model.id);
}

function levels(provider, id) {
  const model = all.getBuiltinModels(provider).find((m) => m.id === id);
  return model ? getSupportedThinkingLevels(model) : LEVELS;
}

const commands = { providers, models, levels };
if (!commands[command]) {
  process.stderr.write("usage: pi-models.mjs <pi-ai dir> providers | models <provider> | levels <provider> <model>\n");
  process.exit(2);
}
const lines = commands[command](...args);
if (lines.length) process.stdout.write(lines.join("\n") + "\n");
