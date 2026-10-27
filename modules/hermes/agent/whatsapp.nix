# WhatsApp through Hermes' Baileys bridge, in bot mode: the server has its own
# number, the owner's DM is the main chat and each group with the bot is a
# sub-chat. The owner's number (WHATSAPP_ALLOWED_USERS) is a secret, in the
# secrets file. Pairing is a one-time QR scan (MANUAL_SETUP.md).
{ pkgs, ... }:
{
  services.hermes-agent = {
    environment = {
      WHATSAPP_ENABLED = "true";
      WHATSAPP_MODE = "bot";
      # Groups the owner creates with the bot are sub-chats; the sender is
      # still checked against WHATSAPP_ALLOWED_USERS.
      WHATSAPP_GROUP_POLICY = "open";
    };

    settings = {
      whatsapp = {
        unauthorized_dm_behavior = "ignore";
        reply_prefix = "";
      };
      # The bridge comes prebuilt from Nix (pkgs/whatsapp-bridge.nix).
      platforms.whatsapp.extra.bridge_script = "${pkgs.hermes-whatsapp-bridge}/bridge.js";
    };
  };
}
