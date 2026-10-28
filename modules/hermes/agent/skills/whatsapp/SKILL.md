---
name: whatsapp
description: Read, search and send the user's WhatsApp messages with the wacli CLI (a linked device of their number).
version: 1.0.0
author: personal-server-nixconfig, adapted from OpenClaw's wacli skill (MIT)
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [WhatsApp, messaging]
prerequisites:
  commands: [wacli]
---

# WhatsApp

`wacli` is a linked device of the user's own WhatsApp number (like WhatsApp
Web). A daemon (`wacli sync --follow`) mirrors every chat into a local store,
so reading and searching work offline and are instant. The user talks to you
on Telegram, not WhatsApp: here you act on their WhatsApp, as them.

Adapted from https://github.com/openclaw/openclaw/blob/1aea2df9351969f6cbac4bc17abcbb71a1720670/extensions/whatsapp/skills/wacli/SKILL.md.

## Setup check

- `wacli --json auth status`: `"authenticated": false` means the user has not
  linked it yet. Tell them to run scripts/bootstrap-macos.sh again over SSH,
  which shows the QR code to scan (WhatsApp → Settings → Linked devices).
- `wacli doctor` diagnoses the store and the connection.

## Read and search

- Recent chats: `wacli --json chats list --limit 20`, or `--query "name or number"`.
- Search: `wacli --json messages search "words" --limit 20 [--chat <jid>]`,
  with `--after 2026-01-01 --before 2026-02-01` or `--has-media`.
- One message: `wacli --json messages show --chat <jid> --id <message_id> --full`
  (both flags are required).
- Older history of a chat: `wacli history backfill --chat <jid> --requests 2 --count 50`
  (needs the phone online; best effort).
- Media: `wacli media download --chat <jid> --id <message_id>`.
- Add `--read-only` to any read so it never takes the store's write lock.

## Send

You write as the user, to real people: only send when the user asked for that
message to that person. Confirm the recipient and the exact text first, unless
they gave both explicitly in the same request.

- Text: `wacli send text --to "+33612345678" --message "…"`; a group:
  `--to "<id>@g.us"`; a synced contact or chat name works too.
- Multiline: `--message` is literal; add `--message-escapes` for `\n`.
- File: `wacli send file --to <recipient> --file /path/file.pdf --caption "…"`.
- After sending, check what was stored when the formatting matters:
  `wacli --json messages search "<a few words>" --chat <jid> --limit 1`.

JIDs: `<number>@s.whatsapp.net` for people, `<id>@g.us` for groups
(`wacli --json chats list` gives them).
