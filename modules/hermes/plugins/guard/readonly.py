"""Claude Code 2.1.317's Bash read-only check: commands it runs with no
permission check before auto mode ever sees them.

Ported from Arthur's Pi extension auto-mode (readonly.ts). Claude Code parses
with tree-sitter; the parser here only reads plain commands joined by `&&`,
`||`, `;`, `|` and newlines, and refuses (sends to the classifier) anything it
cannot see through. ``read_only_refusal(command, cwd)`` is None when the
command is read-only, else why it is not.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Optional

from .readonly_tables import (
    BARE_ONLY, COMMAND_ALLOWLIST, EXACT_COMMANDS, FIND_ACTIONS, FIND_BAD_OPTION, FIND_NEWER, FIND_TAKES_NEXT,
    FIND_VALUED, GLOB_COMMANDS, PATH_LIKE, READONLY_COMMANDS, READONLY_PATTERNS, SAFE_ENV, XARGS_TARGETS,
    CommandConfig, docker_host_flag, is_flag, sed_read_only, tilde_like, user_tilde,
)


@dataclass
class Word:
    value: str = ""
    raw: str = ""
    glob: bool = False
    brace: bool = False


@dataclass
class Command:
    argv: list = field(default_factory=list)
    words: list = field(default_factory=list)
    env: list = field(default_factory=list)  # (name, value)
    redirects: list = field(default_factory=list)  # (op, target)
    text: str = ""


@dataclass
class Script:
    commands: list
    joins: list


MAX_LENGTH = 10_000


class _Opaque(Exception):
    pass


def parse(source: str) -> Optional[Script]:
    """Plain commands only: `$`, backticks, subshells, groups, heredocs, process
    substitution and background jobs make it return None."""
    if len(source) > MAX_LENGTH:
        return None
    commands: list = []
    joins: list = []
    st = {"cur": Command(), "word": None, "pending": None}
    raws: list = []

    def flush() -> bool:
        w = st["word"]
        if w is None:
            return True
        st["word"] = None
        if w.brace and w.raw != "{}":
            return False
        cur = st["cur"]
        if st["pending"]:
            cur.redirects.append((st["pending"], w.value))
            st["pending"] = None
            return True
        assignment = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\+?=", w.raw) if not cur.words else None
        if assignment:
            cur.env.append((assignment.group(1), w.value[w.value.index("=") + 1:]))
        else:
            cur.words.append(w)
            cur.argv.append(w.value)
        raws.append(w.raw)
        return True

    def end(join: Optional[str], newline: bool = False) -> bool:
        if not flush() or st["pending"]:
            return False
        cur = st["cur"]
        if not cur.words:
            # A bare assignment changes the shell for what follows.
            if cur.env or cur.redirects:
                return False
            if newline:
                return True
            if join is not None:
                return False
            if len(joins) == len(commands):
                if not joins or joins[-1] != ";":
                    return False
                joins.pop()
            return len(commands) > 0
        if cur.words[0].raw == "!":
            return False
        cur.text = " ".join(raws)
        raws.clear()
        commands.append(cur)
        if join:
            joins.append(join)
        st["cur"] = Command()
        return True

    def extend(value: str, raw: str, glob: bool = False) -> None:
        if st["word"] is None:
            st["word"] = Word()
        w = st["word"]
        w.value += value
        w.raw += raw
        w.glob = w.glob or glob

    n = len(source)
    i = 0
    while i < n:
        c = source[i]
        if c == "'":
            close = source.find("'", i + 1)
            if close == -1:
                return None
            extend(source[i + 1:close], source[i:close + 1])
            i = close
        elif c == '"':
            value = ""
            j = i + 1
            while j < n and source[j] != '"':
                d = source[j]
                if d in "$`":
                    return None
                if d == "\\" and j + 1 < n and source[j + 1] in '$`"\\\n':
                    if source[j + 1] != "\n":
                        value += source[j + 1]
                    j += 1
                else:
                    value += d
                j += 1
            if j >= n:
                return None
            extend(value, source[i:j + 1])
            i = j
        elif c == "\\":
            if i + 1 >= n:
                return None
            if source[i + 1] != "\n":
                extend(source[i + 1], source[i:i + 2])
            i += 1
        elif c in "$`()":
            return None
        elif c == "#" and st["word"] is None:
            while i + 1 < n and source[i + 1] != "\n":
                i += 1
        elif c in " \t":
            if not flush():
                return None
        elif c in "\n;":
            if c == ";" and i + 1 < n and source[i + 1] == ";":
                return None
            if not end(";", c == "\n"):
                return None
        elif c == "&":
            nxt = source[i + 1] if i + 1 < n else ""
            if nxt == "&":
                if not end("&&"):
                    return None
                i += 1
            elif nxt == ">":
                if not flush() or st["pending"]:
                    return None
                i += 2
                st["pending"] = "&>>" if i < n and source[i] == ">" else "&>"
                if st["pending"] == "&>":
                    i -= 1
            else:
                return None
        elif c == "|":
            nxt = source[i + 1] if i + 1 < n else ""
            if nxt == "|":
                if not end("||"):
                    return None
                i += 1
            elif nxt == "&":
                return None
            elif not end("|"):
                return None
        elif c in "<>":
            nxt = source[i + 1] if i + 1 < n else ""
            if nxt == "(" or (c == "<" and nxt in ("<", ">")):
                return None
            # `2>`: a word of digits right before the operator is its file descriptor.
            if st["word"] is not None and re.fullmatch(r"\d+", st["word"].raw):
                st["word"] = None
            elif not flush():
                return None
            if st["pending"]:
                return None
            op = c
            if c == ">" and nxt in (">", "|"):
                i += 1
                op += source[i]
            if i + 1 < n and source[i + 1] == "&":
                op += "&"
                i += 1
            st["pending"] = op
        else:
            extend(c, c, c in "*?[")
            if c in "{}":
                st["word"].brace = True
        i += 1
    if not end(None):
        return None
    return Script(commands, joins)


def unwrap(argv: list) -> list:
    """`command`, `builtin` and `noglob` only change how the name is looked up."""
    a = argv
    while True:
        if a and a[0] == "command":
            i = 1
            while i < len(a) and re.fullmatch(r"-p+", a[i]):
                i += 1
            if i < len(a) and a[i] == "--":
                i += 1
            if i >= len(a) or a[i].startswith("-"):
                return a
            a = a[i:]
        elif a and a[0] == "builtin":
            i = 2 if len(a) > 1 and a[1] == "--" else 1
            if i >= len(a):
                return a
            a = a[i:]
        elif a and a[0] == "noglob":
            if len(a) <= 1:
                return a
            a = a[1:]
        else:
            return a


_UNWRAP_PREFIX = re.compile(r"^(?:(?:command(?:[ \t]+-p+)*|builtin)(?:[ \t]+--)?|noglob)[ \t]+(?!-)")


def unwrap_text(text: str) -> str:
    t = text
    while _UNWRAP_PREFIX.search(t):
        t = _UNWRAP_PREFIX.sub("", t, count=1)
    return t


def _value_matches(value: str, kind: str) -> bool:
    return {
        "number": lambda: re.fullmatch(r"\d+", value) is not None,
        "string": lambda: True,
        "char": lambda: len(value) == 1,
        "{}": lambda: value == "{}",
        "EOF": lambda: value == "EOF",
    }.get(kind, lambda: False)()


def _flags_allowed(argv: list, start: int, config: CommandConfig, xargs_targets=None) -> bool:
    """Every flag must be in the command's safe list, with a value of the right type when it takes one."""
    name = argv[0]
    i = start
    while i < len(argv):
        a = argv[i]
        if not a:
            i += 1
            continue
        if xargs_targets is not None and (not a.startswith("-") or a == "--"):
            if a == "--" and i + 1 < len(argv):
                i += 1
                a = argv[i]
            if a in xargs_targets:
                break
            return False
        if a == "--":
            if config.respects_double_dash:
                break
            i += 1
            continue
        if not (a.startswith("-") and len(a) > 1):
            i += 1
            continue
        attached = "=" in a
        flag, _, inline = a.partition("=")
        if not flag:
            return False
        kind = config.safe_flags.get(flag)
        if not kind:
            if name == "git" and re.fullmatch(r"-\d+", flag):
                i += 1
                continue
            if name in ("grep", "egrep", "fgrep", "rg") and not flag.startswith("--") and len(flag) > 2:
                short = config.safe_flags.get(flag[:2])
                if short in ("number", "string") and re.fullmatch(r"\d+", flag[2:]):
                    i += 1
                    continue
            if not flag.startswith("--") and len(flag) > 2:
                if not all(config.safe_flags.get(f"-{ch}") == "none" for ch in flag[1:]):
                    return False
                i += 1
                continue
            return False
        if kind == "none":
            if attached:
                return False
            i += 1
            continue
        if attached:
            value = inline
            i += 1
        else:
            if i + 1 >= len(argv) or (argv[i + 1] and is_flag(argv[i + 1])):
                return False
            value = argv[i + 1] or ""
            i += 2
        if kind == "string" and value.startswith("-") and not (
                flag == "--sort" and name == "git" and re.match(r"^-[a-zA-Z]", value)):
            return False
        if not _value_matches(value, kind):
            return False
    return True


