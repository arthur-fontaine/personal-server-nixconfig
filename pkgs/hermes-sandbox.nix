# hermes-sandbox (../modules/hermes/sandbox): the Node sidecar running one Pi
# session in a Gondolin microVM, and Pi's tree for that VM. Both from their
# pnpm lockfiles: Gondolin 0.14.0 for the host, Pi 1.5.0 for the guest,
# installed for linux-arm64 (guest/pnpm-workspace.yaml), copied into the
# image by `hermes-sandbox build-image`.
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
  root = ../modules/hermes/sandbox;
  fs = lib.fileset;
  version = "0.1.0";

  # Pi and its extensions as the guest runs them: plain JavaScript, a hoisted
  # node_modules with no symlinks, so postBuild.copy copies files.
  guest = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "hermes-sandbox-guest";
    inherit version;
    src = fs.toSource {
      root = root + "/guest";
      fileset = fs.unions (map (f: root + "/guest/${f}") [ "package.json" "pnpm-lock.yaml" "pnpm-workspace.yaml" "extensions" ]);
    };
    nativeBuildInputs = [ nodejs_24 pnpmConfigHook pnpm ];
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
      fetcherVersion = 5;
      hash = "sha256-1PKKMY/2chkim5HwQ0BzQnRbfxZq231EeSaS5gu04Go=";
    };
    installPhase = ''
      mkdir -p $out
      # Pi's own extensions (request_host_action), loaded by path.
      cp -R package.json node_modules extensions $out/
      # Its only symlinks; the guest runs Pi's cli.js by path.
      rm -rf $out/node_modules/.bin
      test -f $out/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js
      test -f $out/extensions/request-host-action/index.js
    '';
    dontFixup = true;
  });
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "hermes-sandbox";
  inherit version;
  src = fs.toSource {
    inherit root;
    fileset = fs.unions [ (root + "/package.json") (root + "/pnpm-lock.yaml") (root + "/src") (root + "/test") ];
  };
  nativeBuildInputs = [ nodejs_24 pnpmConfigHook pnpm makeWrapper ];
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
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
