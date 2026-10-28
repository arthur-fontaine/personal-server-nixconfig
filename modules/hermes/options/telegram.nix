{ lib, ... }:
{
  imports = [
    (lib.mkRemovedOptionModule [ "server" "hermes" "telegram" "mainTopic" ] ''
      The root of your DM with the bot is the main chat now, and its topics are
      sub-chats the bot creates with `/sub new <name>`. Remove mainTopic from
      hosts/local.nix, and in BotFather's Mini App switch "Disallow users to
      create new threads" on.
    '')
  ];
}
