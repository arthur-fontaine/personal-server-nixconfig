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

There is no API for a personal account: you use https://www.instagram.com in
your browser tools, like a person would. The browser keeps one profile, so the
user's session stays logged in between tasks.

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

- DMs: https://www.instagram.com/direct/inbox/ (a thread: click it; read the
  messages from the page). Requests are under "Requests".
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
  and recipient first unless they gave both.
- Go at a person's pace: no bulk actions, no scraping loops, a few seconds
  between actions. Instagram locks accounts that behave like bots.