def _allowlisted(text: str, argv: list) -> bool:
    if not argv:
        return False
    config = None
    start = 0
    for key, c in COMMAND_ALLOWLIST.items():
        words = key.split(" ")
        if len(argv) >= len(words) and argv[:len(words)] == words:
            config, start = c, len(words)
            break
    if config is None:
        return False
    if argv[0] == "git" and len(argv) > 1 and argv[1] == "ls-remote":
        if any(a in ("-o", "--server-option") or a.startswith("--server-option=") for a in argv):
            return False
        dashdash = False
        for a in argv[2:]:
            if not a:
                continue
            if not dashdash and a == "--":
                dashdash = True
                continue
            if dashdash or a == "-" or not a.startswith("-"):
                return False
    for a in argv[start:]:
        if "$" in a:
            return False
        if "{" in a and ("," in a or ".." in a):
            return False
    if not _flags_allowed(argv, start, config, XARGS_TARGETS if argv[0] == "xargs" else None):
        return False
    if config.regex is not None and not config.regex.search(text):
        return False
    if config.regex is None and "`" in text:
        return False
    if config.regex is None and argv[0] in ("rg", "grep", "egrep", "fgrep") and re.search(r"[\n\r]", text):
        return False
    return not (config.is_dangerous and config.is_dangerous(text, argv[start:]))


