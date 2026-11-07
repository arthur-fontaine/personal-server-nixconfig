"""Claude Code 2.1.317's read-only command tables, as data.

Ported from Arthur's Pi extension auto-mode (nixconfig,
modules/home/programs/pi/extensions/auto-mode/readonly-tables.ts), itself
read from Claude Code's bundle (readOnlyCommandValidation.ts,
BashTool/readOnlyValidation.ts). Entry order matters: the first key whose
words start the command wins, as in Claude Code.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable, Optional


@dataclass(frozen=True)
class CommandConfig:
    safe_flags: dict
    regex: Optional[re.Pattern] = None
    respects_double_dash: bool = True
    # Gets the command text and the arguments after the matched key.
    is_dangerous: Optional[Callable[[str, list], bool]] = None


def before(s: str, sep: str) -> str:
    i = s.find(sep)
    return s if i == -1 else s[:i]


def is_flag(s: str) -> bool:
    return s.startswith("-") and len(s) > 1 and re.match(r"^-[a-zA-Z0-9_-]", s) is not None


def _any_tilde(args) -> bool:
    return any("~" in a for a in args)


def tilde_like(args) -> bool:
    """`~` the shell may expand inside an argument (`--x=~/a`, `a:~`), or brace-tilde forms."""
    return any(re.search(r"(?:^|[=:])~", a) or ("~" in a and "{" in a) for a in args)


def user_tilde(arg: str) -> bool:
    """`~user`: another user's home."""
    return re.match(r"^~(?!/|$)", arg) is not None


SIGNATURE_FORMAT = re.compile(r"%[-+ ]?G|%\(\*?signature")
PRETTY_NAMES = {"oneline", "short", "medium", "full", "fuller", "email", "raw"}


def _config_pretty(v: str) -> bool:
    # A --format/--pretty name that is not built in can be a pretty.<name> alias from git config.
    return v != "" and "%" not in v and not v.startswith("format:") and not v.startswith("tformat:") and v not in PRETTY_NAMES


def git_format_is_dangerous(_text: str, args: list) -> bool:
    """Signature placeholders run gpg; format values also reach config aliases."""
    def bad(v: str) -> bool:
        return tilde_like([v]) or bool(SIGNATURE_FORMAT.search(v)) or "signature" in v

    for i, a in enumerate(args):
        if SIGNATURE_FORMAT.search(a):
            return True
        for flag in ("--format", "--pretty", "--sort", "--group"):
            if a == flag and i + 1 < len(args):
                v = args[i + 1]
            elif a.startswith(flag + "="):
                v = a[len(flag) + 1:]
            else:
                continue
            if bad(v):
                return True
            if flag in ("--format", "--pretty") and _config_pretty(v):
                return True
    return False


def _reflog_is_dangerous(_text, args) -> bool:
    sub = args[0] if args else None
    if sub and not sub.startswith("-") and sub not in ("show", "list"):
        return True
    return any(a in ("expire", "delete", "exists", "drop", "write") for a in args)


def _ls_remote_is_dangerous(text, args) -> bool:
    if git_format_is_dangerous(text, args):
        return True
    dashdash = False
    i = 0
    while i < len(args):
        a = args[i]
        if not dashdash and a == "--":
            dashdash = True
        elif not dashdash and (not a or a.startswith("-")):
            if a == "--sort":
                i += 1
        else:
            return True
        i += 1
    return False


def _remote_show_is_dangerous(_text, args) -> bool:
    dd = args.index("--") if "--" in args else -1
    head = args if dd == -1 else args[:dd]
    names = [a for a in head if a != "-n"] + ([] if dd == -1 else args[dd + 1:])
    if len(names) != 1 or "-n" not in head:
        return True
    return re.match(r"^[a-zA-Z0-9_][a-zA-Z0-9_-]*$", names[0]) is None


def _remote_is_dangerous(_text, args) -> bool:
    return any(a not in ("-v", "--verbose") for a in args)


def _tag_is_dangerous(text, args) -> bool:
    """A positional argument creates a tag unless listing was asked for."""
    if git_format_is_dangerous(text, args):
        return True
    valued = {"--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format", "-n"}
    listing = dashdash = False
    i = 0
    while i < len(args):
        a = args[i]
        if not a:
            i += 1
            continue
        if a == "--" and not dashdash:
            dashdash = True
            i += 1
            continue
        if not dashdash and a.startswith("-"):
            if a in ("--list", "-l"):
                listing = True
            elif a[1:2] != "-" and len(a) > 2 and "=" not in a and "l" in a[1:]:
                listing = True
            i += 1 if "=" in a else (2 if a in valued else 1)
        else:
            if not listing:
                return True
            i += 1
    return False


