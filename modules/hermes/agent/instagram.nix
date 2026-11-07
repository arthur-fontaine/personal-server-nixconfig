# The user's Instagram and Discord, through their websites in Hermes' always-open browser
# (browser.nix; no API exists for a personal account): a skill
# (skills/instagram). The bootstrap has the user log in there once; later
# logins come from 1Password (onepassword.nix), and its notifications become
# events (docs/events.md).
{ config, lib, server, ... }:
let
  on = name: server.hermes.integrations.${name}.enable;
  confirm = import ./skills/confirm.nix { inherit server; };
  # Where its SKILL.md and direct.js land, for the path the skill opens.
  instagramDir = "${config.services.hermes-agent.hermesHome}/skills/social-media/instagram";
in
{
  services.hermes-agent.hermesHomeFiles =
    lib.optionalAttrs (on "instagram") {
      "skills/social-media/instagram/SKILL.md" = builtins.replaceStrings
        [ "@skillDir@" ] [ instagramDir ] (confirm.skill ./skills/instagram/SKILL.md);
      # Read and written in the page itself (skills/instagram/direct.js): the
      # skill loads it into the tab over CDP, so the DM code stays out of the
      # prompt and out of the model's hands.
      "skills/social-media/instagram/direct.js" = ./skills/instagram/direct.js;
    }
    # Discord the same way: discord.com in that browser (docs/hermes.md).
    // lib.optionalAttrs (on "discord") {
      "skills/social-media/discord/SKILL.md" = confirm.skill ./skills/discord/SKILL.md;
    };
}