NUMBER = re.compile(r"^[-+]?(0[xX][0-9a-fA-F]+|[0-9]+#[0-9a-zA-Z]+|[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?)$")


def _argv_verdict(argv: list) -> Optional[bool]:
    """Claude Code's argv-level verdicts; None means "decide from the text"."""
    if not argv:
        return False
    name = argv[0]
    if name in BARE_ONLY:
        return len(argv) == 1
    if any(e == argv for e in EXACT_COMMANDS):
        return True
    if name in READONLY_COMMANDS:
        return True
    for multi in (c for c in READONLY_COMMANDS if " " in c):
        words = multi.split(" ")
        if len(argv) >= len(words) and argv[:len(words)] == words:
            return not (words[0] == "docker" and (docker_host_flag(argv) or tilde_like(argv[len(words):])))
    if name in ("echo", "ls"):
        return True
    if name == "printf":
        if len(argv) > 1 and argv[1].startswith("-") and argv[1] != "--":
            return False
        at = 2 if len(argv) > 1 and argv[1] == "--" else 1
        fmt = argv[at] if at < len(argv) else ""
        if "$" in fmt:
            return False
        f = fmt.replace("%%", "")
        # %b-style escapes and \u can write arbitrary bytes; numeric conversions evaluate their argument.
        if re.search(r"%[^%a-zA-Z]*[lLhqjzZt]*\\[0-7xX]", f) or re.search(r"\\[uU]", f):
            return False
        if re.search(r"%[-+ 0#']*[0-9.*]*[lLhqjzZt]*[diouxXeEfFgGaAn]", f) or re.search(r"%[^%a-zA-Z]*\*", f):
            for a in argv[at + 1:]:
                if "[" in a or "`" in a or "$(" in a or not NUMBER.match(a):
                    return False
        return True
    if name == "cd":
        return len(argv) <= 2
    if name == "find":
        takes_next = False
        i = 1
        while i < len(argv):
            a = argv[i]
            skip = takes_next
            takes_next = False
            if a in FIND_ACTIONS or FIND_BAD_OPTION.match(a):
                return False
            if not skip and FIND_TAKES_NEXT.match(a):
                takes_next = True
                i += 1
                continue
            if not skip and (a in FIND_VALUED or FIND_NEWER.match(a) or FIND_TAKES_NEXT.match(a)):
                i += 1
            i += 1
        return True
    if name == "history":
        return len(argv) == 1 or (len(argv) == 2 and re.fullmatch(r"\d+", argv[1]) is not None)
    if name == "arch":
        return len(argv) == 1 or (len(argv) == 2 and argv[1] in ("-h", "--help"))
    if name == "ifconfig":
        return len(argv) == 1 or (len(argv) == 2 and re.match(r"^[a-zA-Z]", argv[1]) is not None)
    return None


def _text_verdict(text: str, argv: list) -> bool:
    t = text.strip()
    if t.endswith(" 2>&1"):
        t = t[:-5].strip()
    if _allowlisted(t, argv):
        return True
    for pattern in READONLY_PATTERNS:
        if not pattern.search(t):
            continue
        if t.startswith("find") and re.search(
                r"-delete\b|-rm\b|-exec\b|-execdir\b|-ok\b|-okdir\b|-fprint0?\b|-fls\b|-fprintf\b|-files0-from\b",
                re.sub(r"['\"\\]", "", t)):
            return False
        if "git" in t and (re.search(r"\s-c[\s=]", t) or re.search(r"\s--exec-path[\s=]", t)
                           or re.search(r"\s--config-env[\s=]", t)):
            return False
        return True
    return False


INPUT_OPS = {"<", "<&"}


