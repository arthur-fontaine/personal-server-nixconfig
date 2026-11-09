# Hermes for iPhone and iPad

A SwiftUI client for one conversation: your Telegram DM with your Hermes bot
(main chat and sub-chat topics). It is a Telegram *user* client (TDLib), so
everything goes through Telegram, call mode included: the voice model runs on
the device and Hermes answers over Telegram. The design is in
[`docs/design.md`](docs/design.md); the protocol with Hermes is
[`docs/app-protocol.md`](../../docs/app-protocol.md); what Hermes serves it,
and building and installing it on devices from the server (the sideload
service), is in [`docs/app.md`](../../docs/app.md).

## What's in it

| Part | Where |
| --- | --- |
| App (SwiftUI, iOS 26, iPhone and iPad) | `HermesApp/` |
| Core: protocol, store, pet, uploaders, call logic; no UIKit, no TDLib | `HermesCore/Sources/` |
| Unit tests (Swift Testing) | `HermesCore/Tests/` |
| Widgets (Home + Lock Screen) and the Live Activity | `HermesWidgets/` |
| App Intents shared by the app and the widgets (Live Activity buttons) | `Shared/` |
| Screenshot tour (every screen, both orientations) | `HermesUITests/`, `scripts/screenshots.sh` |
| The bundled pet (replaced by the server's) | `Pet/` |
| Build settings | `Config/Base.xcconfig`, `Config/Local.xcconfig` (git-ignored) |

Dependencies: [TDLibKit](https://github.com/Swiftgram/TDLibKit) (SwiftPM,
pinned in `project.yml`; it pulls TDLibFramework, a ~370 MB zip), and
llama.cpp's prebuilt XCFramework for call mode (`scripts/fetch-llama.sh`,
pinned by checksum, run by XcodeGen before it generates).

## Build

