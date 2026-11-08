# Hermes ships skills for services that need an account, a key or an app
# (server.hermes.disabledSkills lists those missing here). Disabled, it does
# not read them, so it does not offer what this server cannot do.
{ lib, pkgs, server, ... }:
let
  local = server.hermes.localOverrides.overlay.skills or { };
in
{
  # One definition: settings merges attribute sets, not lists. The local
  # overlay (./overrides.nix) turns skills off, or back on.
  services.hermes-agent.settings.skills.disabled = lib.subtractLists (local.enable or [ ])
    (lib.unique (server.hermes.disabledSkills ++ (local.disable or [ ])))
    # Its computer-use skill teaches the computer_use tool and forbids the
    # driver's own tools by name: off while Hermes uses those
    # (./computer-use.nix).
    ++ lib.optional (!(pkgs.cua-driver.hermesComputerUse or true)) "computer-use";
}
