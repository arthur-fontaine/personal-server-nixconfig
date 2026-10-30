# Setup

`scripts/bootstrap-macos.sh` does all of it, in one run: run it on the server,
at its own screen and keyboard (the permission dialogs show there), and let it
reboot. What only works in Hermes' own session (its permissions, signing it in
to your Apple Account and allowing its Apple apps, WhatsApp, Instagram,
Discord, HomeKit) then comes to the Mac's screen by itself: at each login,
`scripts/hermes-setup.sh` checks those steps, as Hermes, without asking
anything, and when one is not done opens Terminal with the steps left, which
ends after 24 hours unanswered (its log: `~hermes/Library/Logs/hermes-setup.log`). Over SSH,
`scripts/bootstrap-macos.sh permissions apple accounts` runs the same steps.

Running it again from the clone
(`~/personal-server-nixconfig/scripts/bootstrap-macos.sh`) goes through every
section: what is set up says so and asks "Change it?" (No by default), what is
missing is set up. After a change to the host (models, integrations, keys, an
address), the configuration is applied again. Each section is its own file in
`scripts/bootstrap/`, run in the order `bootstrap-macos.sh` lists, which the
table follows; each integration is one file in `scripts/bootstrap/integrations/`.
The sections come from the clone: when it is behind GitHub, the script offers
to update it and start again. It reads GitHub over HTTPS whatever your
`~/.gitconfig` says, so a rewrite to SSH (whose key may be in 1Password, out of
reach over SSH) does not get in the way.

