"""guard: Hermes' permission system, Claude Code's auto mode
(``permissions.defaultMode: "auto"``), ported from Arthur's Pi extension
auto-mode (nixconfig, modules/home/programs/pi/extensions/auto-mode).

Two modes (``permission_mode()``; ``/mode auto|ask`` or
``set_permission_mode`` change it at runtime, kept in ``guard/mode.json``):

- auto: plainly safe calls run directly (fastpath.py: tools that only look,
  edits inside the working directory, Claude Code's Bash read-only check and
  acceptEdits file commands); every other call is judged by the classifier
  (classifier.py) on the conversation and the call, with Claude Code's own
  rules (prompts/, verbatim or compact to fit the model, budget.py, plus the
  owner's ``autoMode``-style lists). A
  risky call is blocked and the model told why; after 3 blocks in a row or 20
  in a session the owner is asked instead, on Hermes' approval card
  (Telegram buttons). The classifier unavailable or unreadable: blocked,
  fail closed.
- ask: every call but those that only look asks the owner; no model call.

The classifier is the configured decision model
(server.hermes.decision.approval): Hermes is not on the Claude subscription
the Pi extension uses. Without one, auto mode asks the owner for every call
the fast paths do not clear (fail closed).

Which turns are the owner's: a turn from a platform only the owner writes in
(config.json's trusted_platforms; Telegram admits only its owner) and not one
the gateway injected itself (a background process, a watch pattern, a
delegation finishing). Those, the events daemon's or a webhook's turns, and
any text relayed into a trusted chat as a user-role row (a webhook delivery,
a cron delivery or a proposal mirrored there, transcript.RELAYED) reach the
classifier as notifications, never as the user speaking: a mirror can quote a
stranger. A subagent's classifier reads its parent's conversation.

computer_use asks the same gate itself for every click; this review replaces
that question by granting its key for the session first (tools/approval.py,
approve_session): one action, one question at most.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import subprocess
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# Which texts are never the owner's: the gateway's notices and what is
# relayed into a chat (mirrors), in transcript.py.
from .transcript import FOOTER, HEADERS, RELAYED, internal  # noqa: E402,F401

PERMISSION_MODES = ("auto", "ask")
MODE_LABELS = {
    "auto": ("Auto", "Safe actions run; the rest are checked by the review model, risky ones blocked; you are asked "
                     "after repeated blocks."),
    "ask": ("Ask", "Every action but reads asks you first."),
}

# The approval card shows its reason in 500 characters
# (plugins/platforms/telegram/adapter.py, _EA_REASON_BUDGET): the action
# goes in the reason, short enough that the card always fits.
CARD_ACTION = 300
# The request's budget (server.hermes.permissions.autoMode.maxPromptTokens),
# for mammoth-27b's 16k with margin.
DEFAULT_MAX_PROMPT_TOKENS = 14000
CARD_SUMMARY = 140
CARD_ACTION_UNDER_SUMMARY = 240
# What the card said, keyed by its text: the App topic shows the summary
# apart (card_summary).
SUMMARIES: "dict[str, str]" = {}
MAX_SUMMARIES = 64


def steered_text(content: str) -> str:
    """The owner's words in a steer row: inside Hermes' marker, after the
    gateway's origin preamble (gateway/run_busy.py, _steer_text_with_origin)."""
    try:
        from agent.prompt_builder import STEER_MARKER_CLOSE, STEER_MARKER_OPEN
    except ImportError:
        return ""
    start, end = content.find(STEER_MARKER_OPEN), content.rfind(STEER_MARKER_CLOSE)
    if start < 0 or end < start:
        return ""
    text = content[start + len(STEER_MARKER_OPEN):end].strip()
    if text.startswith("Gateway message origin") and "\n\n" in text:
        text = text.split("\n\n", 1)[1].strip()
    return text


def summary(tool_name: str, args: dict, limit: int = CARD_ACTION) -> str:
    """What the action does, for the owner's eyes: a command as is, other
    arguments as key: value, credentials masked."""
    args = args or {}
    if set(args) == {"command"} or (tool_name == "terminal" and "command" in args):
        text = str(args["command"])
    else:
        text = "; ".join(f"{k}: {v if isinstance(v, str) else json.dumps(v, ensure_ascii=False, default=str)}"
                         for k, v in args.items())
    try:
        from agent.redact import redact_sensitive_text

        text = redact_sensitive_text(text, force=True)
    except Exception:
        pass
    text = " ".join(text.split())
    return f"{tool_name}: {text[:limit] + '…' if len(text) > limit else text}"


