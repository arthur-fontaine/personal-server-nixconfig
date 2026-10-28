---
name: discord
description: Read and send the user's Discord messages (DMs and servers) through discord.com in your browser, where they are logged in.
version: 1.0.0
author: personal-server-nixconfig
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [Discord, messaging]
---

# Discord

You use https://discord.com in your browser tools, as the user, like a person
would: there is no API for a user account. The browser keeps its session; a
Discord tab stays open in the background so its notifications reach you as
events (leave that tab alone and work in your own).

## Logged in?

Open https://discord.com/channels/@me. If it shows the login page:

1. `browser_vault` `list`: the Discord login (the user's 1Password vault for
   you). Type its email yourself, `fill` the password, submit.
2. A code asked for: `browser_vault` `enter_code` with the same login.
3. Never ask for the password in chat. A captcha, a "new login location" email
   check, or no login in the vault: stop, and tell the user to log in again
   with scripts/bootstrap-macos.sh, over SSH while looking at the Mac.

## Read

- DMs: https://discord.com/channels/@me, then the conversation in the list.
- A server channel: https://discord.com/channels/<server id>/<channel id>, or
  click the server, then the channel.
- Unread: the white dot or number on a server or a DM; mentions: the inbox
  (the tray icon, top right).
- Search: the search box at the top right of a channel or DM (`from:`, `in:`,
  `has:`, `before:` / `after:` filters).

## Send

You write as the user, to real people: only send what the user asked for,
to who they asked; confirm the recipient and the exact text first unless they
gave both. Click the message box at the bottom, type, press Enter (Shift+Enter
for a new line). Check that it appears in the conversation.

## Care

Go at a person's pace: no bulk sends, no scraping loops, a few seconds between
actions. Discord bans accounts that behave like bots.
