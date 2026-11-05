# Sandboxed Pi sessions

With `server.hermes.sandbox.enable` (off by default; the bootstrap's Models
section asks), Hermes can hand a coding task on one of your git repositories
to [Pi](https://pi.dev) running in a [Gondolin](https://github.com/earendil-works/gondolin)
microVM, and read back what Pi did. Hermes is the only bridge between the VM
and this Mac: nothing Pi writes runs here before you review it.

## What Hermes can do

| Tool | What it does |
| --- | --- |
| `sandbox_run(task, repo?, ref?)` | bundles one ref of `repo` (its HEAD by default; a branch or a tag, not a bare commit id) and starts a session; returns its id at once. One session at a time |
| `sandbox_status(id?)` | its phase (image, boot, repo, pi, export), Pi's turns and tool calls so far; without an id, the last sessions |
| `sandbox_result(id)` | Pi's branch: its log, diffstat and diff, Pi's last answer (marked untrusted), and the `git fetch` that takes the branch |
| `sandbox_stop(id)` | stops it; what Pi committed so far stays readable |
| `sandbox_grants(id)` | what a running session may reach: its grants (host, method, path prefix), read only (the auto-review skips it) |
| `sandbox_revoke(id, host, method?, path_prefix?)` | takes one of those grants back; Pi's next request there asks again |

When a session ends, the chat that started it gets a notice (an internal
notification turn, like a background process' end) naming the session and
whether it left commits. It never carries Pi's own words: those reach Hermes
only as `sandbox_result`'s output, and the auto-review ([hermes.md](hermes.md))
never counts a notice as your message.

## What the VM gets

- **Files**: none of this Mac's. `/workspace` lives in the sidecar's memory
  (a Gondolin `MemoryProvider`), and the repository arrives as a git bundle,
  written into the VM and fetched there onto `sandbox/<id>`, with no remote
  pointing back. Never your working directory, never a mount.
- **Network**: HTTP and HTTPS only (Gondolin blocks other TCP; WebSockets are
  off), with synthetic DNS. Every request is checked on the host against the
  session's grants: at first `server.hermes.sandbox.allowedHosts`
  (`opencode.ai`) and `hermes.sandbox`, Hermes' broker as the guest names
  it; anything else Pi asks Hermes for (below), and a refusal is a 403.
  `hermes.sandbox` is answered by the sidecar itself, before any lookup, so
  its requests never leave this Mac; until the broker comes (a later stage)
  its answer is a 503. Each decision goes to the session's `audit.jsonl`,
  with the host, method and path, never headers or query. A grant can be
  narrowed to a method and a path prefix; paths are compared as the URL
  parser leaves them, never percent-decoded, and one still holding an
  encoded `/`, `\` or `.` (`%2F`, `%5C`, `%2E`) matches no path prefix, only
  a grant for the whole host: decoded, `/repos/a%2F..%2Fb` would pass for a
  path under `/repos/a`.
- **Secrets**: none. Pi reads `OPENCODE_API_KEY`, which in the guest is a
  random placeholder; the host swaps it for the real key
  (`server.hermes.sandbox.keyEnv`, `OPENCODE_GO_API_KEY` in the secrets
  file) in the headers of requests to opencode.ai only, and blocks it to any
  other host. The sidecar itself gets that key and no other variable of
  Hermes' environment.
- **Pi**: 1.5.0, headless (`--mode json --print`), on
  `opencode-go/deepseek-v4.1-flash` with thinking `high` (this model has no
  medium), the repository's own `.pi/` configuration ignored (`--no-approve`).

## When Pi needs another host

Nothing inside the VM is ever approved: Pi's commands, edits and tests run
freely there, as they would on a machine of its own. A question comes only
at Hermes' boundary, when Pi asks Hermes for something, here a host no grant
of the session covers. Pi asks Hermes for access; Hermes' approval system
decides, exactly as for one of Hermes' own tool calls:

1. The request waits (the guest sees a slow connection; a client whose own
   timeout is shorter than your answer gives up first, and asks again on its
   next try, where a grant you gave meanwhile lets it through). Requests to a host
   already being asked about wait for that one question, then are let
   through if its answer covers them (a grant, or the same request allowed
   once) and refused if it was refused.
2. With the auto-review on (`server.hermes.decision.approval`,
   [hermes.md](hermes.md)), its decision model, guard's own (same
   `~/.hermes/guard/config.json`, same review), rates the action
   `sandbox_network` {session, method, host, path} against your messages as
   guard held them when Hermes called `sandbox_run`, and nothing Pi wrote.
   Cleared, the request goes through; at low risk, its method and path
   prefix become a grant for the session.
3. Otherwise, or with the auto-review off, you get buttons in the main chat
   (the `owner_approval` plugin): the session, its task, the method, host
   and path (one line, cut), and **Once**, **GET /prefix this session** (the
   path's directory), **All of host this session**, **Deny**. No answer in
   `server.hermes.sandbox.approvalTimeout` (5 minutes), or no Telegram,
   refuses: the guest gets a 403.

A path holding an encoded `/`, `\` or `.` is never auto-reviewed and gets no
path button: only once, the whole host, or no. Addresses and names without
a dot (`1.2.3.4`, `localhost`, `*.local`, `*.internal`) are refused without a
question: no task needs them, and you could not judge them. The image needs
no host of its own (Pi runs offline, its telemetry and update check off), so
nothing else is allowed in advance. At most four questions per session wait
at once; more are refused.

Every decision is a line of the session's
`~/.hermes/sandbox/sessions/<id>/audit.jsonl`: the time, the session, the
request (method, scheme, host, path: never its headers or query), the
decision, who took it (`grant`, `guard`, `owner`, `timeout`, `unavailable`,
`limit`, `policy`, `error`), the outcome for the guest (allowed by a grant,
allowed once, allowed and granted for the session, refused: 403), the grant
involved and the reason (the auto-review's rating, the button tapped). The
grants added or revoked by hand are lines too.

## How it comes back

When Pi is done, what it left uncommitted becomes a last commit, and the
branch leaves the VM as a git bundle (`out.bundle`). `sandbox_result` fetches
it into a bare clone, `~/.hermes/sandbox/sessions/<id>/review.git`, and reads
it with git configured so that nothing in the bundle can run a program: no
hooks, no fsmonitor, no attributes (so no filters or diff drivers), no
external diff, no textconv, and neither the system's nor a user's git
config. A bare clone has no checkout, so nothing is ever written out as
files either. To take the branch, after reading it, in your repository:

```sh
git fetch ~hermes/.hermes/sandbox/sessions/<id>/review.git sandbox/<id>:sandbox/<id>
```

## The pieces

- `modules/hermes/plugins/sandbox`: the plugin (the tools; `runner.py`: the
  sessions, the bundles, the review). Its settings, from
  `modules/hermes/agent/sandbox.nix`, are in `~/.hermes/sandbox/config.json`.
- `modules/hermes/sandbox`: `hermes-sandbox` (`pkgs/hermes-sandbox.nix`), a
  Node sidecar, one process per session, speaking JSON lines on stdio with the
  plugin (`src/protocol.mjs`). It owns the VM and its network policy
  (`src/policy.mjs`: a grant set that can change while the VM runs, and the
  question to Hermes for what no grant covers; the plugin's `approval.py`
  answers it). If Hermes
  restarts, its sessions end with it (`sandbox_status` says "lost").
- `modules/hermes/sandbox/guest`: Pi's packages for the VM, from their own
  lockfile, installed by Nix for linux-arm64.

The guest image (Alpine 3.23 with Node, git, bash, ripgrep, fd and Pi's
tree) is built by Gondolin's own builder, without Docker, the first time a
session needs it, and again only when Pi's tree or the package list changes:
about half a minute and 500 MB under `~/.hermes/sandbox/images`, with the
builder's downloads in `~/.hermes/sandbox/cache`. The VM runs on QEMU with
Apple's hypervisor (`memory`, 3 GB, and `cpus`, 2, by default), at most one
at a time, stopped after `timeout` (two hours).

`sudo -iu hermes hermes-sandbox smoke` builds the image if need be and checks
the isolation with a made-up key: the guest sees only the placeholder, a host
without a grant gets 403, opencode.ai answers, `hermes.sandbox` is answered
by the sidecar (503), Pi starts.

## Not yet

A broker for typed actions (a push, say) on Pi's behalf, and Pi's advisor
are the next stages.
