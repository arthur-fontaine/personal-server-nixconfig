"""`/sub`: show and change the policy of the sub-chat it is typed in.

`/sub unlock <passphrase>` never reaches this handler: the pre_gateway_dispatch
hook takes it first, so the passphrase is not stored anywhere.
"""

from __future__ import annotations

from .policy import Chat, Policy, parse_setting, ttl_seconds
from .runtime import Runtime

HELP = """\
/sub                      this sub-chat's policy
/sub presets              the presets and volumes
/sub preset <name>        apply a preset
/sub set <key> <value>    memoryRead|memoryWrite|encrypted on/off, volume <name|none>,
                          tools <a,b|all|none>, ttl <30m|6h|7d|session|none>, model <provider:model|none>
/sub unlock <passphrase>  unlock an encrypted sub-chat
/sub lock                 forget its key
/sub end                  wipe a temporary sub-chat now"""


def describe(policy: Policy) -> str:
    def onoff(b):
        return "on" if b else "off"

    tools = "all" if policy.tools is None else (", ".join(policy.tools) or "none")
    return (
        f"memoryRead {onoff(policy.memoryRead)} · memoryWrite {onoff(policy.memoryWrite)} · "
        f"volume {policy.volume or '(its own)'} · tools {tools} · ttl {policy.ttl or 'permanent'} · "
        f"encrypted {onoff(policy.encrypted)} · model {policy.model or 'main'}"
    )


def current_chat() -> Chat | None:
    try:
        from gateway.session_context import bound_session_key
    except Exception:
        return None
    return Chat.from_session_key(bound_session_key(), None)


class SubCommand:
    def __init__(self, runtime: Runtime):
        self.runtime = runtime

    def __call__(self, raw_args: str = "", **kwargs) -> str:
        return self.run(raw_args, current_chat())

    def run(self, raw_args: str, chat: Chat | None) -> str:
        words = (raw_args or "").split()
        policies = self.runtime.policies
        if words and words[0] in ("help", "-h", "--help"):
            return HELP
        if words and words[0] == "presets":
            lines = [f"• {name}: {describe(p)}" for name, p in sorted(policies.presets.items())]
            volumes = ", ".join(
                f"{n}{' (encrypted)' if v.get('encrypted') else ''}" for n, v in sorted(policies.volumes.items())
            )
            return "\n".join(lines + [f"Volumes: {volumes or 'none'}"])
        if chat is None:
            return "Run /sub in a chat."
        if chat.is_main:
            return ("This is the main chat. A sub-chat is a topic of this chat (Telegram: tap + to create one) "
                    "or a group with the bot: use /sub there.\n\n" + HELP)

        if not words:
            return f"Sub-chat ({policies.preset_name(chat)}): {describe(policies.policy(chat))}\n\n{HELP}"
        command, rest = words[0], words[1:]
        try:
            if command == "preset" and len(rest) == 1:
                policy = policies.set_preset(chat, rest[0])
            elif command == "set" and len(rest) >= 2:
                key = rest[0]
                value = parse_setting(key, " ".join(rest[1:]))
                policy = policies.set(chat, key, value)
            elif command == "lock":
                _, own, _ = self.runtime.chat_volumes(chat)
                self.runtime.lock(own)
                return f"🔒 Locked `{own}`."
            elif command == "end":
                policy = policies.policy(chat)
                if policy.ttl is None:
                    return "This sub-chat is permanent (ttl none); /new starts a fresh session instead."
                self.runtime.wipe_chat(chat)
                return "This sub-chat was wiped."
            else:
                return HELP
        except ValueError as err:
            return f"⚠️ {err}"
        ttl_seconds(policy.ttl)
        self.runtime.apply_model(chat, policy)
        note = ""
        _, own, _ = self.runtime.chat_volumes(chat)
        if self.runtime.is_locked(own, policy):
            note = "\n🔒 Encrypted: send `/sub unlock <passphrase>` (a new passphrase sets it)."
        return f"✅ {describe(policy)}{note}"
