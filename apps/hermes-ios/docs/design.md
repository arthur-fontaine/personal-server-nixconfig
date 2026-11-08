# Hermes for iPhone and iPad: design

A dedicated client for one conversation: the owner's DM with their Hermes
agent on Telegram. Not a Telegram client. Everything here serves three moments:
**talk to Hermes**, **answer Hermes** (approvals, questions) and **glance at
Hermes** (is it working, is the server fine, how's the pet).

## What exists, and what we take

| App | What it does well | Taken | Left |
| --- | --- | --- | --- |
| ChatGPT (iOS 26) | Streaming that grows smoothly with no reflow jumps; composer as a floating capsule; voice mode as a full-screen, low-chrome, single-object UI (the breathing orb) | Streaming, composer, call screen built around one object (the pet) | Model picker, the GPT gallery: one agent here |
| Claude | Long answers in readable prose (serif option, generous line height), code blocks with a copy button, tool use collapsed into one line | Reading typography, collapsible tool/command detail | Artifacts pane |
| Telegram | Speed: instant cold start from a local DB, sticky composer, topics as a list | TDLib's local database for cold start; topics → sub-chats | Bubbles with tails and timestamps on every message, the chat list (we have one chat) |
| Codex app | Approvals that show *what* will happen in plain words, raw command on demand; the pet reacting to the agent's state | Approval card (summary first, command collapsible), pet as the agent's mood | IDE-ish panes |
| Things 3 | Calm surfaces, one accent colour, delight in small motion (the checkbox) | Restraint: one accent, white space, spring on completion | — |
| Apple HIG, iOS 26 | Liquid Glass for the control layer only, content edge to edge; `NavigationSplitView` that collapses to a stack; standard bars pick up the material themselves | Standard bars/sheets/toolbars, glass only on our floating controls (composer, question tray, call controls) | Custom bar backgrounds (they fight the scroll-edge effect) |

## Research for the redesign (November 2026)

The first design was rejected as dated, cramped and generic (a single amber accent,
compact cards, ALL-CAPS labels, a four-tab bar). What premium iOS 26 apps and assistants do
instead:

- **Glass is the navigation layer, nothing else.** "Best used for the navigation layer that
  floats above the content"; "avoid stacking glass on glass… use fills and transparency"; two
  variants, regular and clear, never mixed; tint only to bring emphasis to the primary element
  ([Meet Liquid Glass, WWDC25](https://developer.apple.com/videos/play/wwdc2025/219/),
  [notes](https://wwdcnotes.com/documentation/wwdc25-219-meet-liquid-glass/)). "Reduce your use
  of custom backgrounds in controls and navigation elements… avoid overusing Liquid Glass
  effects" ([Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)).
- **Shape is concentric, type is bolder and left-aligned.** Three shapes: fixed, capsule,
  concentric (inner radius = outer radius − padding); capsules for touch controls, especially
  near the screen's edge on iPhone; "typography is bolder and left-aligned"
  ([Get to know the new design system, WWDC25](https://developer.apple.com/videos/play/wwdc2025/356/),
  [notes](https://wwdcnotes.com/documentation/wwdc25-356-get-to-know-the-new-design-system/)).
- **Assistants have no tab bar.** ChatGPT on iOS 26: a drawer button and a glass action
  group at the top, a floating capsule composer, replies as plain text with no bubble, the
  user's turns in a pale bubble, a lot of empty space; voice is one object (the orb), not a
  screen of controls ([App Store screenshots](https://apps.apple.com/us/app/chatgpt/id6448311069)).
  Claude: the same drawer, serif reading type for answers; its latest update puts what it makes
  beside the chat on iPad ([announcement](https://x.com/claudeai/status/2115859377488072879)).
  Gemini's 2026 redesign: a pill prompt box with voice on the right and one "+" menu for every
  tool ([eWeek](https://www.eweek.com/news/google-gemini-ui-redesign-tools-menu/)).
- **Calm comes from spacing, not from cards.** Things 3.22 for OS 26: "wider spacing that
  feels a bit more relaxed", glassy buttons that "respond to your touch with a subtle glow and
  scale", a touch of glass in the sidebar only
  ([Things blog](https://culturedcode.com/things/blog/2025/09/things-for-os-26/)).
- **What not to copy.** Telegram's Liquid Glass update kept its old top bar under a new tab
  bar ("a weird mix of the old and new",
  [r/ios](https://www.reddit.com/r/ios/comments/1o39tm6/telegrams_liquid_glass_update_a_weird_mix_of_the/));
  its Android port's four-tab bar was received poorly
  ([9to5Google](https://9to5google.com/2026/02/07/telegram-for-android-redesign-goes-all-in-on-liquid-glass-rolling-out-now/)).

Concretely: a 4-pt grid used as 8 / 12 / 16 / 24 / 32; 24 pt margins on iPhone; 28 pt between
turns; body at the Dynamic Type `.body` size with about 6 pt of extra leading; one
bold title style per screen; capsule controls 44–52 pt tall; one colour, used for
one job.

## Principles

1. **One conversation, full width.** Hermes' messages are not bubbles: they
   read as a document (like ChatGPT/Claude), full width, the owner's own
   messages are compact tinted bubbles on the right. That gives code blocks
   and tables room and makes streaming read as writing, not chatting.
2. **The answer is always one tap away.** A pending question floats above the
   composer as a glass tray wherever you are; the Live Activity carries the same
   buttons on the lock screen and in the Dynamic Island.
3. **The pet is the agent's face.** One character expresses Hermes' state
   everywhere: the chat header, the call screen, the widget, the Live
   Activity, the app icon. No spinners where the pet can say it.
4. **Glass for controls, never for content.** System bars as they come; our
   floating controls (composer, question tray, call controls) in one
   `GlassEffectContainer` each. Buttons that scroll with the content (inline
   keyboards, pet actions, the login steps) are bordered, and buttons inside a
   glass surface are filled, never glass on glass (as in system alerts). Native
   components over drawn ones: the sidebar's own selection, `Gauge` and
   `ProgressView` for needs and level, `.badge` for unread counts and pending
   questions, the tab bar's bottom accessory for Hermes' status away from the
   chat.
5. **Fast and honest.** Cold start shows the last messages from TDLib's DB
   before the network is up; a thin status line says "Connecting…" rather than
   a blocking spinner.

## Information architecture

```
Hermes
├── Chats
│   ├── Hermes (main chat)               ← default
│   └── Sub-chats (forum topics)        ← 🔒 private ones behind Face ID
│        └── + New sub-chat (preset, name) → "/sub new …" in the main chat
├── Pet          (status, needs, feed/play/sleep, level)
├── Dashboard    (models usage 24h/7d/30d · machine: CPU, RAM, disk, power)
└── Settings     (account, devices & reinstall, notifications, big files, about)
Overlays: Call (full screen) · Question tray · Login (first run)
Hidden: the "App" topic (machine traffic)
```

### iPhone (compact width)

- `TabView` with four tabs: **Chat**, **Pet**, **Dashboard**, **Settings**,
  with iOS 26's tab bar that minimizes on scroll. The call button sits in the
  chat's toolbar. The Chat tab's badge counts Hermes' open questions; on the
  other tabs, while Hermes works or waits, the tab bar's bottom accessory shows
  its status (or its question) and opens that chat (iOS 26.1+).
- Chat tab = `NavigationStack`: root is the **main chat** (the daily case: one
  tap fewer). The title menu (`Hermes ▾`) opens the sub-chat list as a sheet
  with detents; picking one pushes it.
- Landscape iPhone: same structure; the composer keeps its height.

### iPad and wide windows (regular width)

- `NavigationSplitView`, three columns, which collapses to the iPhone layout
  in Slide Over / narrow Stage Manager windows (by size class, not device):
  - **Sidebar**: the pet card on top (its mood at a glance), then *Chats*
    (main + sub-chats, private ones with a lock), then *Pet*, *Dashboard*,
    *Settings*.
  - **Content/detail**: the selected chat, the conversation column capped at
    a readable 760 pt and centred, so a 13" landscape iPad isn't a 1300 pt-wide
    line of text.
  - **Inspector** (chat only, regular width): a trailing inspector with the
    agent's live status, pending questions and the sub-chat's policy, toggled
    from the toolbar; on by default in landscape ≥ 1180 pt.
- Dashboard on iPad: a two/three-column adaptive grid of cards (`LazyVGrid`
  with adaptive columns), not a stretched list.
- Pet on iPad: sprite and needs side by side.
- Keyboard: ⌘↩ sends, ⌘N new sub-chat, ⌘1…4 sections, ⌘⇧C call; hardware
  keyboard return sends, ⇧↩ new line.
- Multiple windows supported (`UIApplicationSupportsMultipleScenes`).

## User flows

### Install → first message (≈ 60 s)

1. **Welcome**: the pet waves (row `waving`), "Hermes, in your pocket." One
   button: *Continue with Telegram*.
2. **Phone number**: country flag + number field (`.telephoneNumber` content
   type, so iOS suggests the user's own number), *Next*.
3. **Code**: one field, `.oneTimeCode` content type; Telegram sends the code
   into the official app, so the screen says "Sent to your Telegram app" and
   offers *Open Telegram* and *Send by SMS instead*. Typing the last digit
   submits; a wrong code shakes the field.
4. **Password** (only if 2FA): secure field with the hint, *Forgot?* links to
   Telegram's help.
5. **Finding Hermes**: automatic (`searchPublicChat` on the configured
   username); a pet "jumping" frame while it loads. If not found: a clear
   error with the username and *Try again*.
6. **Notifications**: a one-screen explainer before the system prompt ("Hermes
   asks before risky actions — get those even when the app is closed"), then
   the system prompt. Skippable.
7. Lands in the main chat, scrolled to the bottom.

### Daily

- **Ask**: open → main chat at the bottom → type or dictate → Hermes' answer
  streams in place (the draft renders as text growing with a soft fade on the
  newest characters; a Stop button while it streams).
- **Approve from the lock screen**: Live Activity "Hermes needs you · Delete
  backups older than 90 days" → *Once* / *Deny* buttons, no unlock for Deny,
  Face ID for Allow (App Intent `authenticationPolicy`).
- **Approve in app**: the question tray slides up over the composer: summary
  in a sentence, *Show command* reveals the raw command in mono, buttons below.
  Answered → the tray collapses with a spring and a success haptic.
- **Private sub-chat**: tap 🔒 Taxes → Face ID → the view unblurs; if Hermes
  says it's locked, the app sends `/sub unlock` with the Keychain passphrase
  and deletes it. Leaving the app relocks the view (not the server).
- **New sub-chat**: ⌘N or *+*: a sheet with name and preset chips (*Aside*,
  *Project*, *Secret*, *Temp*), each with a one-line explanation.
- **Big file**: attach a 6 GB video → over the 2 GB limit, the attachment
  chip says "Will upload to Gofile" → progress in the composer → sent message
  shows a file card.
- **Call**: phone button → full-screen call: the pet large in the centre,
  animated by the call state (listening: `waiting`, thinking: `review`,
  speaking: `running`), a live caption under it, mute / speaker / end in a
  glass bar. Audio session `.voiceChat` for echo cancellation. The device is
  the ears and the voice (LFM3-Omni-2B on device, Apple speech as fallback),
  Hermes is the brain over Telegram: each utterance becomes a `🎙` message,
  Hermes' draft is spoken sentence by sentence as it grows, a short filler
  ("One moment.") covers a silence over 1.6 s, and talking over it stops the
  speech at once.
- **Commands**: `/` on an empty composer, or *+ › Commands*, opens the
  palette instead of Telegram's raw list: a search field, "In this chat" with
  the values in force (model, permission mode) and the curated commands with
  an icon and one line each. Some are native: the model is a menu of the
  server's chain with the current one checked and "the last answer came from
  a fallback" noted; the permission mode is a picker with each mode
  explained; a new sub-chat is a form; option commands (reasoning effort) are
  pickers; commands that need words (side question, standing goal) prefill
  the composer; destructive ones confirm. Setting anything sends the slash
  command in that chat, so Telegram and the app stay one path.
- **Glance**: Home Screen widget (pet + status + needs), Lock Screen widget
  (pet + status), Live Activity while it works.

## Screens

| Screen | iPhone | iPad |
| --- | --- | --- |
| Login | full screen, centred column | same, max width 440 in a centred card |
| Chat | stack, composer pinned, question tray above it | split view detail, readable column, inspector |
| Sub-chats | sheet from the title menu | sidebar section |
| New sub-chat | sheet (medium detent) | form sheet |
| Pet | scroll: sprite, mood line, needs, actions, level | two columns: sprite / needs+actions |
| Dashboard | scroll of cards | adaptive grid of cards |
| Settings | inset grouped list | same in the detail column |
| Call | full screen cover | full screen cover |

## Message rendering

- Hermes' messages: full-width text, `.body` with 1.35 line height, Telegram
  entities rendered (bold, italic, code, links, block quotes); `pre` blocks in
  a rounded mono card with the language and a copy button, horizontally
  scrollable (no wrapping in code).
- The owner's messages: right-aligned bubble, accent tint at 15 %, max 80 %
  width.
- Time stamps are not on every message: a centred day/time separator when the
  gap is > 20 min (Messages-style).
- Inline keyboards: a row of bordered buttons under the message; once Hermes
  edits the card (answered), the buttons go.
- `[fichier: url]`: a file card (icon by extension, name, service, *Open*),
  on both sides; the marker itself is hidden from the text.
- Attachments from Telegram: documents as file cards, photos inline (thumbnail
  first, full size on tap).

### Streaming

TDLib delivers a bot's native draft as `updatePendingMessage` (main chat) and
the topics' streaming as `updateMessageContent` edits. Both render the same:

- One `StreamingText` view per in-flight message; it renders the full text
  each update (they come every ~100–300 ms) but **appends without re-layout**
  of earlier lines: the text is split into settled paragraphs (cached
  `AttributedString`s) and the last, growing paragraph. Only the last one
  re-renders.
- The newest characters fade in over 150 ms (opacity mask on the tail),
  ChatGPT-style; no per-character animation (it janks on long code).
- Scroll follows the bottom only while the user is at the bottom (within
  80 pt); otherwise a "↓ New" glass pill appears.
- When the final message arrives it replaces the draft in place with the same
  id slot, so nothing jumps.

## Motion

- Springs everywhere (`.smooth`, `.snappy`); nothing linear except progress.
- Question tray: slides up from the composer (matched glass morph inside the
  composer's `GlassEffectContainer`).
- Sending: the bubble rises from the composer (matched geometry).
- Pet: sprite frames at the atlas' own rhythm (≈ 4–9 fps), never
  interpolated; a reaction (feed/play) plays the one-shot row then returns.
- Reduce Motion: the pet shows its first idle frame; streaming fades are off.

## Typography

- SF Pro (system) for UI and chat; Dynamic Type everywhere, from xSmall to
  AX5 (chat body uses `.body`, never fixed sizes).
- SF Mono for code, commands and numbers in the dashboard (`.monospacedDigit()`
  on all live figures so they don't jitter).
- Headlines in the dashboard and pet: `.title2.weight(.semibold)`, rounded
  design (`.fontDesign(.rounded)`) for the pet's name and level only: the pet
  is the one playful element.

## Colour

- Accent: **Hermes amber** `#F2A43A` (light) / `#F6B451` (dark): warm, the
  messenger's gold, distinct from Telegram blue and system blue. Used for the
  owner's bubble tint, primary buttons, the pet's level ring.
- Status colours, used only for status: working = blue (`.blue`),
  thinking = indigo, waiting for you = amber (accent), error = red,
  idle = secondary.
- Backgrounds: system grouped backgrounds; no custom bar colours (Liquid
  Glass decides).
- Dark mode first-class; the pet sits on a soft radial gradient of its mood
  colour.
- Contrast: every text/background pair ≥ 4.5:1; glass controls use
  `.regular` glass with `.tint` only for the primary action.

## App icon

The pet itself: its first idle frame, centred on a solid colour background,
1024×1024 (`~/.hermes/app/pet/icon.png`, rendered by the backend), dropped
into `HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png` by the server's
build. A single-size icon: iOS 26 derives the dark and tinted variants.

## Checked layouts

`scripts/screenshots.sh` tours every screen (chat with and without a question,
a sub-chat, a private one, the palette, the new sub-chat form, pet,
dashboard, settings, login, call) on an iPhone 17 Pro and an iPad Pro 13", in
portrait and landscape. What it showed and what the layouts do:

- iPhone portrait: tabs; landscape (compact height): the question tray drops
  the command disclosure and the pet goes two-column, so the conversation
  keeps room.
- iPad: split view with the floating iOS 26 sidebar; the conversation's
  readable column is padded inside the detail's safe area (not measured from
  the container, which extends under the sidebar); the inspector shows in
  landscape; the dashboard grid has two columns in portrait, three in
  landscape; sheets are form-sized (the palette full-height, since a half
  height shows three rows).
- Narrow iPad windows (Slide Over, Stage Manager) fall back to the iPhone
  layout through the size class.

## Languages

English and French, following the device. French uses *tu*, Apple's French
terms and French typography (no-break spaces before `:`, `?`, `!`, guillemets).
Layouts are measured rather than sized for English: the question tray's answers
go from one row to two columns when the labels don't fit (`ViewThatFits`), and
costs use the narrow currency form ("0,48 $").

## Accessibility

- VoiceOver: each message is one element ("Hermes: …" / "You: …"); the pet
  has a label with its mood and needs ("Pip, level 6, content; hunger 35 %…").
- Live Activity and widgets: no information conveyed by colour alone (status
  has a word and an SF Symbol).
- Hit targets ≥ 44 pt; question buttons ≥ 50 pt tall on iPhone.
