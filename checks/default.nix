# `nix flake check` runs these.
{ inputs, pkgs }:
let
  hermes = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  # The plugins' tests (unii, guard against a fake System One server on
  # loopback), in the interpreter Hermes runs them with.
  unii = pkgs.runCommand "unii-tests" { __darwinAllowLocalNetworking = true; } ''
    cp -R ${../modules/hermes/plugins} plugins
    chmod -R u+w plugins
    # guard's System One client, as agent/guard.nix puts it.
    cp ${../modules/hermes/fast-act/fast_act/decision.py} plugins/guard/systemone.py
    cd plugins
    export HOME=$TMPDIR
    # The sandbox points it at a file it does not have; httpx loads it anyway.
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    for test in tests/test_*.py; do
      echo "== $test"
      ${hermes.hermesVenv}/bin/python3 -I "$test"
    done
    touch $out
  '';

  # The events daemon's tests: fake uzu and Hermes servers on loopback, and
  # Hermes' own signature check.
  events = pkgs.runCommand "hermes-events-tests" { __darwinAllowLocalNetworking = true; } ''
    cp -R ${../modules/hermes/events} events
    chmod -R u+w events
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

  # What hermes-freeze picks; the chown and ACLs themselves need root.
  freeze = pkgs.runCommand "hermes-freeze-tests" { } ''
    cp ${../modules/hermes/system/access/freeze.py} freeze.py
    cp ${../modules/hermes/system/access/test_freeze.py} test_freeze.py
    ${pkgs.python3}/bin/python3 -I test_freeze.py
    touch $out
  '';
}
