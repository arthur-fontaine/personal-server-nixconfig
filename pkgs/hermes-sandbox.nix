# hermes-sandbox (../modules/hermes/coding-agent/sidecar): the Node sidecar
# running one Pi session in a Gondolin microVM, and Pi's tree for that VM
# (../modules/hermes/coding-agent/pi). Both from their pnpm lockfiles:
# Gondolin 0.14.0 for the host, Pi 1.5.0 and pi-advisor-flow 0.14.4 for the
# guest, installed for linux-arm64 (pi/pnpm-workspace.yaml), copied into the
# image with Pi's settings.json, advisor.json and extensions by
# `hermes-sandbox build-image`.
{
  lib,
  stdenvNoCC,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm,
  nodejs_24,
  makeWrapper,
  qemu,
  e2fsprogs,
  lz4,
  cpio,
  coreutils,
  findutils,
  gnutar,
  gzip,
  which,
}:
let
  sidecar = ../modules/hermes/coding-agent/sidecar;
  pi = ../modules/hermes/coding-agent/pi;
  fs = lib.fileset;
  version = "0.1.0";

  # Pi and its extensions as the guest runs them: plain JavaScript, a hoisted
  # node_modules with no symlinks, so postBuild.copy copies files.
  guest = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "hermes-sandbox-guest";
    inherit version;
    src = fs.toSource {
      root = pi;
      fileset = fs.unions (map (f: pi + "/${f}") [ "package.json" "pnpm-lock.yaml" "pnpm-workspace.yaml" "settings.json" "advisor.json" "extensions" ]);
    };
    nativeBuildInputs = [ nodejs_24 pnpmConfigHook pnpm ];
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
      fetcherVersion = 5;
      hash = "sha256-m7CMX+F54L3YI+W5hmdm1hx+IEcF6TyZBFazp5Dq57c=";
    };
    installPhase = ''
      mkdir -p $out
      # Pi's settings and pi-advisor-flow's (the session's agent directory
      # starts from them), and its own extensions (request_host_action, the
      # sandbox_environment prompt section),
      # which the settings load by path, as they do pi-advisor-flow.
      cp -R package.json settings.json advisor.json node_modules extensions $out/
      # Its only symlinks; the guest runs Pi's cli.js by path.
      rm -rf $out/node_modules/.bin
      test -f $out/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js
      test -f $out/extensions/request-host-action/index.js
      test -f $out/extensions/sandbox-environment/index.js
      test -f $out/node_modules/pi-advisor-flow/dist/index.js
    '';
    dontFixup = true;
  });
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "hermes-sandbox";
  inherit version;
  # The coding agent's folder, built in sidecar/: its tests also read
  # ../pi/settings.json and the extensions it names.
  src = fs.toSource {
    root = ../modules/hermes/coding-agent;
    fileset = fs.unions [
      (sidecar + "/package.json") (sidecar + "/pnpm-lock.yaml") (sidecar + "/src") (sidecar + "/test")
      (pi + "/settings.json") (pi + "/advisor.json") (pi + "/pnpm-lock.yaml") (pi + "/extensions")
    ];
  };
  sourceRoot = "source/sidecar";
  nativeBuildInputs = [ nodejs_24 pnpmConfigHook pnpm makeWrapper ];
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src sourceRoot;
    inherit pnpm;
    fetcherVersion = 5;
    hash = "sha256-kRh4qGL0BVf2ksa2Py31jWtotqCauS8kE5rU87H86/Y=";
  };
  doCheck = true;
  checkPhase = ''
    node --test test/*.test.mjs
  '';
  installPhase = ''
    mkdir -p $out/lib/hermes-sandbox $out/bin
    cp -R package.json src node_modules $out/lib/hermes-sandbox/
    # QEMU runs the VM; the rest builds the image (mke2fs, cpio, lz4).
    makeWrapper ${nodejs_24}/bin/node $out/bin/hermes-sandbox \
      --add-flags $out/lib/hermes-sandbox/src/cli.mjs \
      --set HERMES_SANDBOX_GUEST ${guest} \
      --prefix PATH : ${lib.makeBinPath [ qemu e2fsprogs lz4 cpio coreutils findutils gnutar gzip which ]}
  '';
  passthru = { inherit guest; };
  meta.mainProgram = "hermes-sandbox";
})