def command_read_only(cmd: Command) -> Optional[str]:
    """One simple command, as Claude Code's per-command read-only check sees it."""
    for op, target in cmd.redirects:
        if re.match(r"^/dev/(tcp|udp)/", target):
            return "network redirect"
        if op in INPUT_OPS or target == "/dev/null" or (op == ">&" and re.fullmatch(r"\d+", target)):
            continue
        return "output redirect"
    if any(name not in SAFE_ENV or PATH_LIKE.search(value) for name, value in cmd.env):
        return "environment prefix"
    if any(user_tilde(a) for a in cmd.argv[1:]) or any(op == "<" and user_tilde(t) for op, t in cmd.redirects):
        return "~user path"
    argv = unwrap(cmd.argv)
    if any(w.glob for w in cmd.words):
        return None if (argv[0] if argv else "") in GLOB_COMMANDS else "glob"
    verdict = _argv_verdict(argv)
    if verdict is not None:
        return None if verdict else "not read-only"
    return None if _text_verdict(unwrap_text(cmd.text), argv) else "not read-only"


# --- paths ---

def _home() -> str:
    return os.path.expanduser("~")


def realish(p: str) -> str:
    """Symlinks followed through the deepest part of the path that exists."""
    missing = []
    at = p
    while True:
        if os.path.exists(at):
            return os.path.join(os.path.realpath(at), *reversed(missing))
        parent = os.path.dirname(at)
        if parent == at:
            return p
        missing.append(os.path.basename(at))
        at = parent


def _expand_home(p: str) -> str:
    return _home() if p == "~" else os.path.join(_home(), p[2:]) if p.startswith("~/") else p


def _inside(root: str, p: str) -> bool:
    rel = os.path.relpath(p, root)
    return rel == "." or (not rel.startswith("..") and not os.path.isabs(rel))


def _climbs_after_name(p: str) -> bool:
    """`..` after a named segment can climb back out through a symlink."""
    named = False
    for s in p.split("/"):
        if s in ("", "."):
            continue
        if s == "..":
            if named:
                return True
        else:
            named = True
    return False


def readable(root: str, base: str, target: str) -> bool:
    """Claude Code's read check: the path resolves inside the working directory."""
    if target.startswith("~") and target != "~" and not target.startswith("~/"):
        return False
    if "$" in target or "`" in target or target.startswith("="):
        return False
    p = _expand_home(target)
    if _climbs_after_name(p):
        return False
    m = re.search(r"[*?[]", p)
    if m:
        cut = p.rfind("/", 0, m.start())
        p = "." if cut == -1 else (p[:cut] or "/")
    return _inside(root, realish(os.path.normpath(os.path.join(base, p))))


def _operands(args: list) -> list:
    out = []
    dashdash = started = False
    for a in args:
        if dashdash or started:
            out.append(a)
        elif a == "--":
            dashdash = True
        elif a == "-" or not a.startswith("-"):
            out.append(a)
            started = True
    return out


def _shaped(boolean_short: str, valued_short: str, boolean_long, valued_long, attached_short: str = "",
            attached_long=()):
    def kind(a: str) -> str:
        if a.startswith("--"):
            if "=" in a:
                return "attached"
            if a in boolean_long:
                return "boolean"
            if a in attached_long:
                return "attached"
            return "valued" if a in valued_long else "unknown"
        if re.fullmatch(r"-\d+", a):
            return "attached"
        for i in range(1, len(a)):
            ch = a[i]
            if ch in boolean_short:
                continue
            if ch in attached_short:
                return "attached"
            if ch not in valued_short:
                return "unknown"
            return "valued" if i == len(a) - 1 else "attached"
        return "boolean"

    def extract(args: list) -> list:
        out = []
        dashdash = started = False
        known = True
        i = 0
        while i < len(args):
            a = args[i]
            if dashdash or started:
                out.append(a)
            elif a == "--":
                dashdash = True
            elif a != "-" and a.startswith("-"):
                if known:
                    k = kind(a)
                    if k == "valued":
                        i += 1
                    elif k == "unknown":
                        known = False
            else:
                out.append(a)
                started = True
            i += 1
        return out

    return extract


def _attached_value(a: str, flags) -> Optional[str]:
    if not a.startswith("-"):
        return None
    eq = a.find("=")
    if eq >= 0:
        return a[eq + 1:] if a[:eq] in flags else None
    for f in flags:
        if len(f) == 2 and f[0] == "-" and a.startswith(f) and a != f:
            return a[2:]
    return None


