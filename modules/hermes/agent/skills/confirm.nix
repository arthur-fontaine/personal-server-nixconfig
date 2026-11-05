# How Hermes gets the user's yes before it acts as them (a send, a post, a
# call), for the skills (@confirm@ in their SKILL.md) and the prompt: guard's
# approval card in Telegram, with buttons (agent/guard.nix: a send is high
# risk, so the auto-review always asks, and without a decision model guard
# asks for every action; the card shows the action). Asking with clarify
# first would ask twice.
{ server }:
rec {
  rule = "Do not ask in a message of your own: the action itself waits for the user's yes on the approval card the auto-review sends to Telegram, which shows it, so put the recipient and the exact text in the command or the tool's arguments, never in a file or a variable.";

  # A skill's SKILL.md, with its @confirm@ filled in.
  skill = path: builtins.replaceStrings [ "@confirm@" ] [ rule ] (builtins.readFile path);
}
