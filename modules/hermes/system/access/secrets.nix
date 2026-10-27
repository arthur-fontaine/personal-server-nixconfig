# The API keys live in one dotenv file outside the Nix store, readable by the
# Hermes account only. It is created by hand (MANUAL_SETUP.md); activation
# only fixes its ownership.
{ config, lib, ... }:
let
  cfg = config.server.hermes;
  file = lib.escapeShellArg cfg.secretsFile;
  dir = lib.escapeShellArg (builtins.dirOf cfg.secretsFile);
in
{
  system.activationScripts.postActivation.text = lib.mkBefore ''
    mkdir -p ${dir}
    chown root:wheel ${dir}
    chmod 755 ${dir}
    if [ -e ${file} ]; then
      chown ${cfg.user}:${cfg.user} ${file}
      chmod 400 ${file}
    else
      echo "warning: ${cfg.secretsFile} is missing; Hermes has no API keys (see MANUAL_SETUP.md)" >&2
    fi
  '';
}