def _pattern_operands(args: list, valued: set, fallback=()) -> list:
    """grep/rg: the first operand is the pattern unless -e/-f gave one; pattern files are read too."""
    out = []
    have_pattern = dashdash = started = False
    i = 0
    while i < len(args):
        a = args[i]
        if not dashdash and not started and a == "--":
            dashdash = True
            i += 1
            continue
        if not dashdash and not started and a != "-" and a.startswith("-"):
            eq = a.find("=")
            flag = a[:eq] if eq >= 0 else a
            if flag in ("-e", "--regexp", "-f", "--file"):
                have_pattern = True
                if flag in ("-f", "--file"):
                    file = a[eq + 1:] if eq >= 0 else (args[i + 1] if i + 1 < len(args) else None)
                    if file:
                        out.append(file)
            if re.fullmatch(r"-[a-zA-Z]*f", flag) and flag != "-f" and eq < 0 and i + 1 < len(args):
                have_pattern = True
                i += 1
                out.append(args[i])
                i += 1
                continue
            if flag in ("--exclude-from", "--include-from", "--ignore-file"):
                file = a[eq + 1:] if eq >= 0 else (args[i + 1] if i + 1 < len(args) else None)
                if file:
                    out.append(file)
                i += 1 if eq >= 0 else 2
                continue
            if eq < 0:
                file = _attached_value(a, ["-f", "--file"])
                if file is not None:
                    have_pattern = True
                    out.append(file)
                    i += 1
                    continue
                if len(a) > 2 and a.startswith("-e"):
                    have_pattern = True
                    i += 1
                    continue
            i += 2 if flag in valued and eq < 0 else 1
            continue
        if started and not dashdash:
            file = _attached_value(a, ["-f", "--file"])
            if file is not None:
                out.append(file)
        started = True
        if not have_pattern:
            have_pattern = True
            i += 1
            continue
        out.append(a)
        i += 1
    return out if out else list(fallback)


GREP_VALUED = {"-e", "--regexp", "-f", "--file", "--exclude", "--include", "--exclude-dir", "--include-dir", "-m",
               "--max-count", "-A", "--after-context", "-B", "--before-context", "-C", "--context"}
RG_VALUED = {"-e", "--regexp", "-f", "--file", "-t", "--type", "-T", "--type-not", "-g", "--glob", "-m", "--max-count",
             "--max-depth", "-r", "--replace", "-A", "--after-context", "-B", "--before-context", "-C", "--context"}
GIT_GREP_VALUED = {"-e", "--regexp", "-f", "--file", "-A", "--after-context", "-B", "--before-context", "-C",
                   "--context", "-m", "--max-count", "--max-depth", "--threads"}
GIT_GLOBAL_VALUED = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env",
                     "--attr-source", "--shallow-file"}


def _device(p: str) -> bool:
    return p in ("/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr", "/dev/tty") or bool(
        re.fullmatch(r"/dev/fd/\d+", p) or re.fullmatch(r"/proc/self/fd/[0-2]", p))


def _grep_paths(args):
    out = _pattern_operands(args, GREP_VALUED)
    return ["."] if not out and any(a in ("-r", "-R", "--recursive") for a in args) else out


def _find_paths(args):
    out = []
    valued = {"-newer", "-anewer", "-cnewer", "-mnewer", "-samefile", "-path", "-wholename", "-ilname", "-lname",
              "-ipath", "-iwholename"}
    predicates = dashdash = False
    i = 0
    while i < len(args):
        a = args[i]
        if not a:
            pass
        elif dashdash:
            out.append(a)
        elif a == "--":
            dashdash = True
        elif a.startswith("-"):
            if a not in ("-H", "-L", "-P"):
                predicates = True
                if a in valued or re.fullmatch(r"-newer[acmBt][acmtB]", a):
                    if i + 1 < len(args) and args[i + 1]:
                        out.append(args[i + 1])
                        i += 1
        elif not predicates:
            out.append(a)
        i += 1
    return out if out else ["."]


def _sed_paths(args):
    out = []
    skip = have_script = dashdash = started = False
    for i, a in enumerate(args):
        if skip:
            skip = False
            continue
        if not a:
            continue
        if not dashdash and not started and a == "--":
            dashdash = True
            continue
        if not dashdash and not started and a != "-" and a.startswith("-"):
            if a in ("-f", "--file"):
                if i + 1 < len(args) and args[i + 1]:
                    out.append(args[i + 1])
                skip = have_script = True
            elif a in ("-e", "--expression"):
                skip = have_script = True
            elif "e" in a or "f" in a:
                have_script = True
            continue
        started = True
        if not have_script:
            have_script = True
            continue
        out.append(a)
    return out


def _jq_paths(args):
    out = []
    valued = {"-e", "--expression", "--arg", "--argjson", "--args", "--jsonargs", "-L", "--library-path", "--indent", "--tab"}
    have_filter = dashdash = False
    i = 0
    while i < len(args):
        a = args[i]
        if not dashdash and a == "--":
            dashdash = True
            i += 1
            continue
        if not dashdash and a.startswith("-"):
            eq = a.find("=")
            flag = a[:eq] if eq >= 0 else a
            if flag in ("-e", "--expression"):
                have_filter = True
            if flag in ("-f", "--from-file"):
                have_filter = True
                if eq >= 0:
                    out.append(a[eq + 1:])
                elif i + 1 < len(args):
                    i += 1
                    out.append(args[i])
                i += 1
                continue
            if flag in ("--slurpfile", "--rawfile"):
                if i + 2 < len(args):
                    out.append(args[i + 2])
                i += 3
                continue
            i += 2 if flag in valued and eq < 0 else 1
            continue
        if not have_filter:
            have_filter = True
        else:
            out.append(a)
        i += 1
    return out


