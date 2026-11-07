# unii

A Hermes plugin that makes the Telegram DM with the bot **one chat that never
ends**, and every topic of it, and every group with the bot, a **sub-chat**
with its own rules.

## The single chat

Each message is logged word for word, forever. In the background a cheap model
compresses the log into a binary tree of one-line summaries. Each turn is a
fresh model call that sees the **view** (summary lines covering the whole chat,
recent ones fine and old ones coarse, 64–128 KB), then the new message. The
model `zoom`s into a line when it needs the detail. Hermes' own memory, its
session search and its compaction are switched off: the view replaces them.

| File | Part of the design |
| --- | --- |
| `volume.py` | the log, the tree and the view (§1–3), the merge order (§3.1–3.2) |
| `compactor.py` | building nodes: queue, ruler, retries (§4) |
| `prompts.py` | the compaction prompt and tasks, verbatim (§4–5) |
| `engine.py` | the turn (§6) as a Hermes context engine |
| `refresh.py` | new instructions reach the chat (below) |
| `../../agent/prompt/SOUL.md` | the turn prompt, verbatim (§5) |

Where it departs from the design:

- A compaction's context is the newest 24 KB of the chat's view before the
  node, not a separately merged 16–32 KB view.
- Logs are one file per volume rather than one per day.
- The view is one user message (view, then the turn's state, then the message)
  instead of separate blocks.
- A turn does not wait until the newest lines are built: its first step waits
  a few seconds (`summary_wait_seconds`) for the lines of the messages logged
  since the session's last wait, never for a line whose last build failed, and
  the steps after it not at all. A missing line reads "(not summarized yet:
  zoom it)" until it is built.

Hermes freezes a session's system prompt and tool list at its first turn, and
the single chat is one session that never ends: a new SOUL.md, AGENTS.md or
config.yaml (a toolset, an MCP server) never reached it. When one of them
changed, the plugin's first load in a process clears every open session's
stored prompt and tool list, so Hermes builds both again on the next turn.

## Sub-chats

Every topic of the DM, and every group, group topic or channel with the bot, is
a sub-chat. Its policy comes from a preset (set in Nix,
`server.hermes.subchats.presets`) plus `/sub set` changes:

| Setting | Effect |
| --- | --- |
| `memoryRead` | the main chat's view is shown too, read-only, as `<main>` |
| `memoryWrite` | its messages are also logged into the main chat |
| `volume` | a named volume shared with other sub-chats; none: a private one |
| `tools` | toolsets or tools it may use (`pre_tool_call` blocks the rest) |
| `ttl` | `session`, a duration, or permanent: when it is wiped |
| `encrypted` | AES-256-GCM log, key from `/sub unlock`, transcript scrubbed |
| `model` | `provider:model`, e.g. `uzu:local`, pinned like `/model` |

`/sub` in a sub-chat shows its policy and the commands. In the main chat,
`/sub new [preset] [name]` opens one as a DM topic, which only the bot can
create (`telegram.py`, `createForumTopic`); an expired temporary DM topic, or one
ended with `/sub end`, is deleted (`deleteForumTopic`).

## Sources

Copied or adapted from:

- **UniiChat's design**, Victor Taelin:
  <https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449>
  (`optchat.md`). The prompts in `prompts.py` and `SOUL.md` are its section 5
  verbatim, with Unii renamed Hermes and the paragraph on computers dropped;
  the compaction tasks and the "Too long" retry are its section 4.
- **Taelin's rollback push** (`rollback_state_list.js`, 2022), quoted in the
  gist, section 3.1: the merge order of `Volume.merge`.
- **UniiChat**, <https://github.com/VictorTaelin/UniiChat>, and **OptMem**,
  <https://github.com/VictorTaelin/OptMem>: the implementations the gist
  describes; the "subagents never write memory" rule comes from OptMem's README.
- **Hermes Agent**, at commit
  [`74885f9`](https://github.com/NousResearch/hermes-agent/tree/74885f997bece88c1393bd174b25b32338336cb6):
  the `ContextEngine` contract (`agent/context_engine.py`,
  `website/docs/developer-guide/context-engine-plugin.md`), the hooks
  (`website/docs/user-guide/features/hooks.md`), the session key layout
  (`gateway/session.py`, `build_session_key`), the model override
  (`SessionStore.set_model_override`) and the session database calls
  (`hermes_state_sessions.py`, `hermes_state_messages.py`).

## Tests

```sh
nix build .#checks.aarch64-darwin.unii
```