def card_summary(description: str) -> "str | None":
    """The plain-language summary leading an approval card guard wrote, given
    the card's description (Hermes' pre_approval_request hook passes it)."""
    return SUMMARIES.get(description)


def _with_summary(message: str, text: str) -> str:
    if not text:
        return message
    card = f"{text}\n\n{message}"
    SUMMARIES[card] = text
    while len(SUMMARIES) > MAX_SUMMARIES:
        SUMMARIES.pop(next(iter(SUMMARIES)))
    return card


def command_summary(command: str) -> str:
    """A command's plain-language title for its card (titles.py), "" when none."""
    try:
        from . import titles

        return titles.title(command)
    except Exception:  # noqa: BLE001 - the card goes out without it
        logger.warning("guard: no summary for the command", exc_info=True)
        return ""


@dataclass
class Session:
    history: list = field(default_factory=list)  # the last request's messages
    platform: str = ""
    calls: list = field(default_factory=list)  # call lines of the response being run
    parent: str = ""
    subagent: bool = False
    turn_from_user: bool = False
    messages: list = field(default_factory=list)  # the owner's words, for the sandbox
    denials: object = None
    lock: threading.Lock = field(default_factory=threading.Lock)


@dataclass(frozen=True)
class Verdict:
    """review_action's answer (the sandbox reads run, reason, risk)."""
    run: bool
    reason: str
    risk: str = "unknown"


def _computer_use_keys(args: dict) -> list:
    action = str(args.get("action") or "")
    scopes = [action]
    if args.get("bring_to_front") or (action == "focus_app" and args.get("raise_window")):
        scopes.append("bring_to_front")
    mode = "foreground" if args.get("delivery_mode") == "foreground" else "background"
    return [f"cua:{scope}:{mode}" for scope in scopes]


def _skip_computer_use_question(args: dict) -> None:
    try:
        from tools.approval import approve_session
        from tools.approval_context import get_current_session_key

        session_key = get_current_session_key()
        for key in _computer_use_keys(args):
            approve_session(session_key, key)
    except Exception:
        logger.warning("guard: could not spare computer_use its own question", exc_info=True)


