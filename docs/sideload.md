# Sideload: iOS apps on your iPhone and iPad

With `server.sideload.enable` (the bootstrap's "Sideload" step; on by itself
with the Hermes app, its app `hermes`: [app.md](app.md#delivery)), this Mac installs iOS apps on your iPhones and iPads
over Wi-Fi, without the App Store or TestFlight, and keeps them signed. It is
a service of its own (`modules/sideload`), not part of Hermes: Hermes only
calls it (below).

| Part | What it does |
| --- | --- |
| `sideload` (system PATH) | `devices`, `apps`, `limits`, `team`, `status [APP]`, `add APP --ipa PATH\|URL` or `--project PATH\|GIT-URL [--scheme S] [--ref R]`, `install APP [--device UDID]… [--reason …] [--wait]`, `remove APP [--device UDID]…`, `forget APP`, `run` |
| its launchd job (`org.nix-community.home.sideload`, in `server.sideload.user`'s session, Hermes' by default) | does the queued installs and removals, then re-signs what expires soon; every 6 hours and at login |
| `~/Library/Application Support/sideload/` | `state.json` (devices, apps, installs, App IDs used), the queue, added `.ipa` files |
| `~/Library/Caches/sideload/` | each app's source copy and Xcode's DerivedData (kept: a rebuild is quick), the last runs' logs |
| `~/Library/Logs/sideload.log` | the job's own output, one line per install result, and each refusal (`sideload install` without a team, an unknown app) or crash |

## Two kinds of app

- **An Xcode project** (an XcodeGen `project.yml`, an `.xcodeproj` or an
  `.xcworkspace`), from a directory or a git URL: copied, generated, then
  `xcodebuild build -destination id=<udid> -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration` for each device. Xcode's automatic
  signing creates the certificate and profile and registers the device. A
  project of someone else's gets the team (`DEVELOPMENT_TEAM`) and, unless
  `--keep-bundle-id`, a bundle id of the team's own on the command line.
  Apps declared in Nix (`server.sideload.apps.<name>`) can also take their
  team through environment variables, secrets from the secrets file as
  environment (never arguments, which `ps` shows), and files copied in
  before each build.
- **An `.ipa`** (a path, a URL, a Telegram attachment's saved path, a
  big-file link): unpacked, its bundle id rewritten to the team's own, its
  app extensions removed (each would need an App ID and a profile of its
  own). A one-file stub app with that bundle id is built for the device, so
  Xcode registers the id and the device and fetches a profile; that profile
  and signing identity then sign the `.ipa`'s frameworks and app
  (`codesign`, with the profile's own entitlements only).

Then `xcrun devicectl device install app --device <udid>` over the local
network.

## Signing and a free team's limits

The team is the one of the Apple Account signed in to Xcode on the service's
account (the bootstrap's "Sideload: Xcode's Apple Account" step), its free
Personal Team unless `server.sideload.team` names a paid one. `sideload team`
shows the one it finds and where, in this order: `server.sideload.team.id`;
the teams Xcode 26 and earlier kept in its preferences
(`IDEProvisioningTeams`); the team (`OU`) of an "Apple Development"
certificate in the login keychain. Xcode 27 keeps only the account list in
its preferences and makes no certificate when you sign in: until you make one
(Settings › Accounts › your account › Manage Certificates… › + › Apple
Development), `sideload team` says so. A certificate does not tell a free team
from a paid one: `team.paid` does, free by default. With a paid team, setting
`team.id` is enough: the first build makes the certificate. A free team:

- signs for 7 days: the job rebuilds or re-signs and reinstalls an app when
  its profile expires within 48 hours (`refreshBefore`), after removing
  Xcode's cached profiles of that app only; a failed refresh is tried again an
  hour later or at the next run, and the app stays installed meanwhile;
- allows **3 sideloaded apps per device** (apps installed by other means
  count too) and **10 new App IDs per 7 days** (an app's extensions take one
  each; the Hermes app takes two). Both are checked before a build, and a
  refusal says which apps are there or when the next App ID frees up;
  `sideload limits` (and Hermes' `sideload_apps`) shows them;
- cannot sign a bundle id another team registered: ids start with
  `org.personal-server.<name>.<team id>`.

A paid team (`team.paid = true`) lifts the limits and signs for a year.
With the service on, the configuration also downloads Xcode's iOS platform
(about 8 GB), without which a build for a device fails ("iOS N is not
installed").

## Devices

A device must be plugged into this Mac once, by cable: tap Trust on it, then
turn on Developer Mode (Settings → Privacy & Security, then restart it). From
then on Xcode reaches it over Wi-Fi when both are on the same network. The
bootstrap's "Sideload: your iPhones and iPads" step (also at Hermes' login
while no device is ready; `bootstrap-macos.sh sideload-devices` any time)
lists them every 15 seconds (printing only what changed), pairs what is
plugged in, and offers the Hermes app's first install once `sideload team`
finds a team: run the account step first. After that first install, trust the
developer on the device before opening the app (Settings › General › VPN &
Device Management › your Apple Account › Trust).

Plug a device in while Hermes' session is unlocked, with the device unlocked,
and watch both screens: the Mac asks to allow the accessory, then the device
asks to Trust this Mac. Plugged in while the session is locked, macOS parks
the accessory request and never asks again; the device is then on USB
(`system_profiler SPUSBHostDataType`) but not in `devicectl list devices`,
and the step says so. Unplug it and plug it back in, unlocked; if the device
still doesn't ask, check Settings › Privacy & Security › Wired Accessories on
it.

## Hermes' access

`server.hermes.sideload.enable` (on with the service) gives Hermes the
`sideload` plugin (`modules/hermes/plugins/sideload`, wired by
`modules/hermes/system/sideload.nix`), which calls the CLI:
`sideload_devices`, `sideload_apps` (with the limits), `sideload_install`
(adds an `.ipa` or a project if new, then installs; returns at once, and the
end comes back to the chat that asked as a notice) and `sideload_remove`.
Listing is a read; installing and removing go through Hermes' permission
system like any action. The service runs as Hermes' account by default, so
its state is under Hermes' `~/Library`, a path it may keep writing.

When it fails: `sideload status` has `last_error` (a refusal, a missing
team, a crashed run; cleared by the next install that works), `sideload apps`
(or Hermes' `sideload_apps`) each install's last error, `requests/done/` the
answer to each request (a crashed run answers them too),
`~/Library/Logs/sideload.log` one line each, and
`~/Library/Caches/sideload/logs/` the whole run. "No Apple Account in Xcode":
run `bootstrap-macos.sh sideload-account` at the Mac. "No Apple Development
certificate yet": make one in Xcode (above). "Not reachable": the device is on another network or asleep; the next
run tries again.

Rejected: AltServer and Sideloadly (GUI apps without a command line),
SideStore (re-signs on the device through a VPN app), zsign (re-signs only,
with a certificate and profile from elsewhere), isideload (Apple's private
signing API through an anisette server). Xcode is here anyway
(`modules/system/xcode.nix`).
