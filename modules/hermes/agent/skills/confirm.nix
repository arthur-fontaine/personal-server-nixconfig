# How Hermes gets the user's yes before it acts as them (a send, a post, a
# call), for the skills (@confirm@ in their SKILL.md) and the prompt. Always
# with buttons in Telegram: the auto-review's approval card when it is on
# (agent/guard.nix: a send is high risk, so it always asks, and the card
# shows the action), else the clarify tool's choices, which the Telegram
# adapter renders as buttons (plugins/platforms/telegram/adapter.py,
# send_clarify).
{ server }:
let
  guard = server.hermes.decision.approval.enable;
in
rec {
  rule =
    if guard then
      "Do not ask in a message of your own: the action itself waits for the user's yes on the approval card the auto-review sends to Telegram, which shows it, so put the recipient and the exact text in the command or the tool's arguments, never in a file or a variable."
    else
      "Ask with the `clarify` tool, the action and \"Cancel\" as its choices (\"Send\", \"Change it\", \"Cancel\" for a message), which Telegram shows as buttons, never with a question in your reply.";

  # A skill's SKILL.md, with its @confirm@ filled in.
  skill = path: builtins.replaceStrings [ "@confirm@" ] [ rule ] (builtins.readFile path);
}
