# Hermes ships skills for services that need an account, a key or an app
# (server.hermes.disabledSkills lists those missing here). Disabled, it does
# not read them, so it does not offer what this server cannot do.
{ server, ... }:
{
  services.hermes-agent.settings.skills.disabled = server.hermes.disabledSkills;
}