def _branch_is_dangerous(text, args) -> bool:
    """A positional argument creates a branch unless listing was asked for or it follows --merged."""
    if git_format_is_dangerous(text, args):
        return True
    valued = {"--contains", "--no-contains", "--points-at", "--sort"}
    optional_value = {"--merged", "--no-merged"}
    last = ""
    listing = dashdash = False
    i = 0
    while i < len(args):
        a = args[i]
        if not a:
            i += 1
            continue
        if a == "--" and not dashdash:
            dashdash = True
            last = ""
            i += 1
            continue
        if not dashdash and a.startswith("-"):
            if a in ("--list", "-l"):
                listing = True
            elif a[1:2] != "-" and len(a) > 2 and "=" not in a and "l" in a[1:]:
                listing = True
            if "=" in a:
                last = before(a, "=")
                i += 1
            elif a in valued:
                last = a
                i += 2
            else:
                last = a
                i += 1
        else:
            if not listing and last not in optional_value:
                return True
            i += 1
    return False


# Flags that point docker at another daemon or config.
DOCKER_HOST_FLAGS = ["-H", "-c", "-r", "--host", "--context", "--config", "--tlscacert", "--tlscert", "--tlskey",
                     "--url", "--connection", "--identity", "--remote", "--module", "--out"]
DOCKER_HOST_LETTERS = {f[1] for f in DOCKER_HOST_FLAGS if len(f) == 2}


def docker_host_flag(args) -> bool:
    for a in args:
        if any(a == f or a.startswith(f + "=") or (len(f) == 2 and len(a) > 2 and a.startswith(f)) for f in DOCKER_HOST_FLAGS):
            return True
        m = re.match(r"^-([A-Za-z]+)", a)
        if m and len(m.group(1)) >= 2 and any(ch in DOCKER_HOST_LETTERS for ch in m.group(1)):
            return True
    return False


def _docker_is_dangerous(_text, args) -> bool:
    return docker_host_flag(args) or tilde_like(args)


def _sed_is_dangerous(_text, args) -> bool:
    return not sed_read_only(["sed", *args])


def _man_is_dangerous(_text, args) -> bool:
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--", "-") or not a.startswith("-"):
            break
        section = None
        if a in ("-S", "-s"):
            i += 1
            section = args[i] if i < len(args) else ""
        elif a.startswith("-S=") or a.startswith("-s="):
            section = a[2:]
        if section is not None and not re.match(r"^[A-Za-z0-9:,]+$", section):
            return True
        i += 1
    searching = {"-k", "-f", "--apropos", "--whatis"}
    search = False
    for a in args:
        if a == "--":
            break
        if not a.startswith("-") or a == "-":
            continue
        if a.startswith("--"):
            search = search or a in searching
        elif re.search(r"[kf]", a[1:]):
            search = True
    searched = operands = False
    i = 0
    while i < len(args):
        a = args[i]
        if not operands and a == "--":
            operands = True
            i += 1
            continue
        if not (operands or not a.startswith("-") or a == "-"):
            if a in searching:
                searched = True
            elif a in ("-S", "-s"):
                i += 1
            i += 1
            continue
        operands = True
        if search and a.startswith("-"):
            return True
        if not searched and ("/" in a or "\\" in a or "~" in a):
            return True
        i += 1
    return False


def _help_is_dangerous(_text, args) -> bool:
    return _any_tilde(args) or any("/" in a or "\\" in a for a in args)


def _ps_is_dangerous(_text, args) -> bool:
    """`e`/`E` print the environment; BSD ps takes them without a dash."""
    bsd_env = any(not is_flag(a) and re.search(r"[eE]", a) for a in args)
    env = any(re.match(r"^-[a-zA-Z]*e", a) for a in args)
    plain = all(a == "--forest" or re.match(r"^-[AacdeFfjlwHLTm]+$", a) for a in args)
    formats = [x for a in args for x in ([a] if a == "--forest" else re.findall(r"[HLTm]", a))]
    return bool(bsd_env) or (bool(env) and not (plain and len(formats) <= 1))


def _date_is_dangerous(_text, args) -> bool:
    """Only `+FORMAT` positionals: anything else sets the clock."""
    valued = {"-d", "--date", "-r", "--reference", "--rfc-3339"}
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith("--") and "=" in a:
            i += 1
        elif a.startswith("-"):
            i += 2 if a in valued else 1
        else:
            if not a.startswith("+"):
                return True
            i += 1
    return False


def _lsof_is_dangerous(_text, args) -> bool:
    """Host names in -i resolve through DNS."""
    for i, a in enumerate(args):
        if a.startswith("+m"):
            return True
        if re.match(r"^-[a-zA-Z]*i\S*@", a) and re.search(r"[a-zA-Z]", before(a[a.index("@") + 1:], ":")):
            return True
        if re.match(r"^-[a-zA-Z]*i$", a):
            nxt = args[i + 1] if i + 1 < len(args) else ""
            if "~" in nxt:
                return True
            if "@" in nxt and re.search(r"[a-zA-Z]", before(nxt[nxt.index("@") + 1:], ":")):
                return True
    return False


TPUT_WRITES = set("init reset rs1 rs2 rs3 is1 is2 is3 iprog if rf clear flash mc0 mc4 mc5 mc5i mc5p pfkey pfloc pfx pfxl smcup rmcup".split())


