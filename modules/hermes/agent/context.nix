# How much of the conversation goes to the model on each step.
#
# A turn is one model call per tool call, and each call re-sends the prompt:
# a week-old conversation reached ~62k tokens per step, and a step took 24 to
# 31 s on a model whose fresh sessions answer in 3 to 6 s. The tokens are
# cached, so they are cheap, but they are not free to prefill — that ratio is
# prefill time, not thinking.
#
# What makes a prompt that large is tool output: a `cua` script, a terminal
# dump, a whole skill. The prune below replaces old oversized results with
# their summary deterministically (no model call), leaves the newest
# `protect_last_n` messages byte-exact, and only commits a pass when it
# reclaims enough to be worth the prompt cache it breaks.
# https://hermes-agent.nousresearch.com/docs/user-guide/configuration#context-compression
{ ... }:
{
  services.hermes-agent.settings.compression = {
    # Off by default in Hermes ("try 48000"): that is above the size this chat
    # already reaches with a handful of tool calls, so it never fires here.
    proactive_prune_tokens = 24000;
    # Anything smaller is worth keeping: a 4 KB command output is a fact, a
    # 10 KB cua script result is a page of scrollback nobody rereads.
    proactive_prune_min_result_chars = 4000;
    proactive_prune_min_reclaim_tokens = 4096;
    # The tail was the prompt: the last 20 messages held several 10 KB tool
    # results each, so protecting all of them protected the whole problem.
    # Ten still covers the step in flight and its results.
    protect_last_n = 10;
  };
}
