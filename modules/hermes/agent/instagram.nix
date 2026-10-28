# The user's Instagram, through instagram.com in Hermes' always-open browser
# (browser.nix; no API exists for a personal account): a skill
# (skills/instagram). The bootstrap has the user log in there once; later
# logins come from 1Password (onepassword.nix), and its notifications become
# events (docs/events.md).
{
  services.hermes-agent.hermesHomeFiles."skills/social-media/instagram/SKILL.md" = ./skills/instagram/SKILL.md;
}
