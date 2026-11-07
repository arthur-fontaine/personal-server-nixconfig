# Services of the user's that Hermes can use, each optional: it needs an
# account there, and acts as the user in it. The bootstrap asks which. Apple's
# apps (iMCP and the Apple skills) are not here: they come with the Mac.
{ lib, ... }:
let
  integration = description: {
    enable = lib.mkEnableOption description;
  };
in
{
  options.server.hermes.integrations = {
    whatsapp = integration ''
      WhatsApp: your messages, read, searched and sent as you (wacli, a linked
      device of your number), and their events'';
    instagram = integration "Instagram: DMs, posts and stories on instagram.com, and its notifications as events";
    discord = integration "Discord: DMs and servers on discord.com, and its notifications as events";
    runpod = integration "RunPod: its MCP server (GPU pods), and pods left running as events";
    github = integration ''
      GitHub notifications as events (with their own classic token). Pushing
      this repository is not an integration: Hermes always may'';
    onepassword = integration ''
      1Password: a service account reading one vault, whose logins Hermes
      fills into web pages without seeing them'';
    homeassistant = integration ''
      Home Assistant: its devices read and controlled (Hermes' official plugin,
      the ha_* tools) and their state changes as events'';
    tinyfish = integration ''
      TinyFish Search as Hermes' web_search (free up to 12,000 searches a
      day, with an API key; reading a page stays on Firecrawl)'';
    homekit = integration ''
      HomeKit: your home's accessories, through HomeClaw (a Mac App Store app
      the bootstrap installs), and their changes as events'';
  };
}
