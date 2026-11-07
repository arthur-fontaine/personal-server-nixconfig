"""guard's Bash read-only check (readonly.py), ported with the Pi extension
auto-mode's tests/readonly.test.ts and the Bash half of fastpath.test.ts."""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from guard.readonly import git_dir_trusted, parse, read_only_refusal  # noqa: E402

# A repository laid out as git makes one, without running git.
repo = os.path.realpath(tempfile.mkdtemp(prefix="guard-ro-"))
os.makedirs(os.path.join(repo, ".git", "objects"))
os.makedirs(os.path.join(repo, ".git", "refs"))
Path(repo, ".git", "HEAD").write_text("ref: refs/heads/main\n")
os.makedirs(os.path.join(repo, "src"))
Path(repo, "a.txt").write_text("a\n")
Path(repo, "b.txt").write_text("b\n")

# A worktree of a bare repository kept in `.bare`.
bare = os.path.realpath(tempfile.mkdtemp(prefix="guard-bare-"))
gitdir = os.path.join(bare, ".bare", "worktrees", "main")
os.makedirs(gitdir)
Path(gitdir, "HEAD").write_text("ref: refs/heads/main\n")
os.makedirs(os.path.join(bare, "main"))
Path(bare, "main", ".git").write_text(f"gitdir: {gitdir}\n")
worktree = os.path.join(bare, "main")


def allowed(cmd: str, cwd: str = repo) -> None:
    assert read_only_refusal(cmd, cwd) is None, (cmd, read_only_refusal(cmd, cwd))


def refused(cmd: str, why: "str | None" = None, cwd: str = repo) -> None:
    refusal = read_only_refusal(cmd, cwd)
    assert refusal is not None, cmd
    if why:
        assert refusal == why, (cmd, refusal)


def test_parser() -> None:
    script = parse("LANG=C grep -n 'a b' \"c\" x\\ y 2>&1 && ls *.ts | wc -l\n# note\n")
    assert [(c.env, c.argv, c.redirects) for c in script.commands] == [
        ([("LANG", "C")], ["grep", "-n", "a b", "c", "x y"], [(">&", "1")]),
        ([], ["ls", "*.ts"], []),
        ([], ["wc", "-l"], []),
    ]
    assert script.joins == ["&&", "|"]
    assert script.commands[1].words[1].glob
    assert not parse("ls '*.ts'").commands[0].words[1].glob
    for opaque in ["echo $HOME", 'echo "$(id)"', "ls `pwd`", "(ls)", "{ ls; }", "cat <<EOF\nx\nEOF", "cat <<< x",
                   "diff <(ls) <(ls)", "sleep 1 &", "X=1", "ls &&", "; ls", "echo 'open", "ls |& cat"]:
        assert parse(opaque) is None, opaque


def test_read_only() -> None:
    for cmd in [
        "ls -la", "cat a.txt | grep -n x | wc -l", "find . -name '*.ts' -type f -maxdepth 2", "sed -n 1,20p a.txt",
        "sed -n '1p;5,9p' a.txt", "cat a.txt | sed 's/a/b/g'", "head -n 5 a.txt && tail -n 5 a.txt; wc -c a.txt",
        "grep -rn foo src 2>/dev/null | head -20", "grep -A3 -i foo a.txt", "rg -n --hidden -g '*.ts' foo",
        "jq -r '.name' a.txt", "sort -u a.txt | uniq -c", "ls *.txt", "wc -l *.txt", "diff a.txt b.txt",
        "tree -L 2", "file a.txt; stat a.txt", "echo hi; pwd; date +%Y", "printf '%s\\n' x", "test -f a.txt",
        "fd -e ts", "find . -type f | xargs grep -l foo", "LANG=C sort a.txt", "command ls src",
        "ls\n# a comment\nls src\n", "cat < a.txt", "git log -5 > /dev/null 2>&1", "cd src && ls",
    ]:
        allowed(cmd)


def test_git() -> None:
    for cmd in ["git status --short", "git log --oneline -5", "git log --format='%h %s' -n 3", "git diff --stat HEAD~1",
                "git diff a.txt", "git show HEAD --stat", "git branch -a", "git branch --merged main", "git tag -l 'v*'",
                "git rev-parse --show-toplevel", "git ls-files src", "git blame -L 1,5 a.txt",
                "git config --get user.name", "git remote -v", "git stash list", "git worktree list",
                "git grep -n foo src"]:
        allowed(cmd)
    for cmd in ["git log --output=x", "git diff --output=x", "git show --output=x", "git branch -D main",
                "git branch new-branch", "git tag v1", "git fetch", "git push", "git stash", "git reflog expire --all",
                "git remote add x y", "git config user.name x", "git -c core.pager=x log", "git -C src log",
                "git --no-pager log", "git log --format=%G?", "git log --pretty=myalias", "git ls-remote origin",
                "git diff /etc/hosts"]:
        refused(cmd)


def test_writes() -> None:
    for cmd in ["find . -exec cat {} \\;", "find . -delete", "find . -fprint out", "find *.ts", "sed -i 's/a/b/' a.txt",
                "sed 's/a/b/' a.txt", "cat a.txt | sed 's/a/b/w out'", "sed -n '1e date' a.txt", "sort -o out a.txt",
                "tree -o out", "date 0101", "ps e", "xargs rm", "rg --pre cat foo", "grep 'end$' a.txt", "echo x > f",
                "ls >> f", "ls 2> err", "FOO=bar ls", "LANG=./x ls", "npm test", "env", "awk '{print}' a.txt",
                "cat ~root/x", "[ -f a.txt ]", "curl https://x"]:
        refused(cmd)


def test_paths() -> None:
    for cmd in ["cat /etc/hosts", "base64 --input=/etc/hosts", "ls ~", "cat ../x", "grep foo /etc/passwd", "ls /",
                "cat src/../../x", "cat < /etc/hosts", "ls /etc/*", "ls src/../src"]:
        refused(cmd)
    allowed(f"cat {os.path.join(repo, 'a.txt')}")


def test_cd() -> None:
    allowed("cd src && ls")
    allowed("cd ./src && cat ../a.txt")
    allowed(f"cd {repo} && git log -1")
    allowed(f"cd {repo} && git status | head")
    allowed("cd . && git status")
    refused("cd /tmp && ls", "outside the working directory")
    refused("cd", "outside the working directory")
    refused("cd - && ls", "cd -")
    refused("cd src && cd .. && ls", "several cd")
    refused("cd src && git status", "cd then git")
    refused("cd src | git status", "cd then git")
    refused("cd src && command git log", "cd then git")
    refused("cd src; cat ../../x", "outside the working directory")
    refused("cd src; cat < a.txt", "input redirect after cd")


def test_planted_git() -> None:
    assert git_dir_trusted(repo)
    assert not git_dir_trusted(worktree)
    refused("git status", "git repository not trusted", worktree)
    refused("command git status", "git repository not trusted", worktree)
    allowed("ls", worktree)


def main() -> None:
    try:
        for name, fn in list(globals().items()):
            if name.startswith("test_") and callable(fn):
                fn()
                print("ok", name)
    finally:
        shutil.rmtree(repo, ignore_errors=True)
        shutil.rmtree(bare, ignore_errors=True)


if __name__ == "__main__":
    main()