def _git_paths(args):
    i = 0
    d = ""
    while i < len(args) and args[i].startswith("-"):
        opt = args[i]
        i += 1
        if opt in GIT_GLOBAL_VALUED and i < len(args):
            value = args[i]
            i += 1
            if opt in ("-C", "--work-tree"):
                d = value if os.path.isabs(_expand_home(value)) or value.startswith("~") else (
                    f"{d.rstrip('/')}/{value}" if d else value)
        elif opt.startswith("--work-tree="):
            d = opt[12:]

    def under(p):
        return p if d == "" or os.path.isabs(_expand_home(p)) or p.startswith("~") else f"{d.rstrip('/')}/{p}"

    sub = args[i] if i < len(args) else None
    rest = args[i + 1:]
    if sub == "grep":
        found = _pattern_operands(rest, GIT_GREP_VALUED)
        return [under(p) for p in found] if found else ["." if d == "" else d]
    if sub != "diff":
        return []
    out = []
    dashdash = False
    for a in rest:
        if not dashdash and a == "--":
            dashdash = True
        elif dashdash or a == "-" or not a.startswith("-"):
            p = under(a)
            if not _device(p):
                out.append(p)
    return out


def _man_paths(args):
    local = any(a == "--local-file" or (re.match(r"^-[^-]", a) and "l" in a) for a in args)
    out = []
    for i, a in enumerate(args):
        if i > 0 and args[i - 1] in ("-C", "--config-file"):
            out.append(a)
            continue
        slash = re.search(r"[\\/~]", a)
        if not a.startswith("-"):
            parts = [a]
        else:
            parts = []
            if "=" in a:
                parts.append(a[a.index("=") + 1:])
            if len(a) > 2 and not a.startswith("--"):
                parts.append(a[2:])
            if slash and slash.start() > 0:
                parts.append(a[slash.start():])
            parts = list(dict.fromkeys(parts))
        out += [p for p in parts if p != "" and (local or re.search(r"[\\/]", p) or p.startswith("~") or p.startswith("."))]
    return out


def _cd_paths(args):
    ops = _operands(args)
    if not ops:
        return ["-"] if args and args[-1] == "-" else ["~"]
    return [ops[0]]


def _tr_paths(args):
    deletes = any(a in ("-d", "--delete") or (a.startswith("-") and "d" in a) for a in args)
    return _operands(args)[1 if deletes else 2:]


# The read commands whose path operands Claude Code checks against the working directories.
PATHS = {
    "cd": _cd_paths,
    "ls": lambda args: _operands(args) or ["."],
    "find": _find_paths,
    **{c: _operands for c in "cat head tail sort uniq wc file stat diff strings hexdump od base64 nl sha256sum sha1sum md5sum rev tsort".split()},
    "cut": _shaped("nswz", "bcdf", ["--complement", "--only-delimited", "--zero-terminated"],
                   ["--bytes", "--characters", "--delimiter", "--fields", "--output-delimiter"]),
    "paste": _shaped("sz", "d", ["--serial", "--zero-terminated"], ["--delimiters"]),
    "column": _shaped("txdemLJhV", "cosNOClEHRTWrip",
                      ["--table", "--fillrows", "--table-noheadings", "--table-header-repeat", "--table-maxout",
                       "--keep-empty-lines", "--json"],
                      ("--separator --output-separator --output-width --table-name --table-order --table-column "
                       "--table-columns --table-columns-limit --table-noextreme --table-hide --table-right "
                       "--table-truncate --table-wrap --tree --tree-id --tree-parent").split()),
    "tr": _tr_paths,
    "grep": _grep_paths,
    "egrep": _grep_paths,
    "fgrep": _grep_paths,
    "tac": _shaped("br", "s", ["--before", "--regex"], ["--separator"]),
    "fold": _shaped("bs", "w", ["--bytes", "--spaces"], ["--width"]),
    "expand": _shaped("i", "t", ["--initial"], ["--tabs"]),
    "unexpand": _shaped("af", "t", ["--all", "--first-only"], ["--tabs"]),
    "fmt": _shaped("csumn", "wgdl", ["--crown-margin", "--split-only", "--tagged-paragraph", "--uniform-spacing"],
                   ["--width", "--goal", "--prefix"]),
    "comm": _shaped("123iz", "", ["--check-order", "--nocheck-order", "--total", "--zero-terminated"],
                    ["--output-delimiter"]),
    "cmp": _shaped("blsvxzh", "", ["--print-bytes", "--verbose", "--quiet", "--silent"], ["--ignore-initial", "--bytes"]),
    "pr": _shaped("acdFfJmprtTv", "hlwWoND",
                  ("--across --show-control-chars --double-space --form-feed --join-lines --merge --no-file-warnings "
                   "--omit-header --omit-pagination --show-nonprinting").split(),
                  ["--header", "--length", "--width", "--page-width", "--indent", "--first-line-number",
                   "--date-format", "--columns"],
                  attached_short="einsS",
                  attached_long=["--expand-tabs", "--output-tabs", "--number-lines", "--separator", "--sep-string"]),
    "numfmt": _shaped("z", "d", ["--grouping", "--zero-terminated", "--debug"],
                      ["--from", "--to", "--from-unit", "--to-unit", "--format", "--padding", "--delimiter", "--field",
                       "--round", "--suffix", "--invalid"], attached_long=["--header"]),
    "man": _man_paths,
    "rg": lambda args: _pattern_operands(args, RG_VALUED, ["."]),
    "sed": _sed_paths,
    "jq": _jq_paths,
    "git": _git_paths,
}


