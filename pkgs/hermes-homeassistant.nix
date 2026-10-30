# Hermes' official Home Assistant plugin (the ha_* tools and a gateway
# platform), pinned here rather than installed by Hermes from its catalog at
# runtime: https://github.com/NousResearch/hermes-official-plugins/tree/main/homeassistant
{ runCommand, fetchzip }:
let
  rev = "0d9a9a75d76fc6d0bc2ec3ad70b2cdbf3e38ce27";
  source = fetchzip {
    url = "https://github.com/NousResearch/hermes-official-plugins/archive/${rev}.tar.gz";
    hash = "sha256-xFdd5ShnZ/9jxZgqFwzto2QQ3pYWQpvUnKuBwwcSIHU=";
  };
in
runCommand "homeassistant" { } ''
  cp -R ${source}/homeassistant $out
  chmod -R u+w $out
  rm -rf $out/tests
  # It requires Hermes >= 0.21.5, which the pinned one is (v2026.9.24), but
  # Hermes' Nix build stamps itself 0.0.0 (nix/hermes-agent.nix, `version ?
  # "0.0.0"`), so the gate (hermes_cli/plugins_manifest.py) skipped it.
  sed -i '/^requires_hermes:/d' $out/plugin.yaml
''
