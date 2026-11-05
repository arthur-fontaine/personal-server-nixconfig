# The user's Instagram and Discord, through their websites in Hermes' always-open browser
# (browser.nix; no API exists for a personal account): a skill
# (skills/instagram). The bootstrap has the user log in there once; later
# logins come from 1Password (onepassword.nix), and its notifications become
# events (docs/events.md).
{ lib, server, ... }:
let
  on = name: server.hermes.integrations.${name}.enable;
  confirm = import ./skills/confirm.nix { inherit server; };
in
{
  services.hermes-agent.hermesHomeFiles =
    lib.optionalAttrs (on "instagram") {
      "skills/social-media/instagram/SKILL.md" = confirm.skill ./skills/instagram/SKILL.md;
    }
    # Discord the same way: discord.com in that browser (docs/hermes.md).
    // lib.optionalAttrs (on "discord") {
      "skills/social-media/discord/SKILL.md" = confirm.skill ./skills/discord/SKILL.md;
    };
}
