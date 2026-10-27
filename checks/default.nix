# `nix flake check` runs these.
{ inputs, pkgs }:
let
  hermes = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  # The unii plugin's tests, in the interpreter Hermes runs it with.
  unii = pkgs.runCommand "unii-tests" { } ''
    cp -R ${../modules/hermes/plugins} plugins
    chmod -R u+w plugins
    cd plugins
    export HOME=$TMPDIR
    for test in tests/test_*.py; do
      echo "== $test"
      ${hermes.hermesVenv}/bin/python3 -I "$test"
    done
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
