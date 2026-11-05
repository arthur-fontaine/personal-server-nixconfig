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
  it; anything else Pi asks Hermes for (below), and a refusal is a 403
  whose body tells Pi what it means: `403 Forbidden: not granted for this
  sandbox session; ask Hermes with request_host_action, once` (decided in
  Gondolin's `onRequest`, which may answer with a body of ours; its
  `isRequestAllowed` only admits what that decision let through).
  `hermes.sandbox` is answered by the sidecar itself, before any lookup, so
  its requests never leave this Mac: it is Hermes' broker (below). Each decision goes to the session's `audit.jsonl`,
  with the host, method and path, never headers or query. A grant can be
  narrowed to a method and a path prefix; paths are compared as the URL
  parser leaves them, never percent-decoded, and one still holding an
  encoded `/`, `\` or `.` (`%2F`, `%5C`, `%2E`) matches no path prefix, only
  a grant for the whole host: decoded, `/repos/a%2F..%2Fb` would pass for a
  path under `/repos/a`.
- **Secrets**: none of this Mac's. The one value the guest holds is the
  broker's token (`HERMES_BROKER_TOKEN`), made for the session and dead once
  Pi is done. Pi reads `OPENCODE_API_KEY`, which in the guest is a
  random placeholder; the host swaps it for the real key
  (`server.hermes.sandbox.keyEnv`, `OPENCODE_GO_API_KEY` in the secrets
  file) in the headers of requests to opencode.ai only, and blocks it to any
  other host. The sidecar itself gets that key and no other variable of
  Hermes' environment.
- **Pi**: 1.5.0, headless (`--mode json --print`), on
  `opencode-go/deepseek-v4.1-flash` with thinking `high` (this model has no
  medium), set in Pi's own settings, the repository's `.pi/` configuration
  ignored (`--no-approve`), with two extensions of ours: `request_host_action`
  (below) and `sandbox-environment`, and an advisor (next section).

## What Pi is told

`pi/extensions/sandbox-environment` adds a `<sandbox_environment>` section
to Pi's system prompt (Pi's `before_agent_start`, its
`systemPromptOptions.sections`), rendered from the facts the session writes
to `/root/.pi/agent/sandbox.json`: the repository and its branch, the hosts
granted at the start, the broker's host, `/host`. It says that Pi runs
headless in an isolated VM with no one watching; that its committed branch
is the result, whose diff Hermes shows you; that there is no file of this
Mac and no secret in the VM; that a 403 means not granted, not a network
fault to debug, and that it asks once with `request_host_action` and works
without what was denied; that registries are blocked until granted; what
each action is for (`shell` runs on this Mac, only with your yes); and to
finish with a summary. Not `APPEND_SYSTEM.md` in Pi's agent directory: a
trusted repository's `.pi/APPEND_SYSTEM.md` would replace it, and the
repository is the task's content, not its configuration.

## Pi's advisor

Pi runs with [pi-advisor-flow](https://github.com/philipbrembeck/pi-advisor)
0.14.4 (pinned in `pi/package.json` and its lockfile, loaded by path from
the guest's `node_modules`, since Pi cannot install an `npm:` package
offline). Pi is the executor; it gets an `ask_advisor` tool and is prompted
to call it at its plan, after a failure and before it says it is done, and
the flow calls it on its own when Pi repeats the same tool call three
times. The advisor is a second request to a model with a bounded view of
the session; its answer comes back to Pi as advice, nothing more. Nothing
inside the VM is approved by it: it is Pi's reviewer, not Hermes'.

Its configuration is `pi/advisor.json`, which a session writes to Pi's
agent directory (`/root/.pi/agent/advisor.json`, the only one the flow
reads: a repository's own is ignored), with `server.hermes.sandbox.model`
and `thinking` as the executor's and `server.hermes.sandbox.advisor` over it:

| Setting | Value | Why |
| --- | --- | --- |
| `advisor.model` (`advisor`) | `opencode-go/deepseek-v4.1-flash`, Pi's own | through the same provider, so the same placeholder key and host, opencode.ai: no new grant. `advisorDisableSameModel` is `false`, or the flow would skip a same-model advisor |
| `advisor.effort` (`advisorEffort`) | `max` | this model takes `low`, `high` or `max` (pi-ai's opencode-go catalog); the executor stays at `high` |
| `advisor.maxCalls` (`advisorMaxCallsPerSession`) | 5 | Pi's calls and the automatic gate's together; later ones are refused and Pi goes on alone |
| `advisor.contextMaxChars` (`contextMaxChars`) | 15,000 | how much of the conversation one call carries |
| `advisorToolResultMaxBytes` | 20,000 | a tool's output, cut, in that view |
| `advisorRedactSecrets` | `true` | the flow's own redaction of what it sends (the guest holds no secret anyway) |
| `advisorSessionSummary` | `true` | its usage summary at the end (shown only with a UI) |
| `alwaysOn` | `true` | active from the session's start: `pi -p` never runs `/advisor` |
| `simpleMode` | `false` | Simple mode lifts the call budget |
| `gateFailureMode` | `block-tool` | a gate that fails, blocks or finds the budget spent refuses that one tool call; the default would abort the whole run |
| `advisorHerdrIntegration`, `advisorScoutEnabled`, `advisorJevFilterEnabled` | `false` | nothing but the model: no terminal integration, no scout, no classifier endpoint |

`server.hermes.sandbox.advisor.enable = false` writes the same file with the
flow off (`alwaysOn` and its tools off).

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
3. Otherwise, or without a decision model, you get buttons in the main chat
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

## What else Pi can ask Hermes for

Pi has one tool for Hermes, `request_host_action`, which sends one typed
action to the broker, `POST https://hermes.sandbox/v1/actions`. The sidecar
answers it, never the network. Each call needs the session's bearer token
(made by the plugin at launch with `secrets.token_urlsafe`, given to the
sidecar in its environment and to the guest as `HERMES_BROKER_TOKEN`,
checked in constant time). It is revoked when Pi is done or the session
stops, and every later call gets a 401. The body is JSON, 16 KB at most, and
each action has a strict schema: a field it does not name is a 400. No action
has a field for Pi's reasons. The action is judged on its own, as the
planned action `sandbox_<action>` {session, …its fields}, by the same two
steps as a host: the auto-review against your messages from `sandbox_run`,
then your buttons.

