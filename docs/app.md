# The Hermes app

An iPhone and iPad app for Hermes (`apps/hermes-ios`): what it does and how
it is made in [its README](../apps/hermes-ios/README.md) and
[design](../apps/hermes-ios/docs/design.md); its protocol with Hermes in
[app-protocol.md](app-protocol.md).

## Delivery: building, signing, installing

With `server.hermes.app.delivery.enable` (the bootstrap's "The Hermes app"
step), this Mac builds the app, signs it with your Apple Account and installs
it on your iPhones and iPads over Wi-Fi, without the App Store or TestFlight.
Everything is in `modules/hermes/app-delivery`.

| Part | What it does |
| --- | --- |
| `hermes-app` (Hermes' PATH) | `devices`, `status`, `install [--device UDID]… [--reason …] [--wait]`, `run` |
| its launchd job (`org.nix-community.home.hermes-app`, in Hermes' session) | does the queued installs, then re-signs what expires soon; every 6 hours and at login |
| the `app_delivery` plugin | Hermes' tools `app_devices` and `app_install` |
| `~/.hermes/app/delivery.json` | the devices, their last install and profile expiry: the App topic's `devices` state |
| `~/Library/Caches/hermes-app` | the source copy, Xcode's DerivedData (kept, so a rebuild is quick) and the last runs' logs |
| `~/Library/Logs/hermes-app.log` | the job's own output |

### How a build goes

1. The project is copied from the Nix store (`apps/hermes-ios` at the
   deployed revision) and given the current pet, which the App topic writes
   to `~/.hermes/app/pet/`: `icon.png` (1024×1024) becomes the app icon
   (`HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png`), `pet.json`
   and `spritesheet.webp` go to `Pet/`, the pet the app starts with.
2. `xcodegen generate`, then for each device `xcodebuild build -destination
   id=<udid> -allowProvisioningUpdates -allowProvisioningDeviceRegistration`:
   Xcode's automatic signing, with the Apple Account signed in to Xcode on
   Hermes' account, creates the certificate and the profile, and registers the
   device. The app's settings go in as build settings, through the
   environment (not the command line, which `ps` shows): `HERMES_TEAM_ID`,
   `HERMES_BUNDLE_ID_PREFIX`, `HERMES_PAID_TEAM`, `HERMES_TG_API_ID`,
   `HERMES_TG_API_HASH` (the secrets file's `TELEGRAM_API_ID`/`_HASH`) and
   `HERMES_BOT_USERNAME` (the bot's, from Telegram's `getMe`).
3. `xcrun devicectl device install app --device <udid>`, over the local
   network.

It runs as Hermes in its GUI session, where its login keychain (the signing
key, Xcode's account) is unlocked, under the same `taskpolicy -c utility` as
Hermes' commands, so a build waits behind the gateway on a busy Mac.

### Signing: a free Apple Account by default

The team is the one of the Apple Account signed in to Hermes' Xcode, its free
Personal Team unless `server.hermes.app.delivery.team` names a paid one
(`team.id`, `team.paid = true`). What a free team means:

- A profile lasts 7 days. The job rebuilds and reinstalls the app with new
  ones when a device's expires within 48 hours (`refreshBefore`), after
  removing Xcode's cached profiles of this app (only those), and tries again
  at each run while the device is away. A device away for the whole two days
  keeps an app that no longer opens until it is back and the next run
  reinstalls it (your data stays).
- Three apps per device, ten App IDs a week: the app takes two (the app and
  its widgets extension).
- No push notifications (`HERMES_PAID_TEAM=0`): the app gets news through
  Telegram's own notifications. A paid team turns them on.
- Bundle ids must be unique among all teams: they start with
  `org.personal-server.hermes.<team id>` unless `bundleIdPrefix` says
  otherwise.

Rejected: AltServer and Sideloadly (GUI apps without a command line), SideStore
(re-signs on the device through a VPN app, and every new build would still
come from here), zsign (re-signs only, with a certificate and profile from
elsewhere), isideload (Apple's private signing API through an anisette server).
Xcode is here anyway (`modules/system/xcode.nix`), and with delivery on the
configuration also downloads its iOS platform (about 8 GB), without which a
build for a device fails ("iOS N is not installed").

### Devices

A device must be plugged into this Mac once, by cable: you tap Trust on it,
then turn on Developer Mode (Settings → Privacy & Security, then restart it).
From then on Xcode reaches it over Wi-Fi when both are on the same network.
The bootstrap's "The Hermes app's devices" step (also at Hermes' login while
no device is ready, `bootstrap-macos.sh app-devices` any time) lists them,
refreshing every 15 seconds or when you ask, pairs what is plugged in, and
offers a first install.

### When it is installed

Hermes decides: `app_install` after a new pet, when you ask, or when
`app_devices` shows a failed install; without devices, those the app is on
already. It returns at once, and the end comes back to the chat that asked as
a notice with each device's result. The app's own "reinstall" request does the
same through `hermes-app install`. Re-signing needs nobody.

When it fails: `app_devices` (or `hermes-app status`) has each device's last
error, and `~/Library/Caches/hermes-app/logs/` the whole build. "No Apple
Account in Xcode": run `bootstrap-macos.sh apple` at the Mac. "Not reachable":
the device is on another network or asleep; the next run tries again.