def _is_cd(argv) -> bool:
    u = unwrap(argv)
    return bool(u) and u[0] in ("cd", "pushd", "popd", "chdir")


def _is_git(cmd: Command) -> bool:
    argv = unwrap(cmd.argv)
    return bool(argv) and (argv[0] == "git" or (argv[0] == "xargs" and "git" in argv))


def _paths_readable(cmd: Command, root: str, bases: list, after_cd: bool) -> Optional[str]:
    """The paths a read-only command names, checked as Claude Code's path validation does."""
    argv = unwrap(cmd.argv)
    name = argv[0] if argv else ""
    for op, target in cmd.redirects:
        if (re.fullmatch(r"\d+|-", target) is not None) if op == "<&" else (op != "<" or _device(target)):
            continue
        if re.search(r"[*?[]", target) or (after_cd and not os.path.isabs(target) and not target.startswith("~")):
            return "input redirect after cd"
        if not all(readable(root, b, target) for b in bases):
            return "outside the working directory"
    extract = PATHS.get(name)
    if extract is None:
        return None
    if name == "sed" and not sed_read_only(argv):
        return "not read-only"
    args = argv[1:]
    if name == "cd" and len(_operands(args)) > 1:
        return "cd with two operands"
    # The previous directory is unknown here.
    if name == "cd" and args and args[-1] == "-":
        return "cd -"
    # Claude Code leaves a path given as `--flag=PATH` unchecked; here it is checked too.
    attached = [a[a.index("=") + 1:] for a in args if a.startswith("-") and "=" in a]
    attached = [v for v in attached if re.match(r"^[/~.]", v)]
    paths = list(extract(args)) + attached
    return None if all(readable(root, b, p) for p in paths for b in bases) else "outside the working directory"


def _same_dir(a: str, b: str) -> bool:
    try:
        x, y = os.stat(a), os.stat(b)
    except OSError:
        return False
    return x.st_dev == y.st_dev and x.st_ino == y.st_ino


def _cd_keeps_repo(target: str, cwd: str) -> bool:
    """`cd` targets Claude Code trusts before a git command: the working directory itself."""
    if target.startswith("-"):
        return False
    explicit = os.path.isabs(target) or target.startswith("./") or target.startswith("../") or target in (".", "..")
    if not explicit or re.search(r"[$`*?[\\]", target):
        return False
    named = False
    for s in target.split("/"):
        if s in ("", "."):
            continue
        if s == "..":
            if not os.path.isabs(target) or named:
                return False
        else:
            named = True
    return _same_dir(os.path.normpath(os.path.join(cwd, target)), cwd)


_HEAD = re.compile(r"^ref:[ \t]*refs/|^[0-9a-f]{40}([0-9a-f]{24})?[ \t\n\r]*$")


def _head_valid(d: str) -> bool:
    p = os.path.join(d, "HEAD")
    try:
        if os.path.islink(p) or not os.path.isfile(p) or os.path.getsize(p) > 4096:
            return False
        with open(p, encoding="utf-8", errors="replace") as f:
            return _HEAD.search(f.read(255)) is not None
    except OSError:
        return False


def git_dir_trusted(cwd: str) -> bool:
    """Claude Code refuses git in a directory whose repository could have been
    planted: a .git file or symlink pointing outside a `.git` directory (a
    bare-repo + worktree layout), or bare repository files lying around."""
    root = realish(cwd)

    def dot_git(d: str) -> str:
        def target(raw: str) -> str:
            t = os.path.normpath(os.path.join(d, raw))
            if not os.path.exists(t):
                return "plantable"
            t = os.path.realpath(t)
            if _inside(root, t):
                return "plantable"
            if not any(s.lower() == ".git" for s in t.split(os.sep)):
                return "plantable"
            return "trusted" if _head_valid(t) else "none"

        g = os.path.join(d, ".git")
        try:
            if os.path.islink(g):
                return target(os.readlink(g))
            if os.path.isfile(g):
                if os.path.getsize(g) > 65536:
                    return "plantable"
                with open(g, encoding="utf-8", errors="replace") as f:
                    content = f.read()
                if "\0" in content:
                    return "plantable"
                if not content.startswith("gitdir: "):
                    return "none"
                return target(content[8:].rstrip("\r\n"))
            if os.path.isdir(g):
                if not _head_valid(g):
                    return "none"
                for sub in ("objects", "refs"):
                    if not os.path.isdir(os.path.join(g, sub)):
                        return "none"
                return "none" if os.path.exists(os.path.join(g, "commondir")) else "trusted"
        except OSError:
            pass
        return "none"

    def bare_indicators(d: str) -> bool:
        head = os.path.join(d, "HEAD")
        if os.path.isfile(head) or os.path.islink(head):
            return True
        return any(os.path.exists(os.path.join(d, sub)) for sub in ("objects", "refs"))

    here = dot_git(root)
    if here != "none":
        return here == "trusted"
    d = root
    while True:
        if bare_indicators(d):
            return False
        parent = os.path.dirname(d)
        if parent == d:
            return True
        up = dot_git(parent)
        if up != "none":
            return up == "trusted"
        d = parent