| Action | Fields | What Hermes does when it is allowed |
| --- | --- | --- |
| `request_host` | `host`, `method?`, `pathPrefix?` | adds the grant to the session, before Pi's requests need it. The auto-review grants it at low risk; otherwise you get **Grant it this session** / **Deny**. No question about an address or a bare name (refused) |
| `request_folder` | `path` (absolute, or `~/…`: Hermes' home) | resolves it on this Mac (the card shows the absolute path, and what Pi typed if it differs) and copies it into the sidecar's memory, where the guest reads it under `/host/<name>` through Gondolin's `ReadonlyProvider`. It is a snapshot taken when you say yes, never a mount, never written back, and read-only even to the guest's root. Regular files, folders, and the symlinks that resolve inside the folder (recreated as relative links); a link out of it is left out. At most 20,000 entries and 200 MB, checked before you are asked. A copy can leave through any host the VM reaches, so secret locations are refused, unasked: under Hermes' home and the administrator's (`server.admin.home`, which Hermes reads), `.ssh`, `.gnupg`, `.aws`, `.config`, `.hermes`, `.pi`, `.docker`, `.kube`, `.password-store`, `.local/share/keyrings`, `Library/Keychains`, `Library/Application Support` (browser profiles, password managers), `Library/Cookies`, `Library/Containers`, `Library/Group Containers`; and `/etc` (`/private/etc`), `/Library/Hermes`, `/Library/Keychains`, `/var/root`, `/var/db`. So is any folder inside one or holding one (a home itself, `/Users`, `/`). They are matched on the resolved path, as APFS compares names (any case, `/System/Volumes/Data/…` as its usual path), and by device and inode. A refused folder, a missing one and one Hermes' account cannot read all get the same error. The auto-review clears a folder at low risk only; otherwise your buttons (**Copy it in, read-only** / **Deny**) |
| `git_push` | `branch` | only the session's own branch, `sandbox/<id>` or `sandbox/<id>-<name>`, and only when the session came from a repository with an `origin`. The branch leaves the VM as a bundle, is fetched into the review clone (`review.git`), and is pushed from there to `origin`'s URL by this Mac's git. Hooks are off, `ext::` transports are refused, there is no checkout and no force, so a branch already pushed only fast-forwards. The card shows the repository, the remote (without credentials), the head and the commits since the session began |
| `ask_user` | `question`, `choices` (2 to 4) | sends you the question, marked as Pi's words, with its choices and **Don't answer**. Pi gets the choice you tap. It is not auto-reviewed, since you are the one asked. At most 10 per session |
| `shell` | `command`, `cwd?` | **always your buttons** (**Run it once** / **Deny**), even when the auto-review would clear it: its rating goes on the card. The command runs with `bash -c` as Hermes' account, in a new temporary folder under `~/.hermes/sandbox/shell` (or `cwd`, resolved like a folder). Its environment is rebuilt from nothing (`PATH`, `HOME`, `LANG`, `TMPDIR`), so no variable of the secrets file comes along. It is stopped after 2 minutes. Pi gets the exit code and at most 4 KB of output, passed through Hermes' redaction (`agent/redact.py`) |

The answer Pi gets is minimal: `{ok, status, result?}`, `status` being
`allowed`, `denied`, `timeout` or `error`. It never carries the auto-review's
reasons, never a path of this Mac beyond what Pi sent, never a secret. The
`result` is the grant, the folder's `/host` path and file count, `pushed`,
the answer, or the command's exit code and output. A denial or a timeout is
final for the session: the same action asked again gets the same answer
without a question. At most four actions wait at once (a 429 beyond), and so
do at most four questions to you per session. A decision taken after the
session ended does nothing.

Every decision is a line of the session's
`~/.hermes/sandbox/sessions/<id>/audit.jsonl`: the time, the session, the
request (method, scheme, host, path: never its headers or query), the
decision, who took it (`grant`, `guard`, `owner`, `timeout`, `unavailable`,
`limit`, `policy`, `error`), the outcome for the guest (allowed by a grant,
allowed once, allowed and granted for the session, refused: 403), the grant
involved and the reason (the auto-review's rating, the button tapped). The
grants added or revoked by hand are lines too, and so is every broker call
(`event: "action"`): the action, its typed fields (never the token), the
decision (`allowed`, `denied`, `timeout`, `error`), who took it (`guard`,
`owner`, `policy`, `limit`, `final` for a denial repeated, `broker` for a call
refused before any decision: 401, 400, 413…) and the outcome (granted,
copied N files to /host/…, pushed, ran with exit N…).

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

All in `modules/hermes/coding-agent`:

- `default.nix`: the options (`server.hermes.sandbox`) and Hermes' wiring:
  the plugin, and its settings in `~/.hermes/sandbox/config.json`.
- `hermes-plugin/`: the plugin, `sandbox` to Hermes (the tools; `runner.py`:
  the sessions, the bundles, the review; `approval.py`: the auto-review and
  the buttons; `actions.py`: the broker's actions).
- `sidecar/`: `hermes-sandbox` (`pkgs/hermes-sandbox.nix`), a
  Node sidecar, one process per session, speaking JSON lines on stdio with the
  plugin (`src/protocol.mjs`). It owns the VM and its network policy
  (`src/policy.mjs`: a grant set that can change while the VM runs, and the
  question to Hermes for what no grant covers; the plugin's `approval.py`
  answers it) and the broker (`src/broker.mjs`; `src/folders.mjs` copies a
  folder in). If Hermes
  restarts, its sessions end with it (`sandbox_status` says "lost").
- `pi/`: Pi as the image has it: its packages (Pi, pi-advisor-flow), from
  their own lockfile, installed by Nix for linux-arm64; `settings.json` (its
  model, thinking level, packages and extensions; a session writes it to
  Pi's agent directory with `server.hermes.sandbox.model` and `thinking`
  over it); `advisor.json`, the advisor's (above);
  `extensions/request-host-action`, the `request_host_action` tool; and
  `extensions/sandbox-environment`, what Pi is told (above).
- `tests/`: the plugin's tests, against a fake sidecar
  (`nix build .#checks.aarch64-darwin.coding-agent`); the sidecar's run in
  its build (`checks.aarch64-darwin.sandbox`).

The guest image (Alpine 3.23 with Node, git, bash, ripgrep, fd and Pi's
tree) is built by Gondolin's own builder, without Docker, the first time a
session needs it, and again only when Pi's tree or the package list changes:
about half a minute and 500 MB under `~/.hermes/sandbox/images`, with the
builder's downloads in `~/.hermes/sandbox/cache`. The VM runs on QEMU with
Apple's hypervisor (`memory`, 3 GB, and `cpus`, 2, by default), at most one
at a time, stopped after `timeout` (two hours).

`sudo -iu hermes hermes-sandbox smoke` builds the image if need be and checks
the isolation with a made-up key: the guest sees only the placeholder, a host
without a grant gets the 403 above, opencode.ai answers, `hermes.sandbox` is answered
by the sidecar: 401 without the token, an answer with it, 400 for an unknown
field, 401 once the token is revoked; Pi's environment section renders in
the guest. Last, Pi starts.