```sh
cd apps/hermes-ios
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then fill it in
xcodegen generate                                        # also fetches llama.cpp into Vendor/
open Hermes.xcodeproj                                    # or:
xcodebuild build -project Hermes.xcodeproj -scheme HermesApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Without `HERMES_TG_API_ID`/`HERMES_TG_API_HASH` (or with the `-demo` launch
argument) the app runs on built-in demo data through a fake TDLib layer:
nothing to log in to, every screen works. Launch arguments used by the
screenshots: `-section pet|dashboard|settings`, `-topic <id>`, `-noQuestion`,
`-commands`, `-newSubchat`, `-call`, `-noAudio` (the call screen without the
audio engine, which the simulator's audio unit can abort on), `-demoLogin`.

Tests and screenshots:

```sh
xcodebuild test -project Hermes.xcodeproj -scheme HermesApp -only-testing:HermesCoreTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
scripts/screenshots.sh /tmp/hermes-shots   # iPhone 17 Pro and iPad Pro 13", portrait and landscape
```

The `Hermes.xcodeproj` is generated, not committed. Keep DerivedData in one
place (`-derivedDataPath ~/Library/Caches/hermes-ios/DerivedData`). If your
git config rewrites GitHub's HTTPS URLs to SSH and SwiftPM can't clone, run
xcodebuild with `GIT_CONFIG_GLOBAL=/dev/null` (only for that command).

## Languages

English (the development language) and French, with String Catalogs: one per
target, since each bundle looks up its own (`HermesApp/Localizable.xcstrings`
and `InfoPlist.xcstrings` for the permission prompts,
`HermesCore/Sources/Localizable.xcstrings` read through `L(_:)`, and
`HermesWidgets/Localizable.xcstrings`; `Shared/`'s App Intents land in both the
app's and the widgets'). SwiftUI literals are keys already; any other text goes
through `String(localized:)` (or `L` in the core), and numbers, sizes, dates and
units through their format styles. Xcode adds new strings to the catalogs when it
builds; from the command line, after a simulator *and* a device build (the voice
engine only compiles for devices):

```sh
xcrun xcstringstool sync HermesApp/Localizable.xcstrings \
  $(for f in ~/Library/Caches/hermes-ios/DerivedData/Build/Intermediates.noindex/Hermes.build/Debug-iphone*/HermesApp.build/Objects-normal/arm64/*.stringsdata; do printf -- '--stringsdata %s ' "$f"; done)
```

The French uses *tu* and Apple's own terms (Réglages, Annuler, Plus tard).
`scripts/screenshots.sh` takes `LANGUAGE=fr` to tour the app in French.

## Configuration (build settings)

All of them can be set in `Config/Local.xcconfig`, in the environment (what
the server does, so the Telegram API hash stays out of the command line), or
passed to xcodebuild as `KEY=value`. `Config/Base.xcconfig` must never assign
the `HERMES_*` settings below, not even empty: an xcconfig assignment wins
over the environment. Their defaults come through derived settings
(`HERMES_ID_PREFIX`, `HERMES_PAID`) instead.

| Setting | What | Default |
| --- | --- | --- |
| `HERMES_TEAM_ID` | Apple team id (`DEVELOPMENT_TEAM`, automatic signing) | empty |
| `HERMES_BUNDLE_ID_PREFIX` | bundle ids are `<prefix>.app` and `<prefix>.app.widgets`; the App Group is `group.<prefix>.hermes`. A free team needs a globally unique prefix | `dev.hermes.local` |
| `HERMES_PAID_TEAM` | `1` for a paid Apple Developer Program team: push (APNs), communication and time-sensitive notifications, Live Activity push. `0` signs with a free personal team | `0` |
| `HERMES_BOT_USERNAME` | the Hermes bot's username, without `@`: the app opens that DM after login | empty (demo: `hermes_bot`) |
| `HERMES_TG_API_ID`, `HERMES_TG_API_HASH` | from https://my.telegram.org (never commit them) | empty: demo mode |
| `HERMES_SWISSTRANSFER_TOKEN` | an Infomaniak API token: big files go to SwissTransfer instead of Gofile | empty |
| `CURRENT_PROJECT_VERSION`, `MARKETING_VERSION` | build number and version | `1`, `1.0` |

App IDs: two (the app and its one widget extension), so a free team's limit
of 10 App IDs per 7 days and 3 apps per device is not a problem.

## Build inputs the server provides

The server's sideload service (its app `hermes`,
`modules/hermes/system/sideload.nix`) builds the app when Hermes reinstalls it
after a new pet, and to
re-sign it before the 7-day profiles expire:

1. **App icon**: one 1024×1024 PNG at
   `HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (single
   universal size; iOS derives the dark and tinted variants). The server copies
   `~/.hermes/app/pet/icon.png` there.
2. **Pet**: `Pet/pet.json` and `Pet/spritesheet.webp` (a Codex pet: 8×9 atlas
   of 192×208 cells), copied from `~/.hermes/app/pet/`. Bundled, so a fresh
   install shows the right pet before Telegram connects; afterwards the app
   follows the `state.pet` slot and downloads newer sheets from the App topic.
   The pet in the repository, Pip, is drawn by `scripts/make-default-pet.py`.
3. **Settings** as above, in xcodebuild's environment:

```sh
xcodegen generate
HERMES_TEAM_ID=… HERMES_BUNDLE_ID_PREFIX=… HERMES_PAID_TEAM=0 \
  HERMES_BOT_USERNAME=… HERMES_TG_API_ID=… HERMES_TG_API_HASH=… \
  xcodebuild build -project Hermes.xcodeproj -scheme HermesApp -configuration Release \
  -destination id=<udid> -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION=…
```

## Free vs paid Apple team

| | Free personal team | Paid team (`HERMES_PAID_TEAM=1`) |
| --- | --- | --- |
| Install | 7-day profiles, re-signed by the server | 1-year profiles |
| App Group (widgets), Background Modes, Keychain, Face ID | yes | yes |
| Notifications | live while Hermes works, a question waits or a call is on, and for a window after (10 min, Settings › Notifications): the app stays connected in the background with a silent, mixable audio session; otherwise at background refreshes (a few a day, iOS decides) | pushed by Hermes through APNs, even when the app is closed |
| Siri announcing notifications on AirPods | no (needs communication or time-sensitive notifications) | yes: communication notifications from "Hermes", questions time-sensitive |
| Live Activity | updated live in the same window; shown as stale 2 min after the last update it could get, ended when Hermes is idle | updated and started by Hermes' pushes |
| Answering from the Live Activity | yes (App Intents run in the app's process) | yes |

Telegram's own push can't reach a third-party bundle id (Telegram would
need this app's APNs certificate), so a paid build registers its device
token with Hermes (`push.register` in the App topic) and Hermes pushes itself.

## Call mode

The voice model, LFM3-Omni-2B (Liquid AI, Q4_0, 1.05 GB + its 0.27 GB audio
projector), is downloaded once from Settings › Call mode (Wi-Fi only,
deletable). It transcribes what you say (on-device ASR), and Hermes' answer
comes back over Telegram and is spoken sentence by sentence as it streams
(the model's speech output, 24 kHz), in the voice picked in Settings ›
Call mode (female by default, or male; Apple's fallback takes an installed
voice of the same gender). You can talk over it to interrupt. Each
utterance is a main-chat message starting with `🎙 `; the app sends
`call.state` so Hermes answers in a spoken style during the call. Without the
model (not downloaded, too little memory, or the simulator, where llama.cpp
has no slice), calls use Apple's speech recognition and synthesis.

Only Hermes' spoken answer is read aloud: what is worth reading (links, code,
lists) comes as a separate message starting with `📎 `, shown and never
spoken, not even by Siri announcing its notification (protocol §6). The call screen names each step of a turn (Listening,
Hearing you…, Transcribing…, Sending…, Thinking, Speaking), and the app logs
each call (`CallLog`, the last 400 lines). When a call hears nothing on a
device, Settings › About › Copy Diagnostics copies the permissions, the voice
model's state, the audio session and those lines (no message content).