def _tput_is_dangerous(_text, args) -> bool:
    dashdash = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            dashdash = True
            i += 1
        elif not dashdash and a.startswith("-"):
            if a == "-S" or (not a.startswith("--") and len(a) > 2 and "S" in a):
                return True
            i += 2 if a == "-T" else 1
        else:
            if a in TPUT_WRITES:
                return True
            i += 1
    return False


def _ss_is_dangerous(_text, args) -> bool:
    """Filter words are fine; names that need resolving (hosts, services) are not."""
    keyword = re.compile(r"^(dst|src|dport|sport|and|or|not|eq|ne|ge|le|gt|lt|autobound|state|exclude|dev|fwmark|cgroup)$")
    takes_name = re.compile(r"^(state|exclude|dport|sport|dev|fwmark|cgroup)$")
    valued = re.compile(r"^(-f|--family|-A|--query|--socket)$")
    filt = []
    dashdash = False
    i = 0
    while i < len(args):
        a = args[i]
        if not dashdash and a == "--":
            dashdash = True
        elif not dashdash and a.startswith("-"):
            if valued.match(a):
                i += 1
        else:
            filt.append(a)
        i += 1
    if _any_tilde(filt):
        return True
    skip = False
    for w in [w for w in re.split(r"[\s()=!<>&|,]+", " ".join(filt)) if w]:
        if skip:
            skip = False
            continue
        if keyword.match(w):
            skip = bool(takes_name.match(w))
            continue
        if re.search(r"[g-zG-Z]", w) or (re.search(r"[a-fA-F]", w) and ("." in w or ":" not in w)):
            return True
    return False


NUMERIC_COMPARISONS = {"-eq", "-ne", "-lt", "-le", "-gt", "-ge"}
INTEGER = re.compile(r"^-?(0[xX][0-9a-fA-F]+|[0-9]+#[0-9a-zA-Z]+|[0-9]+)$")


def _test_is_dangerous(_text, args) -> bool:
    """Arithmetic operands are evaluated by the shell, `-v`/`-R` look up variables."""
    if any(a in ("-v", "-R", "-a", "-o") or "[" in a for a in args):
        return True
    for i, a in enumerate(args):
        if a in NUMERIC_COMPARISONS:
            for side in (args[i - 1] if i > 0 else None, args[i + 1] if i + 1 < len(args) else None):
                if side is not None and not INTEGER.match(side):
                    return True
        if a == "-t" and i + 1 < len(args) and not INTEGER.match(args[i + 1]):
            return True
    return False


# --- sed: read-only when it only prints lines (-n with Np/N,Mp) or substitutes on stdin ---

def sed_read_only(argv: list) -> bool:
    scripts = _sed_scripts(argv)
    if scripts is None:
        return False
    files = _sed_has_files(argv)
    prints = _sed_prints_only(argv, scripts)
    substitutes = _sed_substitutes_stdin(argv, scripts, files)
    if not prints and not substitutes:
        return False
    if substitutes and any(";" in s for s in scripts):
        return False
    return not any(_sed_script_dangerous(s) for s in scripts)


def _sed_scripts(argv):
    args = argv[1:]
    if not args or any(re.match(r"^-e[wWe]", a) or re.match(r"^-w[eE]", a) for a in args):
        return None
    scripts = []
    from_e = positional = False
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-e", "--expression") and i + 1 < len(args):
            from_e = True
            i += 1
            scripts.append(args[i])
        elif a.startswith("--expression="):
            from_e = True
            scripts.append(a[13:])
        elif a.startswith("-e="):
            from_e = True
            scripts.append(a[3:])
        elif a.startswith("-"):
            pass
        elif not from_e and not positional:
            scripts.append(a)
            positional = True
        else:
            break
        i += 1
    return scripts


def _sed_has_files(argv) -> bool:
    args = argv[1:]
    positional = 0
    from_e = False
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-e", "--expression") and i + 1 < len(args):
            from_e = True
            i += 2
            continue
        if a.startswith("--expression=") or a.startswith("-e="):
            from_e = True
        elif not a.startswith("-"):
            positional += 1
            if from_e or positional > 1:
                return True
        i += 1
    return False


def _only_flags(flags, allowed) -> bool:
    return all(all(f"-{c}" in allowed for c in f[1:]) if f.startswith("-") and not f.startswith("--") and len(f) > 2
               else f in allowed for f in flags)


def _sed_prints_only(argv, scripts) -> bool:
    flags = [a for a in argv[1:] if a.startswith("-") and a != "--"]
    if not _only_flags(flags, ["-n", "--quiet", "--silent", "-E", "--regexp-extended", "-r", "-z", "--zero-terminated", "--posix"]):
        return False
    if not any(f in ("-n", "--quiet", "--silent") or (not f.startswith("--") and "n" in f) for f in flags):
        return False
    return bool(scripts) and all(all(re.match(r"^(?:\d+|\d+,\d+)?p$", c.strip()) for c in s.split(";")) for s in scripts)


