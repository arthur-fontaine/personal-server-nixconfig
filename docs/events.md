# Events: Hermes writes first

When something happens that may call for you, Hermes looks into it and
proposes what to do, in the main chat. For example: Zoé asks on WhatsApp
for a drink tonight. Hermes checks your calendar. Free: "Book it and tell him
yes, or ask him where?". Busy: "Tell him you can't, with or without the
reason, or say nothing?", each option a button. You tap one (or type your
answer) in the main chat, which acts: it replies
to Zoé, books the event. When he then writes "bobbolitas à 19h ?", Hermes
finds the place near you, proposes to update the event, and its memory keeps
where bobbolitas is.

## How it works

```
wacli (WhatsApp) ──webhook──┐
imsg watch (iMessage) ──────┤
Chrome (Instagram, Discord) ┤
HomeClaw (HomeKit) ─webhook─┤
pollers (calendar, mail, …) ┤
                            ▼
                  hermes-events (modules/hermes/events)
                  · drops replays and messages older than 10 minutes
                  · gathers a chat's messages until it is quiet for 45 s (capped at 5 min);
                    drops them if you answer there yourself
                  · reads what was said before in that chat, your replies included, from
                    the source itself (the last 15 messages of the past week)
                  · asks the local model (uzu) a typed question: may this need you? how urgent?
                    (for mail: what kind of mail is it? see "Mail: only what matters")
                  · writes every event and its outcome to recent.jsonl (two days), which Hermes
                    reads when you ask whether something arrived
                            │ only what passes, signed
                            ▼
                  Hermes' webhook route "events" (127.0.0.1:8644)
                  · reads your main memory, looks things up (read-only tools)
                  · writes one proposal, one numbered item per independent topic, or stays silent
                  · sends it with `propose` (plugins/owner_approval): its options are buttons
                            │
                            ▼
                  Telegram, your main chat (mirrored into its session)
                            │ your tap ("I picked option 1 …"), or a typed answer
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
can only write to you; acting takes your answer in the main chat. A button
says in full what it does, and your tap continues the main chat as your own
turn: the auto-review takes it as yours, since you chose it, and still asks
before anything that reaches other people.

## A message within its conversation

A message alone often means nothing ("Il faut le faire sur l'ordinateur ?").
So when a chat's batch is screened, the daemon reads the conversation before
it, from the source itself, and the triage and Hermes both get it, marked
apart from the new messages (`hermes_events/history.py`):

- WhatsApp: `wacli messages list --chat … --before …`, read-only, on the store
  `wacli sync` keeps.
- iMessage, SMS: `imsg history --chat-id … --end …`.
- Instagram: its notifications carry the message but not who sent it. The
  daemon finds the thread, by the id in the notification's link or else by
  the message among the inbox's latest, by loading `direct.js` — the script
  the `instagram` skill uses — in a background tab: it reads the app's own
  traffic and the tab closes. Its DM API is gone (404 with the logged-out
  page) and the calls it makes now are signed, so a hand-built request would
  be an unofficial client. The row gives the thread's name, its participants
  and its newest message: enough for the sender's name in a one-to-one
  thread, one chat per thread, and the group's name in a group. Its earlier
  messages are not read: opening a thread is what marks them seen, and the
  user would then get no notification on their phone. So an Instagram event
  arrives without the conversation before it, and the daemon cannot tell
  whether you already answered it from your phone.
- Discord: none yet.

When a source cannot be read, the event goes on without its history.

## Every event source in this setup

| Source | What | How | Status |
| --- | --- | --- | --- |
| WhatsApp | messages to you | `wacli sync --webhook` | done |
| iMessage, SMS | messages to you | `imsg watch --json` | done |
| Instagram | its notifications (DMs, comments, mentions…) | Web Push to Hermes' always-open Google Chrome; the daemon hooks `showNotification` in Instagram's service worker over CDP, then reads the inbox from the page itself (`direct.js`) for the sender | done |
| Discord | its notifications (DMs, mentions) | a Discord tab the daemon keeps open in that Chrome, hooked on each document (Discord notifies from the open tab, not through push); logged out, it says so once in the main chat | done |
| Home Assistant | state changes in the watched domains (locks, the alarm, binary sensors, people) and entities, one per entity per 30 s | its WebSocket API (`state_changed`), with `HASS_TOKEN`; `server.hermes.homeassistant.watchDomains` / `watchEntities` | done |
| HomeKit | accessory changes you choose (door, motion, leak…) | HomeClaw's webhook | done |
| Calendar | new events, events starting within 30 min | iMCP `events_fetch`, every 5 min | done |
| Mail | new unread mail in an inbox, if it matters (see below) | iMCP `mail_mailboxes_list`, `mail_messages_search`, `mail_messages_read`, every 5 min | done |
| Reminders | falling due | `remindctl show`, every minute | done |
| Phone | missed calls | the call history database iCloud syncs (Full Disk Access) | done |
| Files | new files in `~/Downloads` and iCloud Drive's Downloads | polled every minute | done |
| RunPod | pods left running for 2, 6, 12, 24, 48 h | its REST API | done (trusted: no model) |
| This Mac | low disk, a power cut, Hermes or uzu down and back, new logins | `pmset`, `last`, health URLs | done (trusted: no model) |
| GitHub | notifications (reviews, mentions, failed runs) | `gh api notifications`, every 10 min, with its own classic token (the notifications scope): the bootstrap asks for it | done |
| Telegram | | already the chat itself | not an event |
| Find My | a device or person moving | FindMy.app's window only, no API | not planned |
| iPhone | Shortcuts automations (arriving home, an alarm, a Focus) | would need the Mac reachable from outside (a tunnel) | not planned |

## Mail: only what matters

Most mail is automated, so the mail source is pickier than the chats
(`hermes_events/pollers.py`, `mail`):

- Only the inbox: each message's mailbox is looked up in
  `mail_mailboxes_list` and kept only when its URL's last component or its
  name is an inbox ("INBOX", "Boîte de réception", "Posteingang"…). Junk,
  Trash, Sent, Archive and your own folders are skipped, and the log says so.
  When the mailbox list fails, the poll fails and records nothing: the mail
  comes at the next poll that can filter it, never unfiltered.
- The mail itself: `mail_messages_read` gives the sender's name, a
  600-character plain-text excerpt (HTML stripped, links cut to their host)
  and what the headers say: `List-Unsubscribe`, `List-Id`, `Precedence:
  bulk`, `Auto-Submitted`, and the SPF, DKIM and DMARC results from
  `Authentication-Results`.
- Its own question (`hermes_events/triage.py`, the `mail` profile): the local
  model names a category. Personal mail, deliveries, failed payments, bills
  due, security alerts, appointments and admin letters go on; newsletters,
  promotions, social-network notifications, other automated mail, spam and
  phishing are only written to `recent.jsonl`, with their category.
- If the triage fails, a mail with no bulk headers and nothing failed in its
  authentication goes on; a mass mailing or a forged one does not.
- Hermes' route still answers `[SILENT]` for spam, phishing, ads,
  newsletters and social notifications that get through.

Instagram's notifications need a Google build of Chrome: Hermes' pinned
Chrome for Testing gets a push endpoint that Firebase refuses (`410`), so
sites' pushes never reach it; a Google Chrome's endpoint takes them (`201`).
Both were tried with a real Web Push before choosing.

## Settings

The sources of an integration (WhatsApp, Instagram, Discord, Home Assistant, HomeKit, GitHub,
RunPod) are on when it is (`server.hermes.integrations`); Apple's and this
Mac's are always on.


`server.hermes.events`: `enable`, one switch per source (`whatsapp`,
`imessage`, `instagram`, `discord`, `homekit`, `calendar`, `mail`, `reminders`, `calls`,
`github`, `runpod`, `system`), `files` (the folders), `batchSeconds` (45),
`maxBatchSeconds` (300), `maxAgeSeconds` (600), and the two loopback ports. The route's prompt is in
`modules/hermes/agent/events.nix`.

## Checking it

The bootstrap asks uzu a question, then the screening question on a test
invitation, then offers to send a fake WhatsApp message through the whole
chain: a proposal should reach Telegram. Logs: `~/Library/Logs/hermes-events.log`
on the Hermes account; `nix build .#checks.aarch64-darwin.events` runs the
daemon's tests.