| Step | What the script does | What only you can do |
| --- | --- | --- |
| Nix | installs it (multi-user) | |
| Repository | clones it to `~/personal-server-nixconfig` | |
| This host | writes the git-ignored `hosts/local.nix`: host name, your user, the SSH keys allowed to log in (from your GitHub account, pasted, or this Mac's `~/.ssh/*.pub`) | choose the keys |
| Telegram bot | walks you through @BotFather's `/newbot`, checks the token, reads your user id from your first message to the bot, keeps both in `/etc/hermes/secrets.env` (root, then Hermes only, mode 0400), sets its description, then checks privacy mode (groups as sub-chats), its picture (the Hermes logo, from the pinned Hermes source) and Threaded Mode (with it, the DM stays the main chat and its topics, which only the bot opens with `/sub new`, are sub-chats) | create the bot; send `/setprivacy` → your bot → `Disable`; send `/setuserpic` → your bot → the Hermes logo it saved to `~/Downloads`; for topics, in BotFather's Mini App, Threads Settings: Threaded Mode on and "Disallow users to create new threads" on |
| Models | lists Hermes' providers to pick (type to search) for the main model, then each fallback, showing the chain so far, the local model last; asks a provider's API key as soon as it is picked, then lists its models (`gpt-6-luna` first for ChatGPT), or takes one typed in; "Another OpenAI-compatible API" asks a name, its address and key, and checks them on its `/models`; writes the chain to `hosts/local.nix` and the keys to the secrets file. A ChatGPT subscription logs in here (`hermes auth add openai-codex`: a link and a code), kept root-only until Hermes' account exists | choose; paste the keys; for ChatGPT, open the link on any device, sign in, enter the code |
| Integrations | asks which of your other services Hermes may use: WhatsApp, Instagram, Discord, Home Assistant, HomeKit, 1Password, RunPod, GitHub notifications (none by default; Apple's apps are always there), and writes them to `hosts/local.nix`. The steps marked *(integration)* run only for those | pick |
| RunPod *(integration)* | asks for its API key | create it |
| Home Assistant *(integration)* | asks for its address and checks from this Mac that it answers (nothing at all: a wrong address, another network, or the terminal not allowed on the local network; a 401: it is there), opens its token page, checks the token against `/api/`, then keeps the address in `hosts/local.nix` and the token as `HASS_TOKEN`; checks both again on every run | give the address; create a long-lived access token (profile → Security); allow the terminal on the local network if macOS asks |
| 1Password *(integration)* | checks that the service account token reads the "Hermes" vault (again on every run), then keeps it in the secrets file | create the vault, the service account (read access to that vault only) and its token; put in the vault the logins Hermes may use, Instagram's with the website `https://www.instagram.com` |
| GitHub notifications *(integration)* | opens a pre-filled page for a classic token with only the notifications scope, checks it, keeps it for Hermes' events | create it |
| The configuration | runs `darwin-rebuild switch`: always the first time and after a change above, otherwise only if you ask; then moves a ChatGPT login made before the account existed into it | |
| Hermes' login at boot | gives the `hermes` account a random password and writes `/etc/kcpassword`, so macOS logs it in at boot (the login user itself is in Nix); on every run, checks that the password it replays is still the account's (`dscl -authonly`) and that FileVault is off, and sets a new one when it is not. A daemon (Nix) clears `autoLoginUserScreenLocked`, which would lock the session right after the automatic login | confirm turning FileVault off, which auto-login needs |
| GitHub access | opens GitHub's token page pre-filled (Contents: read and write, a year), then `gh auth login` for Hermes | create it; pick this repository under Repository access (a link cannot) |
| Permissions | runs `cua-driver permissions grant`; macOS keeps them system-wide, so they cover the Hermes account; for Full Disk Access, opens the list and shows `/Library/Hermes/hermes-launcher` in Finder; then has the launcher browse for iMCP, so macOS asks its Local Network question now | click Allow for Accessibility and Screen Recording; add the launcher to Full Disk Access, once: Hermes updates keep it; allow hermes-launcher to find devices on the local network |
| Apple Account (at Hermes' login) | opens Hermes' System Settings → Apple Account on the Mac's screen, and waits until it is signed in | sign in with your Apple Account; in iCloud turn on Messages, Notes, Reminders, Contacts, Calendars, Find My Mac |
| Apple apps | runs a check of Reminders, Notes, Contacts, Calendar and Messages the way the gateway runs (launchd starting the launcher in Hermes' session), so each dialog is the gateway's own; opens Messages until Hermes can read your conversations; for Find My, shows the launcher to add to Screen Recording and Accessibility | click Allow in each dialog; in Messages, Settings → iMessage → "Enable Messages in iCloud" |
| iMCP | starts it (Nix installs it in /Applications) and Voice Memos once (which creates the Recordings folder iMCP asks for), trusts Hermes in it, waits until its services are on, then connects to it as Hermes | in its menu bar icon, click Calendar, Contacts, Location, Mail (choose `~/Library/Mail`), Music, Shortcuts, Voice Memos (`group.com.apple.VoiceMemos.shared/Recordings`), Weather, Phone and Voicemail (the folder each dialog names), allowing each dialog; allow Local Network |
| WhatsApp *(integration)* | `wacli auth` as Hermes: shows a QR code, then the first sync | scan it: WhatsApp → Settings → Linked devices → Link a device |
| Instagram (at Hermes' login) *(integration)* | starts Hermes' always-open Chrome on instagram.com, on the Mac's screen, until its profile holds a session | log in, save the login info, turn on Instagram's notifications if it offers them |
| Discord (at Hermes' login) *(integration)* | points you to the Discord tab Hermes' events keep open in its Chrome, and records your login | log in (the phone app's QR code is easiest), allow notifications |
| HomeKit (at Hermes' login) *(integration)* | installs HomeClaw from the App Store with `mas` (or opens its page), starts it, turns on its HTTP MCP endpoint and checks it answers, then points its webhook at Hermes' events daemon | allow it your home data; in its Settings → Webhook, choose the accessories it reports |
| Start | restarts Hermes, or the first time reboots, so macOS logs Hermes in and starts it | |
| Check (a run once Hermes is logged in) | asks uzu a question and the events' screening question on a test invitation (waiting for its first model download), then offers to send a fake WhatsApp message through the events chain ([docs/events.md](docs/events.md)) | see the proposal arrive in Telegram |

macOS reserves those clicks for a person: no script can grant them.

Full Disk Access lets Hermes read the folders macOS keeps even from root
(Desktop, Documents, Downloads, Mail, Messages, iCloud). macOS ties the grant
to one binary, and every Hermes update is a new one, so the gateway runs under
a small launcher that never changes (`pkgs/tcc-launcher`): the grant made to it
reaches Hermes and everything it runs, across updates.

## After the setup

- uzu downloads its model (Qwen 3.5 9B, about 5 GB) when it first starts:
  `tail -f /Users/hermes/Library/Logs/uzu.log`.
- DigUp downloads its embedding model at the first `digup index`.
- Keep the lid open: the backlight is off, but a closed lid turns the display
  off and computer use sees a black screen. The Mac never sleeps either way.
- Talk to the bot in its DM, outside any topic: that is the main chat.
  `/sub new [preset] [name]` there opens a sub-chat as a topic; a group with
  the bot is one too. Send `/sub` in a sub-chat for its rules.
- Whoever can push to the repository can change the whole Mac through
  `sudo server-rebuild`, Hermes included: keep its GitHub token to this
  repository.
