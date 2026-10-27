# Hermes' WhatsApp (Baileys) bridge with its node_modules, so the gateway never
# runs `npm install` at start. The stamp is the check the adapter makes
# (plugins/platforms/whatsapp/adapter.py, _ensure_bridge_deps).
{ buildNpmPackage, hermes-agent-src, nodejs }:
buildNpmPackage {
  pname = "hermes-whatsapp-bridge";
  version = "1.0.0";
  src = "${hermes-agent-src}/scripts/whatsapp-bridge";
  inherit nodejs;

  npmDepsHash = "sha256-yXk6VO4w3h6WN8B+pwYkWejcgX+pjj1HE9f6xINaFpA=";
  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -R . $out/
    sha256sum package.json | cut -c1-16 > $out/node_modules/.hermes-pkg-hash
    runHook postInstall
  '';
}