def _sed_substitutes_stdin(argv, scripts, files) -> bool:
    if files:
        return False
    flags = [a for a in argv[1:] if a.startswith("-") and a != "--"]
    if not _only_flags(flags, ["-E", "--regexp-extended", "-r", "--posix"]) or len(scripts) != 1:
        return False
    m = re.match(r"^s/(.*?)$", scripts[0].strip(), re.S)
    if not m:
        return False
    body = m.group(1)
    slashes, last, i = 0, -1, 0
    while i < len(body):
        if body[i] == "\\":
            i += 2
            continue
        if body[i] == "/":
            slashes += 1
            last = i
        i += 1
    return slashes == 2 and re.match(r"^[gpimIM]*[1-9]?[gpimIM]*$", body[last + 1:]) is not None


def _sed_script_dangerous(script: str) -> bool:
    """Commands that write files (w, W), run commands (e) or are hard to read statically."""
    n = script.strip()
    if not n:
        return False
    if re.search(r"[^\x01-\x7F]", n) or any(c in n for c in "{}\n\r"):
        return True
    h = n.find("#")
    if h != -1 and not (h > 0 and n[h - 1] == "s"):
        return True
    s = re.search
    if s(r"^!", n) or s(r"[/\d$]!", n):
        return True
    if s(r"\d\s*~\s*\d|,\s*~\s*\d|\$\s*~\s*\d", n) or s(r"^,", n) or s(r",\s*[+-]", n):
        return True
    if s(r"s\\", n) or s(r"\\[|#%@]", n) or s(r"\\/.*[wW]", n) or s(r"/[^/]*\s+[wWeE]", n):
        return True
    if s(r"^s/", n) and not s(r"^s/[^/]*/[^/]*/[^/]*$", n):
        return True
    if s(r"^s.", n) and s(r"[wWeE]$", n) and not s(r"^s([^\\\n]).*?\1.*?\1[^wWeE]*$", n):
        return True
    addr = (r"", r"\d+\s*", r"\$\s*", r"/[^/]*/[IMim]*\s*", r"\d+,\d+\s*", r"\d+,\$\s*", r"/[^/]*/[IMim]*,/[^/]*/[IMim]*\s*")
    if any(s("^" + a + r"[wW]\s*\S+", n) for a in addr):
        return True
    if any(s("^" + a + "e", n) for a in addr):
        return True
    sub = s(r"s([^\\\n]).*?\1.*?\1(.*?)$", n)
    if sub and s(r"[wWeE]", sub.group(2) or ""):
        return True
    return bool(s(r"y([^\\\n])", n) and s(r"[wWeE]", n))


# --- the tables ---

# Commands read-only with any arguments.
READONLY_COMMANDS = ["docker ps", "docker images"] + (
    "cal uptime cat head tail wc stat strings hexdump od nl id uname free df du locale groups nproc basename dirname "
    "realpath cut paste tr column tac rev fold expand unexpand fmt comm cmp numfmt readlink diff true false sleep which "
    "type expr seq tsort pr").split()

BARE_ONLY = {"pwd", "whoami", "alias"}

EXACT_COMMANDS = [["claude", "-h"], ["claude", "--help"], ["node", "-v"], ["node", "--version"],
                  ["python", "--version"], ["python3", "--version"], ["ip", "addr"]]