def _cd_target(cmd: Command) -> Optional[str]:
    argv = unwrap(cmd.argv)
    return argv[1] if len(argv) == 2 and not cmd.env and not cmd.redirects else None


def _segment_read_only(source, commands, joins, cwd, root, cd_before: list) -> Optional[str]:
    """One pipe segment, as Claude Code checks a command without pipes.
    ``cd_before`` holds the directories earlier segments may have moved to."""
    # `cd <working directory>` changes nothing and is dropped.
    plain_cwd = re.search(r"[\s\\$`'\"*?[\]{}<>|&;()]", cwd) is None
    kept = [c for c in commands if not (plain_cwd and c.text == f"cd {cwd}" and _cd_target(c) is not None
                                       and not any(w.glob for w in c.words))]
    if not kept:
        return None
    cds = [c for c in kept if _is_cd(c.argv)]
    if len(cds) > 1:
        return "several cd"
    if len(cds) == 1 and any(_is_git(c) for c in kept):
        t = _cd_target(cds[0])
        if t is None or unwrap(cds[0].argv)[0] != "cd" or not _cd_keeps_repo(t, cwd):
            return "cd then git"
    # A leading `cd DIR &&` with a checkable DIR moves where later relative paths resolve.
    first = kept[0]
    leading = None
    if (len(kept) > 1 and len(kept) == len(commands) and first.argv[0] == "cd" and joins and joins[0] == "&&"
            and "||" not in source and ";" not in source and "\n" not in source
            and "&" not in source.replace("&&", "")):
        t = _cd_target(first)
        if (t is not None and not t.startswith("-")
                and (os.path.isabs(t) or t.startswith("./") or t.startswith("../") or t in (".", ".."))
                and (os.path.isabs(t) or ".." not in t.split("/"))
                and not re.search(r"[*?[\]]", t) and readable(root, cwd, t)):
            leading = realish(os.path.normpath(os.path.join(cwd, t)))
    # Claude Code resolves paths after any other cd against the working
    # directory; checking them against the cd target as well keeps a relative
    # path from slipping out through it.
    moved = list(cd_before)
    for cmd in kept:
        bases = [leading] if leading is not None and cmd is not first else [cwd, *moved]
        refusal = command_read_only(cmd) or _paths_readable(
            cmd, root, bases, leading is None and (len(cds) > 0 or len(cd_before) > 0))
        if refusal:
            return refusal
        t = _cd_target(cmd) if _is_cd(cmd.argv) else None
        if t is not None:
            moved.append(realish(os.path.normpath(os.path.join(cwd, _expand_home(t)))))
    if leading is not None:
        cd_before.append(leading)
    else:
        cd_before.extend(moved[len(cd_before):])
    return None


def read_only_refusal(source: str, cwd: str) -> Optional[str]:
    """None when the whole command is read-only, else why it still goes to the classifier."""
    script = parse(source)
    if not script or not script.commands:
        return "unparsed"
    root = realish(os.path.abspath(cwd))
    segments = [([script.commands[0]], [])]
    for i, j in enumerate(script.joins):
        nxt = script.commands[i + 1]
        if j == "|":
            segments.append(([nxt], []))
        else:
            segments[-1][1].append(j)
            segments[-1][0].append(nxt)
    if any(_is_git(c) for c in script.commands) and not git_dir_trusted(cwd):
        return "git repository not trusted"
    if len(segments) > 1:
        if sum(1 for cmds, _ in segments if _is_cd(cmds[0].argv)) > 1:
            return "several cd"
        cds = [c for c in script.commands if _is_cd(c.argv)]
        if cds and any(_is_git(c) for c in script.commands):
            if len(cds) > 1:
                return "several cd"
            t = _cd_target(cds[0])
            if t is None or unwrap(cds[0].argv)[0] != "cd" or not _cd_keeps_repo(t, cwd):
                return "cd then git"
    cd_before: list = []
    for cmds, joins in segments:
        refusal = _segment_read_only(source, cmds, joins, cwd, root, cd_before)
        if refusal:
            return refusal
    return None
