# Events: Hermes writes first

When something happens that may call for you, Hermes looks into it and
proposes what to do, in the main chat. For example: Martin asks on WhatsApp
for a drink tonight. Hermes checks your calendar. Free: "Book it and tell him
yes, or ask him where?". Busy: "Tell him you can't, with or without the
reason, or say nothing?". You answer in the main chat, which acts: it replies
to Martin, books the event. When he then writes "bobbolitas à 19h ?", Hermes
finds the place near you, proposes to update the event, and its memory keeps
where bobbolitas is.

## How it works

```
wacli (WhatsApp) ──webhook──┐
imsg watch (iMessage) ──────┤
Chrome (Instagram) ───CDP───┤
HomeClaw (HomeKit) ─webhook─┤
pollers (calendar, mail, …) ┤
                            ▼
                  hermes-events (modules/hermes/events)
                  · drops replays and messages older than 10 minutes
                  · gathers a chat's messages until it is quiet for 45 s (capped at 5 min);
                    drops them if you answer there yourself
                  · asks the local model (uzu) a typed question: may this need you? how urgent?
                            │ only what passes, signed
                            ▼
                  Hermes' webhook route "events" (127.0.0.1:8644)
                  · reads your main memory, looks things up (read-only tools)
                  · writes one proposal, one numbered item per independent topic, or stays silent
                            │
                            ▼
                  Telegram, your main chat (mirrored into its session)
                            │ your answer
                            ▼
                  the main chat, with every tool: replies, books, acts
```

The screening runs on this Mac (uzu, the model it already serves, with its
answer held to a JSON schema), so the main model only runs for what may matter.
[Jev](https://openrouter.ai/docs/guides/community/jev) (OpenRouter's typed
decisions API) could replace it: `hermes_events/triage.py` is the one class to
swap.

## Why the proposal cannot act

The events are other people's words, which can try to steer Hermes (prompt
injection). So the run that drafts the proposal has read-only tools only: web
search, and iMCP's reading tools (calendar, contacts, maps, location, weather)
through a second connection, `imcp-read`. No terminal, no files, no sending,
no fetching of arbitrary pages (which could carry your data out in a URL). It
can only write to you; acting takes your answer in the main chat.

## Every event source in this setup

| Source | What | How | Status |
| --- | --- | --- | --- |
| WhatsApp | messages to you | `wacli sync --webhook` | done |
| iMessage, SMS | messages to you | `imsg watch --json` | done |
| Instagram | its notifications (DMs, comments, mentions…) | Web Push to Hermes' always-open Google Chrome; the daemon hooks `showNotification` in Instagram's service worker over CDP | done |
| HomeKit | accessory changes you choose (door, motion, leak…) | HomeClaw's webhook | done |
| Calendar | new events, events starting within 30 min | iMCP `events_fetch`, every 5 min | done |
| Mail | new unread mail | iMCP `mail_messages_search`, every 5 min | done |
| Reminders | falling due | `remindctl show`, every minute | done |
| Phone | missed calls | the call history database iCloud syncs (Full Disk Access) | done |
| Files | new files in `~/Downloads` and iCloud Drive's Downloads | polled every minute | done |
| RunPod | pods left running for 2, 6, 12, 24, 48 h | its REST API | done (trusted: no model) |
| This Mac | low disk, a power cut, Hermes or uzu down and back, new logins | `pmset`, `last`, health URLs | done (trusted: no model) |
| GitHub | notifications | `gh api notifications` | off by default: needs a classic token with the notifications scope |
| Telegram | | already the chat itself | not an event |
| Find My | a device or person moving | FindMy.app's window only, no API | not planned |
| iPhone | Shortcuts automations (arriving home, an alarm, a Focus) | would need the Mac reachable from outside (a tunnel) | not planned |

Instagram's notifications need a Google build of Chrome: Hermes' pinned
Chrome for Testing gets a push endpoint that Firebase refuses (`410`), so
sites' pushes never reach it; a Google Chrome's endpoint takes them (`201`).
Both were tried with a real Web Push before choosing.

## Settings

`server.hermes.events`: `enable`, one switch per source (`whatsapp`,
`imessage`, `instagram`, `homekit`, `calendar`, `mail`, `reminders`, `calls`,
`github`, `runpod`, `system`), `files` (the folders), `batchSeconds` (45),
`maxBatchSeconds` (300), `maxAgeSeconds` (600), and the two loopback ports. The route's prompt is in
`modules/hermes/agent/events.nix`.

## Checking it

The bootstrap asks uzu a question, then the screening question on a test
invitation, then offers to send a fake WhatsApp message through the whole
chain: a proposal should reach Telegram. Logs: `~/Library/Logs/hermes-events.log`
on the Hermes account; `nix build .#checks.aarch64-darwin.events` runs the
daemon's tests.