# find actions that write, delete or run something.
FIND_ACTIONS = {"-delete", "-rm", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fls", "-fprintf", "-files0-from"}
# find predicates that take an argument.
FIND_VALUED = set(("-name -iname -path -ipath -lname -ilname -regex -iregex -wholename -iwholename -samefile -newer "
                   "-anewer -cnewer -mnewer -perm -user -group -uid -gid -size -type -xtype -fstype -inum -links -used "
                   "-context -amin -cmin -mmin -atime -ctime -mtime -mindepth -maxdepth -printf -regextype -D -f -flags "
                   "-Bnewer -Btime -Bmin -files0-from -xattrname").split())
FIND_NEWER = re.compile(r"^-newer[aBcm][aBcmt]$")
FIND_TAKES_NEXT = re.compile(r"^-(?:[EHLPXdsx]*D|f|[dsx]*[EHLPX][EHLPXdsx]*f)$")
FIND_BAD_OPTION = re.compile(r"^-[dsx]+f$")


def _plain_command(cmd: str) -> re.Pattern:
    return re.compile("^" + re.escape(cmd) + r"(?:\s|$)[^<>()$`|{}&;\n\r]*$")


# Claude Code's text patterns, tried after the argument checks.
READONLY_PATTERNS = [_plain_command(c) for c in READONLY_COMMANDS] + [re.compile(p) for p in (
    r"""^echo(?:\s+(?:'[^']*'|"[^"$<>\n\r]*"|[^|;&`$(){}><#\\!"'\s]+))*(?:\s+2>&1)?\s*$""",
    r"^claude -h$", r"^claude --help$",
    r"^uniq(?:\s+(?:-[a-zA-Z]+|--[a-zA-Z-]+(?:=\S+)?|-[fsw]\s+\d+))*(?:\s|$)\s*$",
    r"^pwd$", r"^whoami$", r"^node -v$", r"^node --version$", r"^python --version$", r"^python3 --version$",
    r"^history(?:\s+\d+)?\s*$", r"^alias$", r"^arch(?:\s+(?:--help|-h))?\s*$", r"^ip addr$",
    r"^ifconfig(?:\s+[a-zA-Z][a-zA-Z0-9_-]*)?\s*$",
    r"""^jq(?!.*(?:\s['"]?-[a-zA-Z]*[fL]|--from-file|--rawfile|--slurpfile|--run-tests|--library-path|\benv\b|\$ENV\b|\binclude\b|\bimport\b))(?:\s+(?:-[a-zA-Z]+|--[a-zA-Z-]+(?:=\S+)?))*(?:\s+'[^'`]*'|\s+"[^"`]*"|\s+[^-\s'"][^\s]*)+\s*$""",
    r"""^cd(?:\s+(?:'[^']*'|"[^"]*"|[^\s;|&`$(){}><#\\]+))?$""",
    r"^ls(?:\s+[^<>()$`|{}&;\n\r]*)?$",
    r"^find(?:[ \t]+(?:\\[()]|(?!-delete\b|-rm\b|-exec\b|-execdir\b|-ok\b|-okdir\b|-fprint0?\b|-fls\b|-fprintf\b|-files0-from\b)[^<>()$`|{}&;\n\r\s]|[ \t])+)?$",
)]

# The only commands allowed to take unquoted globs.
GLOB_COMMANDS = set(("ls cat head tail wc stat grep egrep fgrep diff du df echo strings hexdump od nl cut column tr tac "
                     "rev cmp basename dirname realpath readlink sha256sum sha1sum md5sum cd").split())

# Environment variables a command prefix may set (with a value that is not a path).
SAFE_ENV = set(("GOEXPERIMENT GOOS GOARCH CGO_ENABLED GO111MODULE RUST_BACKTRACE RUST_LOG NODE_ENV PYTHONUNBUFFERED "
                "PYTHONDONTWRITEBYTECODE PYTEST_DISABLE_PLUGIN_AUTOLOAD PYTEST_DEBUG ANTHROPIC_API_KEY LANG LANGUAGE "
                "LC_ALL LC_CTYPE LC_TIME CHARSET TERM COLORTERM NO_COLOR FORCE_COLOR TZ LS_COLORS LSCOLORS GREP_COLOR "
                "GREP_COLORS GCC_COLORS TIME_STYLE BLOCK_SIZE BLOCKSIZE COLUMNS LINES CLICOLOR CLICOLOR_FORCE CI "
                "DEBIAN_FRONTEND GIT_TERMINAL_PROMPT").split())
PATH_LIKE = re.compile(r"^[.~]*[/\\]|[/\\][/\\]|:[/\\.]|(?:^|[/\\])\.\.(?:[/\\]|$)")

# What xargs may run.
XARGS_TARGETS = ["echo", "printf", "wc", "grep", "egrep", "fgrep", "head", "tail"]


def _f(spec: str) -> dict:
    """'--a -b:number --c:string' -> {"--a": "none", "-b": "number", "--c": "string"}"""
    out = {}
    for item in spec.split():
        name, _, kind = item.partition(":")
        out[name] = kind or "none"
    return out


REF_SCOPE = "--all --branches --tags --remotes"
DATE_FILTERS = "--since:string --after:string --until:string --before:string"
LOG_DISPLAY = "--oneline --graph --decorate --no-decorate --date:string --relative-date"
COUNT = "--max-count:number -n:number"
DIFF_STAT = "--stat --numstat --shortstat --name-only --name-status"
COLOR = "--color --no-color"
PATCH = "--patch -p --no-patch --no-ext-diff -s"
AUTHOR_FILTERS = "--author:string --committer:string --grep:string"
FD_FLAGS = _f(
    "-h --help -V --version -H --hidden -I --no-ignore --no-ignore-vcs --no-ignore-parent -s --case-sensitive -i "
    "--ignore-case -g --glob --regex -F --fixed-strings -a --absolute-path -L --follow -p --full-path -0 --print0 "
    "-d:number --max-depth:number --min-depth:number --exact-depth:number -t:string --type:string -e:string "
    "--extension:string -S:string --size:string --changed-within:string --changed-before:string -o:string "
    "--owner:string -E:string --exclude:string --ignore-file:string -c:string --color:string -j:number "
    "--threads:number --max-buffer-time:string --max-results:number -1 -q --quiet --show-errors --strip-cwd-prefix "
    "--one-file-system --prune --search-path:string --base-directory:string --path-separator:string "
    "--batch-size:number --no-require-git --hyperlink:string --and:string --format:string")
GREP_FLAGS = _f(
    "-e:string --regexp:string -f:string --file:string -F --fixed-strings -G --basic-regexp -E --extended-regexp -P "
    "--perl-regexp -i --ignore-case --no-ignore-case -v --invert-match -w --word-regexp -x --line-regexp -c --count "
    "--color:string --colour:string -L --files-without-match -l --files-with-matches -m:number --max-count:number -o "
    "--only-matching -q --quiet --silent -s --no-messages -b --byte-offset -H --with-filename -h --no-filename "
    "--label:string -n --line-number -T --initial-tab -u --unix-byte-offsets -Z --null -z --null-data -A:number "
    "--after-context:number -B:number --before-context:number -C:number --context:number --group-separator:string "
    "--no-group-separator -a --text --binary-files:string -I -D:string --devices:string -d:string "
    "--directories:string --exclude:string --exclude-from:string --exclude-dir:string --include:string -r "
    "--recursive -R --dereference-recursive --line-buffered -U --binary --help -V --version")
SUMS = _f("-b --binary -t --text -c --check --ignore-missing --quiet --status --strict -w --warn --tag -z --zero --help --version")

GIT_COMMANDS = {
    "git diff": CommandConfig(_f(
        f"{DIFF_STAT} {COLOR} --dirstat --summary --patch-with-stat --word-diff --word-diff-regex:string --color-words "
        "--no-renames --no-ext-diff --check --ws-error-highlight:string --full-index --binary --abbrev:number "
        "--break-rewrites --find-renames --find-copies --find-copies-harder --irreversible-delete "
        "--diff-algorithm:string --histogram --patience --minimal --ignore-space-at-eol --ignore-space-change "
        "--ignore-all-space --ignore-blank-lines --inter-hunk-context:number --function-context --exit-code --quiet "
        "--cached --staged --pickaxe-regex --pickaxe-all --no-index --relative:string --diff-filter:string -p -u -s -M "
        "-C -B -D -l -S:string -G:string -O:string -R")),
    "git log": CommandConfig(_f(
        f"{LOG_DISPLAY} {REF_SCOPE} {DATE_FILTERS} {COUNT} {DIFF_STAT} {COLOR} {PATCH} {AUTHOR_FILTERS} --abbrev-commit "
        "--full-history --dense --sparse --simplify-merges --ancestry-path --source --first-parent --merges --no-merges "
        "--reverse --walk-reflogs --skip:number --max-age:number --min-age:number --no-min-parents --no-max-parents "
        "--follow --no-walk --left-right --cherry-mark --cherry-pick --boundary --topo-order --date-order "
        "--author-date-order --pretty:string --format:string --diff-filter:string -S:string -G:string --pickaxe-regex "
        "--pickaxe-all"), is_dangerous=git_format_is_dangerous),
    "git show": CommandConfig(_f(
        f"{LOG_DISPLAY} {DIFF_STAT} {COLOR} {PATCH} --abbrev-commit --word-diff --word-diff-regex:string --color-words "
        "--pretty:string --format:string --first-parent --raw --diff-filter:string -m --quiet"),
        is_dangerous=git_format_is_dangerous),
    "git shortlog": CommandConfig(_f(
        f"{REF_SCOPE} {DATE_FILTERS} -s --summary -n --numbered -e --email -c --committer --group:string "
        "--format:string --no-merges --author:string"), is_dangerous=git_format_is_dangerous),
    "git reflog": CommandConfig(_f(f"{LOG_DISPLAY} {REF_SCOPE} {DATE_FILTERS} {COUNT} {AUTHOR_FILTERS}"),
                                is_dangerous=_reflog_is_dangerous),
    "git stash list": CommandConfig(_f(f"{LOG_DISPLAY} {REF_SCOPE} {COUNT}"), respects_double_dash=False),
    "git ls-remote": CommandConfig(_f(
        "--branches -b --tags -t --heads -h --refs --quiet -q --exit-code --get-url --symref --sort:string"),
        is_dangerous=_ls_remote_is_dangerous),
    "git status": CommandConfig(_f(
        "--short -s --branch -b --porcelain --long --verbose -v --untracked-files:string -u:string --ignored "
        "--ignore-submodules:string --column --no-column --ahead-behind --no-ahead-behind --renames --no-renames "
        "--find-renames:string -M:string")),
    "git blame": CommandConfig(_f(
        f"{COLOR} -L:string --porcelain -p --line-porcelain --incremental --root --show-stats --show-name "
        "--show-number -n --show-email -e -f --date:string -w --ignore-rev:string --ignore-revs-file:string -M -C "
        "--score-debug --abbrev:number -s -l -t"), respects_double_dash=False),
    "git ls-files": CommandConfig(_f(
        "--cached -c --deleted -d --modified -m --others -o --ignored -i --stage -s --killed -k --unmerged -u "
        "--directory --no-empty-directory --eol --full-name --abbrev:number --debug -z -t -v -f --exclude:string "
        "-x:string --exclude-from:string -X:string --exclude-per-directory:string --exclude-standard --error-unmatch "
        "--recurse-submodules")),
    "git config --get": CommandConfig(_f(
        "--local --global --system --worktree --default:string --type:string --bool --int --bool-or-int --path "
        "--expiry-date -z --null --name-only --show-origin --show-scope")),
    "git remote show": CommandConfig(_f("-n"), is_dangerous=_remote_show_is_dangerous),
    "git remote": CommandConfig(_f("-v --verbose"), is_dangerous=_remote_is_dangerous),
    "git merge-base": CommandConfig(_f("--is-ancestor --fork-point --octopus --independent --all")),
    "git rev-parse": CommandConfig(_f(
        "--verify --short:string --abbrev-ref --symbolic --symbolic-full-name --show-toplevel --show-cdup "
        "--show-prefix --git-dir --git-common-dir --absolute-git-dir --show-superproject-working-tree "
        "--is-inside-work-tree --is-inside-git-dir --is-bare-repository --is-shallow-repository --is-shallow-update "
        "--path-prefix")),
    "git rev-list": CommandConfig(_f(
        f"{REF_SCOPE} {DATE_FILTERS} {COUNT} {AUTHOR_FILTERS} --count --reverse --first-parent --ancestry-path "
        "--merges --no-merges --min-parents:number --max-parents:number --no-min-parents --no-max-parents "
        "--skip:number --max-age:number --min-age:number --walk-reflogs --oneline --abbrev-commit --pretty:string "
        "--format:string --abbrev:number --full-history --dense --sparse --source --graph"),
        is_dangerous=git_format_is_dangerous),
    "git describe": CommandConfig(_f(
        "--tags --match:string --exclude:string --long --abbrev:number --always --contains --first-match "
        "--exact-match --candidates:number --dirty --broken")),
    "git cat-file": CommandConfig(_f("-t -s -p -e --batch-check --allow-undetermined-type")),
    "git for-each-ref": CommandConfig(_f(
        "--format:string --sort:string --count:number --contains:string --no-contains:string --merged:string "
        "--no-merged:string --points-at:string"), is_dangerous=git_format_is_dangerous),
    "git grep": CommandConfig(_f(
        "-e:string -E --extended-regexp -G --basic-regexp -F --fixed-strings -P --perl-regexp -i --ignore-case -v "
        "--invert-match -w --word-regexp -n --line-number -c --count -l --files-with-matches -L --files-without-match "
        "-h -H --heading --break --full-name --color --no-color -o --only-matching -A:number --after-context:number "
        "-B:number --before-context:number -C:number --context:number --and --or --not --max-depth:number "
        "--untracked --no-index --recurse-submodules --cached --threads:number -q --quiet")),
    "git stash show": CommandConfig(_f(
        f"{DIFF_STAT} {COLOR} {PATCH} --word-diff --word-diff-regex:string --diff-filter:string --abbrev:number")),
    "git worktree list": CommandConfig(_f("--porcelain -v --verbose --expire:string")),
    "git tag": CommandConfig(_f(
        "-l --list -n:number --contains:string --no-contains:string --merged:string --no-merged:string --sort:string "
        "--format:string --points-at:string --column --no-column -i --ignore-case"), is_dangerous=_tag_is_dangerous),
    "git branch": CommandConfig(_f(
        "-l --list -a --all -r --remotes -v -vv --verbose --color --no-color --column --no-column --abbrev:number "
        "--no-abbrev --contains:string --no-contains:string --merged --no-merged --points-at:string --sort:string "
        "--show-current -i --ignore-case"), is_dangerous=_branch_is_dangerous),
}

COMMAND_ALLOWLIST = {
    "xargs": CommandConfig(_f("-I:{} -n:number -P:number -L:number -s:number -E:EOF -0 -t -r -x -d:char")),
    **GIT_COMMANDS,
    "file": CommandConfig(_f(
        "--brief -b --mime -i --mime-type --mime-encoding --apple --check-encoding -c --exclude:string "
        "--exclude-quiet:string --print0 -0 -F:string --separator:string --help --version -v --no-dereference -h "
        "--dereference -L --keep-going -k --list -l --no-buffer -n --preserve-date -p --raw -r -s --special-files")),
    "sed": CommandConfig(_f(
        "--expression:string -e:string --quiet --silent -n --regexp-extended -r --posix -E --line-length:number "
        "-l:number --zero-terminated -z --separate -s --unbuffered -u --debug --help --version"),
        is_dangerous=_sed_is_dangerous),
    "sort": CommandConfig(_f(
        "--ignore-leading-blanks -b --dictionary-order -d --ignore-case -f --general-numeric-sort -g "
        "--human-numeric-sort -h --ignore-nonprinting -i --month-sort -M --numeric-sort -n --random-sort -R --reverse "
        "-r --sort:string --stable -s --unique -u --version-sort -V --zero-terminated -z --key:string -k:string "
        "--field-separator:string -t:string --check -c --check-char-order -C --merge -m --buffer-size:string "
        "-S:string --parallel:number --batch-size:number --help --version")),
    "man": CommandConfig(_f("-a --all -d -f --whatis -h -k --apropos -w -S:string -s:string"), is_dangerous=_man_is_dangerous),
    "help": CommandConfig(_f("-d"), is_dangerous=_help_is_dangerous),
    "netstat": CommandConfig(_f("-a -L -l -n -f:string -g -i -I:string -s -r -m -v")),
    "ps": CommandConfig(_f(
        "-e -A -a -d -N --deselect -f -F -l -j -y -w -ww --width:number -c -H --forest --headers --no-headers "
        "-n:string --sort:string -L -T -m -C:string -G:string -g:string -p:string --pid:string -q:string "
        "--quick-pid:string -s:string --sid:string -t:string --tty:string -U:string -u:string --user:string --help "
        "--info -V --version"), respects_double_dash=False, is_dangerous=_ps_is_dangerous),
    "base64": CommandConfig(_f(
        "-d -D --decode -b:number --break:number -w:number --wrap:number -i:string --input:string --ignore-garbage "
        "-h --help --version"), respects_double_dash=False),
    "grep": CommandConfig(GREP_FLAGS),
    "egrep": CommandConfig(GREP_FLAGS),
    "fgrep": CommandConfig(GREP_FLAGS),
    "rg": CommandConfig(_f(
        "-e:string --regexp:string -f:string -i --ignore-case -S --smart-case -F --fixed-strings -w --word-regexp -v "
        "--invert-match -c --count -l --files-with-matches --files-without-match -n --line-number -o --only-matching "
        "-A:number --after-context:number -B:number --before-context:number -C:number --context:number -H -h "
        "--heading --no-heading -q --quiet --column -g:string --glob:string -t:string --type:string -T:string "
        "--type-not:string --type-list --hidden --no-ignore -u -m:number --max-count:number -d:number "
        "--max-depth:number -a --text -L --follow --color:string --json --stats --help --version --debug --")),
    "sha256sum": CommandConfig(SUMS),
    "sha1sum": CommandConfig(SUMS),
    "md5sum": CommandConfig(SUMS),
    "tree": CommandConfig(_f(
        "-a -d -l -f -x -L:number -P:string -I:string --gitignore --gitfile:string --ignore-case --matchdirs "
        "--metafirst --prune --info --infofile:string --noreport --charset:string --filelimit:number -q -N -Q -p -u "
        "-g -s -h --si --du -D --timefmt:string -F --inodes --device -v -t -c -U -r --dirsfirst --filesfirst "
        "--sort:string -i -A -S -n -C -X -J -H:string --nolinks --hintro:string --houtro:string -T:string "
        "--hyperlink --scheme:string --authority:string --fromfile --fromtabfile --fflinks --help --version")),
    "date": CommandConfig(_f(
        "-d:string --date:string -r:string --reference:string -u --utc --universal -I --iso-8601:string -R "
        "--rfc-email --rfc-3339:string --debug --help --version"), is_dangerous=_date_is_dangerous),
    "hostname": CommandConfig(_f(
        "-f --fqdn --long -s --short -i --ip-address -I --all-ip-addresses -a --alias -d --domain -A --all-fqdns -v "
        "--verbose -h --help -V --version"), regex=re.compile(r"^hostname(?:\s+(?:-[a-zA-Z]|--[a-zA-Z-]+))*\s*$")),
    "lsof": CommandConfig(_f(
        "-? -h -v -a -b -C -l -n -N -O -P -Q -R -t -U -V -X -H -E -F -g -i -K -L -o -r -s -S -T -x -A:string "
        "-c:string -d:string -e:string -k:string -p:string -u:string"), is_dangerous=_lsof_is_dangerous),
    "pgrep": CommandConfig(_f(
        "-d:string --delimiter:string -l --list-name -a --list-full -v --inverse -w --lightweight -c --count -f "
        "--full -g:string --pgroup:string -G:string --group:string -i --ignore-case -n --newest -o --oldest "
        "-O:string --older:string -P:string --parent:string -s:string --session:string -t:string --terminal:string "
        "-u:string --euid:string -U:string --uid:string -x --exact -F:string --pidfile:string -L --logpidfile "
        "-r:string --runstates:string --ns:string --nslist:string --help -V --version")),
    "tput": CommandConfig(_f("-T:string -V -x"), is_dangerous=_tput_is_dangerous),
    "ss": CommandConfig(_f(
        "-h --help -V --version -n --numeric -a --all -l --listening -o --options -e --extended -m --memory -p "
        "--processes -i --info -s --summary -4 --ipv4 -6 --ipv6 -0 --packet -t --tcp -M --mptcp -S --sctp -u --udp "
        "-d --dccp -w --raw -x --unix --tipc --vsock -f:string --family:string -A:string --query:string "
        "--socket:string -Z --context -z --contexts -b --bpf -E --events -H --no-header -O --oneline --tipcinfo "
        "--tos --cgroup --inet-sockopt"), is_dangerous=_ss_is_dangerous),
    "fd": CommandConfig(FD_FLAGS),
    "fdfind": CommandConfig(FD_FLAGS),
    "docker logs": CommandConfig(_f(
        "--follow -f --tail:string -n:string --timestamps -t --since:string --until:string --details"),
        is_dangerous=_docker_is_dangerous),
    "docker inspect": CommandConfig(_f("--format:string -f:string --type:string --size -s"), is_dangerous=_docker_is_dangerous),
    "test": CommandConfig(_f(
        "-b:string -c:string -d:string -e:string -f:string -g:string -G:string -h:string -k:string -L:string "
        "-N:string -O:string -p:string -r:string -s:string -S:string -t:string -u:string -w:string -x:string "
        "-z:string -n:string -eq:string -ne:string -lt:string -le:string -gt:string -ge:string -nt:string -ot:string "
        "-ef:string"), respects_double_dash=False, is_dangerous=_test_is_dangerous),
}
