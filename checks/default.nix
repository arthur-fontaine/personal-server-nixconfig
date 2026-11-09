# `nix flake check` runs these.
{ inputs, pkgs }:
let
  hermes = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  # The plugins' tests (unii, guard against a fake System One server on
  # loopback, owner_approval, lost_turns against Hermes' own session store,
  # plugin loader and a whole gateway on a fake Telegram, front_desk in Hermes'
  # own agent loop, app_topic against a fake bot and with the real guard), in the interpreter Hermes
  # runs them with.
  unii = pkgs.runCommand "unii-tests" { __darwinAllowLocalNetworking = true; nativeBuildInputs = [ pkgs.git ]; } ''
    cp -R ${../modules/hermes/plugins} plugins
    chmod -R u+w plugins
    # guard's System One client, as agent/guard.nix puts it.
    cp ${../modules/hermes/fast-act/fast_act/decision.py} plugins/guard/systemone.py
    cd plugins
    export HOME=$TMPDIR
    # The sandbox points it at a file it does not have; httpx loads it anyway.
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    # Hermes' strings in every language, as its wrapped binary sets them.
    export HERMES_BUNDLED_LOCALES=${hermes}/share/hermes-agent/locales
    for test in tests/test_*.py; do
      echo "== $test"
      ${hermes.hermesVenv}/bin/python3 -I "$test"
    done
    touch $out
  '';

  # The coding agent's sidecar tests (protocol, network policy, the broker,
  # Pi's events, a session against a fake VM) run in its build.
  sandbox = pkgs.hermes-sandbox;

  # The coding agent's plugin against a fake sidecar, its approvals and its
  # broker actions with a fake guard and owner, in Hermes' interpreter.
  coding-agent = pkgs.runCommand "coding-agent-tests" { nativeBuildInputs = [ pkgs.git ]; } ''
    cp -R ${../modules/hermes/coding-agent} coding-agent
    chmod -R u+w coding-agent
    cd coding-agent
    export HOME=$TMPDIR
    for test in tests/test_*.py; do
      echo "== $test"
      ${hermes.hermesVenv}/bin/python3 -I "$test"
    done
    touch $out
  '';

  # sideload (Xcode builds, .ipa re-signing, limits, refresh, removal) and
  # Hermes' sideload plugin against fake xcrun, xcodebuild, xcodegen,
  # codesign, ditto and security, in Hermes' interpreter; and the declared
  # apps' projects (the Hermes app on) against the build environment sideload
  # gives them.
  sideload = let
    server = (inputs.self.darwinConfigurations.Personal-Server.extendModules {
      modules = [ { server.hermes.app.delivery.enable = true; } ];
    }).config.server;
    apps = pkgs.writeText "sideload-apps.json" (builtins.toJSON (builtins.mapAttrs (_: a: {
      source = toString a.source;
      names = builtins.attrValues a.teamEnv ++ builtins.attrNames (a.secretEnv // a.envCommands // a.env);
    }) server.sideload.apps));
  in pkgs.runCommand "sideload-tests" { SIDELOAD_APPS = apps; __darwinAllowLocalNetworking = true; } ''
    mkdir -p modules/hermes
    cp -R ${../modules/sideload} modules/sideload
    cp -R ${../modules/hermes/plugins} modules/hermes/plugins
    chmod -R u+w modules
    cd modules/sideload
    export HOME=$TMPDIR
    ${hermes.hermesVenv}/bin/python3 -I tests/test_sideload.py
    ${hermes.hermesVenv}/bin/python3 -I tests/test_build_settings.py
    touch $out
  '';

  # The events daemon's tests: fake uzu and Hermes servers on loopback, and
  # Hermes' own signature check.
  events = pkgs.runCommand "hermes-events-tests" { __darwinAllowLocalNetworking = true; } ''
    cp -R ${../modules/hermes/events} events
    chmod -R u+w events
    # The DM script the daemon reads the inbox with, as agent/events.nix puts it.
    cp ${../modules/hermes/agent/skills/instagram/direct.js} events/hermes_events/direct.js
    cd events
    export HOME=$TMPDIR
    ${hermes.hermesVenv}/bin/python3 -I tests/test_events.py
    touch $out
  '';

  # browser_fast_act against a fake System One server and a fake Cua Driver
  # (an MCP server over stdio), in the interpreter Hermes runs it with.
  fast-act = pkgs.runCommand "fast-act-tests" { __darwinAllowLocalNetworking = true; } ''
    cp -R ${../modules/hermes/fast-act} fast-act
    chmod -R u+w fast-act
    cd fast-act
    export HOME=$TMPDIR
    # The sandbox points it at a file it does not have; httpx loads it anyway.
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    ${hermes.hermesVenv}/bin/python3 -I tests/test_fast_act.py
    touch $out
  '';

  # Hermes' local overlay: the checker (each forbidden area refused) and
  # server-rebuild against stub git, darwin-rebuild, curl and sudo.
  overrides = pkgs.runCommand "hermes-overrides-tests" { } ''
    cp -R ${../modules/hermes/system/access/overrides} overrides
    chmod -R u+w overrides
    export HOME=$TMPDIR BASH_BIN=${pkgs.bash}/bin/bash
    ${pkgs.python3}/bin/python3 -I overrides/test_overrides.py
    touch $out
  '';

  # What hermes-freeze picks and its space report; the chown and ACLs
  # themselves need root. hermes-space and its weekly line, on a fake Bot API.
  freeze = pkgs.runCommand "hermes-freeze-tests" { __darwinAllowLocalNetworking = true; } ''
    cp ${../modules/hermes/system/access/freeze.py} freeze.py
    cp ${../modules/hermes/system/access/test_freeze.py} test_freeze.py
    cp ${../modules/hermes/system/access/space.py} space.py
    cp ${../modules/hermes/system/access/test_space.py} test_space.py
    ${pkgs.python3}/bin/python3 -I test_freeze.py
    ${pkgs.python3}/bin/python3 -I test_space.py
    touch $out
  '';

  # The DM script the Instagram skill loads into the page, against stand-ins
  # for the page: the inbox merge, the composer, the send path, no browser.
  instagram = pkgs.runCommand "instagram-script-tests" { } ''
    cp ${../modules/hermes/agent/skills/instagram/direct.js} direct.js
    cp ${../modules/hermes/agent/skills/instagram/direct.test.mjs} direct.test.mjs
    ${pkgs.nodejs}/bin/node direct.test.mjs
    touch $out
  '';
}