class Guard:
    def __init__(self, model=None, trusted_platforms=frozenset({"telegram", "cron"}), mode: str = "auto", *,
                 rules: Optional[dict] = None, identity: str = "", cwd: str = "", context_file: str = "",
                 mode_file: Optional[Path] = None, ask=None, sleep=None,
                 max_prompt_tokens: int = DEFAULT_MAX_PROMPT_TOKENS) -> None:
        from . import prompt

        self.model = model
        self.trusted_platforms = frozenset(trusted_platforms)
        self.default_mode = mode if mode in PERMISSION_MODES else "ask"
        self.mode_file = mode_file
        self.mode = self._stored_mode()
        self.rules = rules or {}
        self.identity = identity
        self.cwd = cwd or os.getcwd()
        self.context_file = context_file
        self.sessions: dict = {}
        self._ask = ask
        self._sleep = sleep
        self._system = None
        self._prompt = prompt
        self.max_prompt_tokens = max_prompt_tokens
        self._variant = ""
        self._told = ""  # the configuration error the owner was told about

    # --- the mode ---

    def _stored_mode(self) -> str:
        try:
            value = json.loads(self.mode_file.read_text()).get("mode") if self.mode_file else None
        except (OSError, ValueError, AttributeError):
            value = None
        return value if value in PERMISSION_MODES else self.default_mode

    def set_mode(self, mode: str) -> str:
        if mode not in PERMISSION_MODES:
            raise ValueError(f"unknown permission mode {mode!r}; one of {', '.join(PERMISSION_MODES)}")
        self.mode = mode
        for session in self.sessions.values():
            session.denials = None
        if self.mode_file:
            self.mode_file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.mode_file.with_suffix(".tmp")
            tmp.write_text(json.dumps({"mode": mode}))
            tmp.replace(self.mode_file)
        logger.info("guard: permission mode is now %s", mode)
        return mode

    # --- sessions ---

    def _session(self, session_id: str) -> Session:
        return self.sessions.setdefault(session_id or "", Session())

    def owners_turn(self, platform: str, text: str) -> bool:
        return platform in self.trusted_platforms and not internal(text)

    def pre_llm_call(self, session_id: str = "", user_message="", platform: str = "", parent_session_id: str = "",
                     **_):
        from .classifier import Denials

        session = self._session(session_id)
        session.subagent = session.subagent or bool(parent_session_id)
        session.parent = parent_session_id or session.parent
        if session.denials is None:
            session.denials = Denials()
        parent = self.sessions.get(parent_session_id) if parent_session_id else None
        if parent is not None:
            # A subagent works for its parent's turn: whether that was the owner's carries over.
            session.turn_from_user = parent.turn_from_user
            if not session.messages:
                session.messages.extend(parent.messages)
            return
        text = user_message if isinstance(user_message, str) else ""
        session.turn_from_user = self.owners_turn(platform, text)
        if session.turn_from_user and text:
            session.messages.append(text[:2000])
            del session.messages[:-8]

    def pre_api_request(self, session_id: str = "", platform: str = "", conversation_history=None, **_):
        """Every request carries the whole conversation: kept as what the
        classifier reads; the calls of the response it brings start afresh."""
        session = self._session(session_id)
        with session.lock:
            session.history = [m for m in conversation_history or [] if isinstance(m, dict)]
            session.platform = platform or session.platform
            session.calls = []
        # A message sent mid-turn joins it as a steer row: the owner's.
        if platform in self.trusted_platforms:
            for m in session.history:
                if m.get("role") == "user" and m.get("display_kind") == "steer":
                    from .transcript import text_of

                    text = steered_text(text_of(m.get("content")))
                    if text and text[:2000] not in session.messages:
                        session.turn_from_user = True
                        session.messages.append(text[:2000])
                        del session.messages[:-8]

    # --- the transcript ---

    def _lines(self, session: Session) -> list:
        from .transcript import history_lines, text_of

        def owners(platform):
            def check(text: str) -> bool:
                return self.owners_turn(platform, text)
            return check

        lines = []
        parent = self.sessions.get(session.parent) if session.parent else None
        if parent is not None:
            lines += history_lines(parent.history, owners(parent.platform), owner_texts=parent.messages)
            # The subagent's own task is its parent's words, relayed: not the owner speaking.
            own = [m for m in session.history if not (m.get("role") == "user")]
            first = next((m for m in session.history if m.get("role") == "user"), None)
            if first is not None:
                from .transcript import NOTIFICATION, indent, line

                lines.append(line("notification", f"{NOTIFICATION} (the task delegated to this subagent)\n"
                                  f"{indent(text_of(first.get('content')))}"))
            lines += history_lines(own, lambda _t: False)
        else:
            history = []
            for m in session.history:
                if m.get("role") == "user" and m.get("display_kind") == "steer":
                    m = {**m, "content": steered_text(text_of(m.get("content"))) or text_of(m.get("content"))}
                history.append(m)
            lines += history_lines(history, owners(session.platform), owner_texts=session.messages)
        return lines + list(session.calls)

    def _context(self) -> str:
        """AGENTS.md, indented and defanged; framed by prompt.context_message."""
        try:
            text = Path(self.context_file).read_text() if self.context_file else ""
        except OSError:
            text = ""
        if not text.strip():
            return ""
        from .transcript import defang, indent

        return defang(indent(text), ["user_claude_md"])

    def _git_status(self, command: str) -> str:
        from .transcript import destroys_work, meta_line, parse_porcelain

        if not destroys_work(command):
            return ""
        try:
            out = subprocess.run(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=self.cwd,
                                 capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return ""
        return meta_line({"gitStatus": parse_porcelain(out.stdout)}) if out.returncode == 0 else ""

    def system_prompt(self) -> str:
        if self._system is None:
            self._system = self._prompt.build_system_prompt(self.rules, self.identity)
        return self._system

    def request(self, lines: list, action: str, meta: str = ""):
        """The request, fitted to the model's limit (budget.py); TooLong when the action cannot fit."""
        from . import budget
        from .classifier import questions

        request = budget.build(budget=self.max_prompt_tokens, model=getattr(self.model, "model", ""), lines=lines,
                               action=action, meta=meta, context=self._context(),
                               wrap_context=self._prompt.context_message, rules=self.rules, identity=self.identity,
                               questions=questions)
        if request.variant != self._variant:
            self._variant = request.variant
            logger.info("guard: the classifier reads Claude Code's %s prompt (requests fitted to %d tokens)",
                        request.variant, self.max_prompt_tokens)
        return request

    def classify(self, lines: list, action: str, meta: str = ""):
        from . import budget, systemone
        from .classifier import Verdict as Classified, classify

        try:
            request = self.request(lines, action, meta)
        except budget.TooLong as error:
            return Classified("too_long", "Too long for auto mode's review model to read", error=str(error))
        if request.omitted or request.context_cut:
            logger.info("guard: request fitted to %d tokens (~%d): %d earlier lines left out%s", self.max_prompt_tokens,
                        request.tokens, request.omitted, ", AGENTS.md cut" if request.context_cut else "")
        ask = self._ask or (lambda **kw: systemone.ask(self.model, **kw))
        kwargs = {"sleep": self._sleep} if self._sleep else {}
        return classify(ask, request.state, request.system, **kwargs)

    def _no_verdict(self, verdict) -> None:
        """Log why the classifier gave no verdict; tell the owner, once, of a configuration error."""
        if verdict.kind in ("allow", "block"):
            if self._told and not verdict.error:
                logger.info("guard: the review model answers again")
                self._told = ""
            if verdict.error:
                logger.warning("guard: stage 2 failed (%s); blocked on stage 1", verdict.error)
            return
        if verdict.kind == "config_error":
            logger.error("guard: auto mode's review model refuses its requests: %s", verdict.error)
            # The same error with other numbers (a token count) is the same error.
            kind = re.sub(r"\d+", "#", verdict.error)
            if self._told != kind:
                self._told = kind
                tell_owner(f"Auto mode can't reach its review model: {verdict.error}. I'm asking you for each action "
                           "until it's fixed.")
            return
        logger.warning("guard: no verdict (%s): %s", verdict.kind, verdict.error or verdict.reason)

    # --- the gate ---

    def pre_tool_call(self, tool_name: str, args: dict, task_id: str = "", session_id: str = "",
                      tool_call_id: str = "", **_):
        from .classifier import Denials, blocked_message, no_verdict_message, status_of, unavailable_message
        from .fastpath import INTERACTIVE, fast_path, looks_only
        from .transcript import call_line, claude_name, UNSHOWN

        args = args or {}
        session = self._session(session_id or task_id)
        if session.denials is None:
            session.denials = Denials()
        shown = call_line(tool_name, args) if tool_name not in UNSHOWN else ""

        def seen() -> None:
            if shown:
                with session.lock:
                    session.calls.append(shown)

        if self.mode == "ask":
            if looks_only(tool_name, args) or tool_name in INTERACTIVE:
                return None
            seen()
            return self._card(session, tool_name, args, "ask mode: every action asks")

        why = fast_path(tool_name, args, self.cwd)
        if why:
            if why != "interactive":
                session.denials.allowed()
            logger.info("guard: %s runs (%s)", tool_name, why)
            seen()
            return None
        if self.model is None and self._ask is None:
            seen()
            return self._card(session, tool_name, args, "no review model configured")
        if not shown:
            # Claude Code: a call with no classifier-relevant input is allowed.
            return None
        meta = self._git_status(str(args["command"])) if tool_name == "terminal" and args.get("command") else ""
        verdict = self.classify(self._lines(session), shown, meta)
        seen()
        if tool_name == "computer_use":
            _skip_computer_use_question(args)
        logger.info("guard: %s %s (%s%s)", tool_name, verdict.kind, verdict.reason,
                    f", p(block)={verdict.block_probability:.2f}" if verdict.block_probability is not None else "")
        self._no_verdict(verdict)
        if verdict.kind in ("config_error", "too_long"):
            # Fail closed by asking: not a judgment, not counted as a block.
            return self._card(session, tool_name, args, verdict.reason)
        if verdict.kind == "allow":
            session.denials.allowed()
            return None
        if verdict.kind in ("block", "parse_failure"):
            session.denials.blocked()
            if session.denials.over_limit():
                return self._card(session, tool_name, args, session.denials.limit_prompt(verdict.reason))
            if verdict.kind == "block":
                return {"action": "block", "message": blocked_message(verdict.reason)}
            return {"action": "block", "message": no_verdict_message(verdict.reason)}
        return {"action": "block", "message": unavailable_message(
            getattr(self.model, "model", "The review model"), claude_name(tool_name), status_of(verdict.error))}

    def _card(self, session: Session, tool_name: str, args: dict, reason: str):
        """The owner's buttons, through Hermes' approval gate (a no, or no
        answer, refuses the call)."""
        said = ""
        if tool_name == "terminal" and (args.get("command") or "").strip():
            said = command_summary(str(args["command"]))
        action = summary(tool_name, args, CARD_ACTION_UNDER_SUMMARY if said else CARD_ACTION)
        first, _, rest = reason.partition("\n\n")
        message = _with_summary(f"{first}: {action}" + (f"\n\n{rest}" if rest else ""), said)
        # What "Always" remembers: this exact action, never a whole tool.
        grain = hashlib.sha256(json.dumps(args, sort_keys=True, default=str).encode()).hexdigest()[:16]
        rule_key = f"guard:{tool_name}:{grain}"
        if session.subagent and _no_card():
            return _ask_owner(message, rule_key)
        return {"action": "approve", "message": message, "rule_key": rule_key}


def _no_card() -> bool:
    """Whether Hermes' approval gate would ask nobody: a background subagent
    still working after its parent's turn ended finds no card notifier
    (gateway/run_turn_runner.py), and the gate refuses without a question."""
    try:
        from tools.approval import _gateway_notify_cb
        from tools.approval_context import _is_gateway_approval_context, get_current_session_key

        return _is_gateway_approval_context() and _gateway_notify_cb(get_current_session_key()) is None
    except Exception:
        return False


SUBAGENT_CHOICES = [("once", "Allow once"), ("session", "Allow for this session"), ("deny", "Deny")]


def _ask_owner(message: str, rule_key: str):
    """Ask with owner_approval's buttons in the main chat, from the subagent's thread."""
    try:
        from tools.approval import approve_session, is_approved
        from tools.approval_context import _get_approval_timeout, get_current_session_key

        session_key = get_current_session_key()
        pattern_key = f"plugin_rule:{rule_key}"
        if is_approved(session_key, pattern_key):
            return None
        from owner_approval import ask

        choice = ask("A subagent wants to act", message, SUBAGENT_CHOICES, timeout=_get_approval_timeout())
    except Exception:
        logger.warning("guard: could not ask the owner for a subagent's action", exc_info=True)
        choice = "unavailable"
    if choice == "session":
        approve_session(session_key, pattern_key)
    if choice in ("once", "session"):
        return None
    reason = {"deny": "the user denied it", "timeout": "the user did not answer in time"}.get(
        choice, "the user could not be asked")
    return {"action": "block", "message": f"BLOCKED: {reason}. Do not retry it; say so in your result. ({message})"}


def tell_owner(text: str) -> None:
    """A plain message to the owner's main chat, through owner_approval's bot."""
    try:
        from owner_approval import tell

        if tell(text):
            return
    except Exception:
        logger.warning("guard: could not tell the owner", exc_info=True)
        return
    logger.warning("guard: could not tell the owner (Telegram not connected)")


# The loaded Guard, for other plugins and the app: ``import guard``.
GUARD: Optional[Guard] = None


def permission_mode() -> str:
    return GUARD.mode if GUARD is not None else "ask"


def set_permission_mode(mode: str) -> str:
    if GUARD is None:
        raise RuntimeError("guard is not loaded")
    return GUARD.set_mode(mode)


def permission_mode_info() -> dict:
    """For the app's picker (app-backend's App topic controls)."""
    return {
        "value": permission_mode(),
        "options": [{"id": m, "label": MODE_LABELS[m][0], "description": MODE_LABELS[m][1]} for m in PERMISSION_MODES],
        "set": "/mode {value}",
    }


def mode_command(raw_args: str = "", **_) -> str:
    arg = (raw_args or "").strip().lower()
    if not arg:
        return f"Permission mode: {permission_mode()} ({MODE_LABELS[permission_mode()][1]}) /mode auto or /mode ask."
    try:
        mode = set_permission_mode(arg)
    except ValueError as error:
        return str(error)
    return f"Permission mode: {mode}. {MODE_LABELS[mode][1]}"


def reviewing() -> bool:
    """Whether a classifier reviews actions (guard loaded, a model, auto mode)."""
    return GUARD is not None and GUARD.model is not None and GUARD.mode == "auto"


def launch_context(session_id: str) -> "dict | None":
    """What the owner wrote in a session so far, and whether the current turn
    is theirs (for the sandbox, which reviews later against it)."""
    if GUARD is None:
        return None
    session = GUARD.sessions.get(session_id or "")
    if session is None:
        return {"messages": [], "turn_from_user": False}
    return {"messages": list(session.messages), "turn_from_user": bool(session.turn_from_user)}


def review_action(context: dict, tool: str, args: dict, actions=()) -> Verdict:
    """Classify an action taken outside Hermes' own tool calls (the sandbox's
    requests) against a launch_context: run, the reason, and a risk the
    sandbox grants on (low: cleared by stage 1)."""
    from .transcript import NOTIFICATION, call_line, indent, line

    if GUARD is None:
        return Verdict(False, "the auto-review is off")
    if GUARD.mode != "auto":
        return Verdict(False, "ask mode: every action asks")
    if GUARD.model is None and GUARD._ask is None:
        return Verdict(False, "no review model configured")
    context = context or {}
    key = "user" if context.get("turn_from_user") else "notification"
    lines = [line(key, indent(m) if key == "user" else f"{NOTIFICATION}\n{indent(m)}") for m in context.get("messages") or []]
    lines += [line("action", str(a)) for a in actions]
    verdict = GUARD.classify(lines, call_line(tool, args) or line(tool, args))
    GUARD._no_verdict(verdict)
    if verdict.kind == "allow":
        return Verdict(True, verdict.reason, "low" if verdict.stage == "fast" else "medium")
    return Verdict(False, verdict.reason, "high")


def _load(home: Path) -> Guard:
    from . import systemone

    config = json.loads((home / "guard" / "config.json").read_text())
    model = None
    if config.get("model"):
        key = os.environ.get(config["key_env"], "") if config.get("key_env") else ""
        model = systemone.Config.from_env({
            "OPENJEV_BASE_URL": config["url"], "OPENJEV_MODEL": config["model"],
            "OPENJEV_AUTH_SCHEME": config["auth_scheme"], "OPENJEV_API_KEY": key,
            "OPENJEV_TIMEOUT_MS": str(config.get("timeout_ms", 20000)),
        })
        logger.info("guard: auto mode's classifier is the decision model %s at %s", model.model, model.url)
    else:
        logger.warning("guard: no review model; auto mode asks the owner for every call it cannot clear itself")
    return Guard(model, config.get("trusted_platforms", ["telegram", "cron"]), config.get("mode", "auto"),
                 rules=config.get("rules") or {}, identity=config.get("identity", ""), cwd=config.get("cwd", ""),
                 context_file=config.get("context_file", ""), mode_file=home / "guard" / "mode.json",
                 max_prompt_tokens=int(config.get("max_prompt_tokens") or DEFAULT_MAX_PROMPT_TOKENS))


def register(ctx) -> None:
    import sys

    from hermes_constants import get_hermes_home

    global GUARD
    GUARD = _load(Path(get_hermes_home()))
    sys.modules.setdefault("guard", sys.modules[__name__])
    ctx.register_hook("pre_llm_call", GUARD.pre_llm_call)
    ctx.register_hook("pre_api_request", GUARD.pre_api_request)
    ctx.register_hook("pre_tool_call", GUARD.pre_tool_call)
    ctx.register_command("mode", mode_command, description="Permission mode: auto or ask", args_hint="[auto|ask]")
