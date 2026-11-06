---
name: instagram
description: Read and send the user's Instagram DMs, browse their feed and stories, and post, through instagram.com in your browser, where they are logged in.
version: 1.0.0
author: personal-server-nixconfig
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [Instagram, social media, messaging]
---

# Instagram

There is no public API for a personal account: you use https://www.instagram.com
in your browser tools, like a person would. The browser keeps one profile, so
the user's session stays logged in between tasks.

## Logged in?

Open https://www.instagram.com/. If it shows the login form:

1. Go to https://www.instagram.com/accounts/login/.
2. `browser_vault` `list`: the Instagram login (from the user's 1Password
   vault for you). Type its username yourself, then `fill` for the password,
   then submit.
3. A code asked for: `browser_vault` `enter_code` with the same login.
4. Never ask for the password in chat, and never try to read it. No login in
   the vault, or Instagram asks for something else (a checkpoint, "was this
   you?", a code sent elsewhere): stop and tell the user to log in again with
   scripts/bootstrap-macos.sh, over SSH while looking at the Mac.

## Do

DMs go through `direct.js`, which sits next to this file and runs inside the
page: it reads the inbox out of the app's own traffic and writes with the
app's own message box. Never call an Instagram endpoint yourself — its DM
paths are signed and renamed between releases, and a hand-built one is an
unofficial client.

```python
SCRIPT = open('/Users/hermes/.hermes/skills/social-media/instagram/direct.js').read()
cdp('Page.addScriptToEvaluateOnNewDocument', source=SCRIPT)  # every page load
# A narrow page only renders its empty state: work wide.
cdp('Emulation.setDeviceMetricsOverride', width=1280, height=900,
    deviceScaleFactor=1, mobile=False)
goto_url('https://www.instagram.com/direct/inbox/')
wait_for_load()
print(js('__ig.inbox()'))   # js() awaits, so send() and clear() come back settled
```

- `__ig.inbox()`: `{count, unread, threads, rows}`. `threads` are the app's own
  inbox rows: `{id, v2, name, users, text, at, unread}`, newest first. `id` is
  what `/direct/t/<id>/` takes (`v2` is the 128-bit form of the same thread);
  `text` is the preview the app itself shows — a real snippet, or "You sent a
  video."; `at` is milliseconds since the epoch. `rows` are the page's texts
  ("Camille 2 nouveaux messages · 17m Non lu"), for confirming a name or when
  `threads` comes back empty.
- A push notification that names no sender is answered from `threads`: the row
  whose snippet matches is who wrote, and `name`/`users` say who they are.
- `__ig.diag()`: `url`, `title`, `fromTraffic`, `rows`, the captured request
  URLs, the first one's key paths (`shape`), and whether a message box and a
  Send button are on the page. Read it first whenever something looks empty.
- `__ig.thread()`: `{id, text}` for the thread open in the tab — the transcript
  as the page shows it, names and times included.
- `__ig.send('text')`: types into the open thread's box, clicks the page's own
  Send button, waits, and returns `{sent, how, after}`. Read `after` to confirm
  it landed. The Send button only exists once the box has text (an empty box
  shows emoji, voice clip, photo and GIF instead), so `sendButton: false` in an
  empty thread is normal.
- `__ig.clear()`: empties the box without sending (`{cleared}`). Use it when a
  draft must not go out.

Open a thread with `goto_url('https://www.instagram.com/direct/t/<id>/')`.
Opening one marks its messages seen, and the user then gets no notification on
their phone; reading `inbox()` does not. So read the inbox first, and open a
thread only when the task needs what is inside it. Requests from people the
user does not follow are under "Requests" at the top of the inbox.

When it is empty:

1. `diag().fromTraffic` 0 with a login form in `inbox().page`: not logged in
   (see above). With `title` "Instagram • Messages" and nothing captured, the
   page loaded before the script was installed — load it again with the script
   in place.
2. `fromTraffic` 0 and `rows` 0: the page is still loading. Wait and ask again.
3. `shape` shows a payload but no threads: the app renamed its fields. Tell the
   user, with the `shape` you see, and read the open thread with `__ig.thread()`
   — do not invent a parser.

- Stories: the circles at the top of the home feed; a person's at
  https://www.instagram.com/stories/<username>/.
- Profiles and posts: https://www.instagram.com/<username>/.
- Post a photo or video: the "Create" (+) button in the sidebar. The desktop
  site cannot post stories: say so, and offer a post instead.
- When a page does not respond to the browser tools, computer use on the
  browser window works too.

## Care

- You act as the user, in front of real people. Send a DM, post, comment,
  like or follow only when the user asked for that, and confirm the exact text
  and recipient first unless they gave both. @confirm@
- Go at a person's pace: no bulk actions, no scraping loops, a few seconds
  between actions. Instagram locks accounts that behave like bots.
