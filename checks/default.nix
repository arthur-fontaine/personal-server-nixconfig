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
}
