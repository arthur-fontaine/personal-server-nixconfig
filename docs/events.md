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
                            ▼
                  hermes-events (modules/hermes/events)
                  · drops replays and messages older than 10 minutes
                  · gathers a chat's burst for a minute; drops it if you answer there yourself
                  · asks the local model (uzu) a typed question: may this need you? how urgent?
                            │ only what passes, signed
                            ▼
                  Hermes' webhook route "events" (127.0.0.1:8644)
                  · reads your main memory, looks things up (read-only tools)
                  · writes one proposal, or stays silent
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
| Instagram | DMs, notifications | the badge in the title of instagram.com, over CDP, in one always-open browser Hermes shares (`browser.cdp_url`); web push cannot work, Chrome for Testing has no push keys | next |
| HomeKit | accessory changes (door, motion, temperature, battery, unreachable) | HomeClaw's webhook (`homekit_webhook`) | next |
| Calendar | invitations, an event starting soon, changes | iMCP `events_fetch`, polled | next |
| Reminders | due, overdue | `remindctl show`, polled | next |
| Phone | missed calls, voicemail | the CallHistory database (Full Disk Access), iMCP voicemail | next |
| Mail | new mail that may need you | iMCP `mail_messages_search`, polled | next |
| Files | a new file in Downloads or Desktop (a scan, an invoice) | launchd `WatchPaths` | next |
| GitHub | notifications (reviews, mentions, failed runs) | `gh api notifications`, polled (nothing can reach the Mac to push) | next |
| RunPod | pods running, idle pods costing money | the RunPod API, polled | next |
| This Mac | low disk, on battery (a power cut), a crashing agent, uzu, iMCP or HomeClaw down, a failed rebuild, a new SSH login, a macOS update | trusted and rare: delivered as is, no screening, no model | next |
| Telegram | | already the chat itself | not an event |
| Find My | a device or person moving | FindMy.app's window only, no API | not planned |
| iPhone | Shortcuts automations (arriving home, an alarm, a Focus) | would need the Mac reachable from outside (a tunnel) | not planned |

## Settings

`server.hermes.events`: `enable`, `whatsapp`, `imessage`, `batchSeconds` (60),
`maxAgeSeconds` (600), and the two loopback ports. The route's prompt is in
`modules/hermes/agent/events.nix`.

## Checking it

The bootstrap asks uzu a question, then the screening question on a test
invitation, then offers to send a fake WhatsApp message through the whole
chain: a proposal should reach Telegram. Logs: `~/Library/Logs/hermes-events.log`
on the Hermes account; `nix build .#checks.aarch64-darwin.events` runs the
daemon's tests.
