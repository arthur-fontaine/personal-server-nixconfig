# Setup

`scripts/bootstrap-macos.sh` does all of it, in one run: run it on the server,
at its own screen and keyboard (the permission dialogs show there), and let it
reboot. Then run it once more over SSH while you look at the Mac, which shows
Hermes' desktop: that run signs Hermes in to your Apple Account and allows its
Apple apps, which only work in its own session. Every step checks whether it is done,
so running it again from the clone
(`~/personal-server-nixconfig/scripts/bootstrap-macos.sh`) only redoes what is
missing, for example the BotFather settings you skipped.

| Step | What the script does | What only you can do |
| --- | --- | --- |
| Nix | installs it (multi-user) | |
| Repository | clones it to `~/personal-server-nixconfig` | |
| This host | writes the git-ignored `hosts/local.nix`: host name, your user, the SSH keys allowed to log in (from your GitHub account, pasted, or this Mac's `~/.ssh/*.pub`) | choose the keys |
| Secrets | writes `/etc/hermes/secrets.env` (root, then Hermes only, mode 0400): the OpenCode Zen and RunPod API keys | paste the keys |
| Telegram bot | walks you through @BotFather's `/newbot`, checks the token, reads your user id from your first message to the bot, sets its description, then checks Threaded Mode (with it, the DM stays the main chat and its topics, which only the bot opens with `/sub new`, are sub-chats), privacy mode (groups as sub-chats) and its picture (the Hermes logo, from the pinned Hermes source) | create the bot; for topics, in BotFather's Mini App, Threads Settings: Threaded Mode on and "Disallow users to create new threads" on; send `/setprivacy` → your bot → `Disable`; send `/setuserpic` → your bot → the Hermes logo it saved to `~/Downloads` |
| Models | asks for the main model, then each fallback in order (a ChatGPT subscription, OpenCode Zen, any provider), the local model last; writes them to `hosts/local.nix` | choose |
| System | runs `darwin-rebuild switch` | |
| Auto-login | gives the `hermes` account a random password and writes `/etc/kcpassword`, so macOS logs it in at boot (the login user itself is in Nix) | confirm turning FileVault off, which auto-login needs |
| ChatGPT (when the chain uses it) | `hermes auth add openai-codex` as Hermes: shows a link and a code | open the link on any device, sign in to ChatGPT, enter the code |
| GitHub | opens GitHub's token page pre-filled (Contents: read and write, a year), then `gh auth login` for Hermes; then a second pre-filled page for a classic token with only the notifications scope, for Hermes' events | create both; on the first, pick this repository under Repository access (a link cannot) |
| 1Password (optional) | checks that the service account token reads the "Hermes" vault, then adds it to the secrets file | create the vault, the service account (read access to that vault only) and its token; put in the vault the logins Hermes may use, Instagram's with the website `https://www.instagram.com` |
| WhatsApp (optional) | `wacli auth` as Hermes: shows a QR code, then the first sync | scan it: WhatsApp → Settings → Linked devices → Link a device |
| Permissions | runs `cua-driver permissions grant`; macOS keeps them system-wide, so they cover the Hermes account | click Allow for Accessibility and Screen Recording |
| Full Disk Access | opens the list and shows `/Library/Hermes/hermes-launcher` in Finder | add it, once: Hermes updates keep it |
| Reboot | reboots, so macOS logs Hermes in and starts it | |
| Apple Account (second run, over SSH) | opens Hermes' System Settings → Apple Account on the Mac's screen, and waits until it is signed in | sign in with your Apple Account; in iCloud turn on Messages, Notes, Reminders, Contacts, Calendars, Find My Mac |
| Apple apps | runs a check of Reminders, Notes, Contacts, Calendar and Messages the way the gateway runs (launchd starting the launcher in Hermes' session), so each dialog is the gateway's own; opens Messages until Hermes can read your conversations; for Find My, shows the launcher to add to Screen Recording and Accessibility | click Allow in each dialog; in Messages, Settings → iMessage → "Enable Messages in iCloud" |
| iMCP | starts it (Nix installs it in /Applications), trusts Hermes in it, waits until its services are on, then connects to it as Hermes | in its menu bar icon, click Calendar, Contacts, Location, Mail (choose `~/Library/Mail`), Music, Shortcuts, Voice Memos, Weather, allowing each dialog; allow Local Network |
| HomeClaw | installs it from the App Store with `mas` (or opens its page), starts it, turns on its HTTP MCP endpoint and checks it answers, then points its webhook at Hermes' events daemon | allow it your home data; in its Settings → Webhook, choose the accessories it reports |
| Check (second run) | asks uzu a question and the events' screening question on a test invitation (waiting for its first model download), then offers to send a fake WhatsApp message through the events chain ([docs/events.md](docs/events.md)) | see the proposal arrive in Telegram |
| Instagram (second run) | starts Hermes' always-open Chrome on instagram.com, on the Mac's screen, until its profile holds a session | log in, save the login info, turn on Instagram's notifications if it offers them |
| Discord (second run) | points you to the Discord tab Hermes' events keep open in its Chrome, and records your login | log in (the phone app's QR code is easiest), allow notifications |

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
