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
| Apple HIG, iOS 26 | Liquid Glass for the control layer only, content edge to edge; `NavigationSplitView` that collapses to a stack; standard bars pick up the material themselves | Standard bars/sheets/toolbars, glass only on our floating controls (composer, call controls) | Custom bar backgrounds (they fight the scroll-edge effect) |

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

## Correct by construction (HermesUI)

The binding rules are `hermes-app-work/design-rules.md` (compiled from Apple's HIG). They are not
checked after the fact: the app is built so that breaking one doesn't compile, fails the build, or
fails a test.

| Layer | What it guarantees | Where |
| --- | --- | --- |
| **HermesUI** (framework) | Tokens are types — `Spacing` (4-pt grid: 4…32), `Rhythm` (24 between speakers, 8 between bubbles, 16 between a reply's blocks), `TextRole` (Dynamic Type styles, monospaced only for code), `Tone`, `Surface` (system fill tiers), `Emphasis`, `PetSize`, `IconSize` — and no public API takes a number or a colour. Components encode the rules: `CardSurface` (fill, clip and hit from one shape, no stroke API, corner = inset + inner control radius, so concentric), `ActionRow` (one height, capsules in a row, rounded rectangles concentric with the card when stacked — always at AX sizes —, primary trailing and never destructive, "…" a circle of the row's height), `ApprovalCard`, `ChatColumn` (the one leading edge: the system margin; 672-pt readable width), `TranscriptRow` (the rhythm by speaker), `UserBubble`, `CodeBlock`, `IconButton`, `PetAvatar` (square, circle-clipped), `ComposerBar`/`BarButton`/`Toast` (`Chrome/`: the only glass), `PetAccent` | `HermesUI/Sources` |
| **DesignCheck** (build phase of HermesUI) | A SwiftSyntax checker failing the build on: styling modifiers in a screen (`.padding`, `.font`, `.foregroundStyle`, `.background`, `.tint`, `.buttonStyle`…), layout numbers outside `Tokens.swift`, raw colours and font sizes, shapes drawn by a screen, strokes/borders/shadows anywhere, Liquid Glass outside `Chrome/`, numbers or colours in HermesUI's public API. One fixture per rule (`swift test` in `Tools/DesignCheck`). Every screen and the widget extension compose HermesUI; `Tools/DesignCheck/phase2-screens.txt` (empty) only admits a temporary, listed exception | `Tools/DesignCheck`, `scripts/design-check.sh` |
| **Unit tests** | The accent reads at ≥ 4.5:1 (7:1 on the background with Increase Contrast) on every system background, light and dark, for 75 pet colours, with a ≥ 4.5:1 label; `ActionRow` refuses a destructive or second primary; spacing on the grid; concentric radii; the rhythm | `HermesUI/Tests` |
| **Geometric UI tests** | On the running app (iPhone 17 Pro, iPad Pro 13"): one leading x for text, code, card and composer (16 pt on iPhone); the readable column; every gap on the scale and by relation; the approval's buttons one height ≥ 44, primary trailing; measured concentric corners; hit targets; stacked answers at AX5; round controls with \|w − h\| ≤ ½ pt; no private sub-chat name on screen | `HermesUITests/GeometryTests.swift` |
| **Review rounds** | `scripts/review-shots.sh` renders the chat, chats menu, the bar pet (caress, menu) and the component catalogue (`-catalog <page>`) in light, dark, AX5, French and with another pet; a separate reviewer inspects zoomed crops | `HermesUITests/ReviewShots.swift` |

The yardstick for margins, bars, rows and fills is Apple's own apps measured on the same simulator
(16-pt margins, 44-pt Back items, 36-pt trailing items, 26-pt grouped sections, Messages' composer:
a "+" circle and a glass field).

## Principles

1. **One conversation, full width.** Hermes' messages are not bubbles: they
   read as a document (like ChatGPT/Claude), full width, the owner's own
   messages are compact neutral bubbles on the right. That gives code blocks
   and tables room and makes streaming read as writing, not chatting.
2. **The answer is always one tap away.** A pending question is the last item of
   its chat, above the composer; the Live Activity carries the same buttons on
   the lock screen and in the Dynamic Island.
3. **The pet is the agent's face.** One character expresses Hermes' state
   everywhere: the chat header, the call screen, the widget, the Live
   Activity, the app icon. No spinners where the pet can say it.
4. **Glass for controls, never for content.** System bars as they come; our
   floating controls (the composer, call controls) in one `GlassEffectContainer`
   each, and only in HermesUI's `Chrome/` (DesignCheck enforces it). The
   approval card and everything that scrolls are content: system fills, bordered
   and prominent buttons. Native components over drawn ones: system rows and
   their selection, `.badge` for unread counts.
5. **Fast and honest.** Cold start shows the last messages from TDLib's DB
   before the network is up; a thin status line says "Connecting…" rather than
   a blocking spinner.

## Information architecture

No tab bar: the chat is the app (Arthur: « une navbar en bas … ultra has been et useless »).

```
Main chat (root)
├── toolbar leading: the pet — tap: a caress (happy row, soft haptic, a tiny heart);
│                     long press: New Pet…; its animation shows Hermes' state
├── title "Main chat ⌄" → the chats (main, sub-chats; a private one is "Private chat" + lock),
│                          New Sub-chat…, ──, Dashboard, Settings (pushed on the chat)
└── toolbar trailing: Call
Overlays: Call (full screen) · Login (first run) · New sub-chat (sheet)
Hidden: the "App" topic (machine traffic)
```

### iPhone (compact width)

- One `NavigationStack` whose root is the open chat; picking a chat in the title menu replaces it.
- The system toolbar: the pet (a still frame of the row Hermes' state picks, in the bar's own
  36-pt circular item; a tap caresses it — the reaction and a heart for a second —, a long press
  opens New Pet… anchored to the item, UIKit's `UIButton` primary action + menu as Safari's Back),
  the chat's name as title (`toolbarTitleMenu`), Call. A subtitle only for the connection
  ("Connecting…"): Hermes' state is the pet, the draft and the approval card. Never the app's name as a title (HIG Toolbars): the main chat is "Main chat".
- The composer is pinned with `safeAreaBar(edge: .bottom)`, so the scroll edge effect runs under
  it; Stop replaces Send while Hermes writes. The transcript follows its bottom as it grows until
  the owner scrolls away.

### iPad and wide windows (regular width)

- `NavigationSplitView`: the sidebar lists the chats (system rows, badges), New Sub-chat…, with
  Dashboard and Settings pinned at its foot (`safeAreaBar`, the list's 52-pt rows); the detail is the chat in a 672-pt readable column with the
  pet leading and Call trailing. A narrow window (Slide Over, Stage Manager) gets the iPhone layout by size class.
- Keyboard: ⌘↩ sends, ⌘N new sub-chat, ⌘⇧C call.

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
- **Approve in app**: the approval card is the chat's last item: the summary as
  a question, *Show Command* reveals the raw command in mono, Allow Once / Deny /
  "…" below. Answered → the card goes, with a success haptic.
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
- **Glance**: Home Screen widget (pet + what Hermes is doing), Lock Screen widget
  (pet + status), Live Activity while it works.

## Screens

| Screen | iPhone | iPad |
| --- | --- | --- |
| Login | Apple's welcome layout (`OnboardingPage`): the pet, a bold title, one field, the primary full width at the foot | the same in a 440-pt column |
| Chat | stack, composer pinned, the question as the last item | split view detail, readable column |
| Sub-chats | the title menu | sidebar section |
| New sub-chat | sheet (medium detent) | form sheet |
| Pet | the bar's leading item: tap to caress, hold for New Pet… (no sheet) | the same, in the detail's bar |
| Dashboard | an inset-grouped list as Settings › Battery: window segmented, value rows, sparklines under their rows, a model's details pushed | the same in the readable column |
| Settings | inset grouped list (pushed, inline title) | the same in the readable column |
| Call | the Phone app's layout: name and duration, the pet, a caption, one row of round glass controls | the same |
| Private gate | the system's empty state: lock, "Private chat", why, Unlock | the same |
| Commands | a list: values in force as value rows, pickers with the system's checkmark, commands in the label colour (red when they confirm) | a form sheet |
| Widgets, Live Activity | the pet (its own accent, centred optically), its name, what Hermes does; answers on the lock screen with the red refusal and the pet's fill | — |

## Message rendering

- Hermes' messages: no bubble, `.body`, full column width; code blocks on the grouped fill with a
  concentric corner (the 12-pt minimum outside a card), monospaced `.callout`, scrolling sideways,
  Copy in the context menu; quotes behind a quiet rule.
- The owner's messages: a neutral bubble (`secondarySystemFill`, as Messages' other party),
  trailing, 16 × 12 pt padding (ChatGPT and Claude measure ≈ 16 × 14), a 46-pt capsule at one
  line; not the accent, which stays for what acts. Code blocks have 16 pt of padding, the approval
  card 20.
- Rhythm: 24 pt between speakers, 8 pt between the owner's bubbles, 16 pt between the blocks of
  a reply; a centred time when messages are > 20 min apart.
- Hermes' open question is the transcript's last item: an `ApprovalCard` (content layer, the
  grouped fill, no glass): the summary as `.headline`, *Show Command* as a disclosure, then Allow
  Once (prominent, trailing), Deny (red label on the neutral fill), "…" for the other answers. The
  message the question came with doesn't repeat its buttons.
- Inline keyboards: `ActionRow`s of secondary buttons.

## Motion

- Springs everywhere (`.smooth`, `.snappy`); nothing linear except progress.
- Sending: the bubble rises from the composer (matched geometry).
- Pet: sprite frames at the atlas' own rhythm (≈ 4–9 fps), never
  interpolated; a reaction (a caress, a question arriving, an answer) plays its one-shot row
  then returns to the row Hermes' state picks.
- Reduce Motion: the pet shows its first idle frame; streaming fades are off.

## Typography

SF Pro only, Dynamic Type text styles only (`TextRole`): `.body` for messages, `.headline` for a
card's question, `.subheadline`/`.footnote`/`.caption` for secondary lines, `.callout.monospaced()`
for code. Regular and semibold. Everything works to AX5: answers stack, nothing truncates.

## Colour

- One accent: the pet's colour (`PetAccent`), the dominant hue of its sprite, its lightness moved
  per appearance until it reads at ≥ 4.5:1 on every system background (7:1 on the screen's with
  Increase Contrast) and its label (black or white) at ≥ 4.5:1. It colours the primary answer, the
  send/stop button, links and selection — not the toolbar (monochrome), not the bubbles.
- Everything else is semantic: `.primary`/`.secondary`, the system background and fill tiers.
  Destructive is the system red role, never prominent.

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

- iPhone: one stack, the chat at its root; landscape keeps the same structure.
- iPad: split view with the floating iOS 26 sidebar; the conversation's
  readable column is padded inside the detail's safe area (not measured from
  the container, which extends under the sidebar); the dashboard grid has two columns in portrait, three in
  landscape; sheets are form-sized (the palette full-height, since a half
  height shows three rows).
- Narrow iPad windows (Slide Over, Stage Manager) fall back to the iPhone
  layout through the size class.

## Languages

English and French, following the device. French uses *tu*, Apple's French
terms and French typography (no-break spaces before `:`, `?`, `!`, guillemets).
Layouts are measured rather than sized for English: an `ActionRow` stacks its
answers when a label doesn't fit on one line (`ViewThatFits`), and costs use the
narrow currency form ("0,48 $").

## Accessibility

- VoiceOver: each message is one element ("Hermes: …" / "You: …"); the pet
  reads "Pip, <what Hermes is doing>", with the actions Caress and New Pet.
- Live Activity and widgets: no information conveyed by colour alone (status
  has a word and an SF Symbol).
- Hit targets ≥ 44 pt; question buttons ≥ 50 pt tall on iPhone.
