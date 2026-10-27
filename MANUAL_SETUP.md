# Manual setup

What Nix cannot do for you, once, after the first `darwin-rebuild switch`
(`scripts/bootstrap-macos.sh` runs it). Run these over SSH as the administrator
unless a step says otherwise. The Hermes account is `hermes` (uid 550).

## 1. Secrets

Hermes reads its API keys from `/etc/hermes/secrets.env`, outside the Nix
store. Create it, then rebuild (activation hands it to `hermes`, mode 0400):

```sh
sudo tee /etc/hermes/secrets.env >/dev/null <<'EOF'
OPENCODE_ZEN_API_KEY=...        # https://opencode.ai/auth
RUNPOD_API_KEY=...              # https://www.runpod.io/console/user/settings
WHATSAPP_ALLOWED_USERS=33612345678   # your own number: country code, no +
EOF
sudo server-rebuild
```

## 2. The Hermes account's session

Computer use and the local model need the account logged in to a GUI session,
every boot:

1. Give it a password: `sudo dscl . -passwd /Users/hermes`
2. System Settings → Users & Groups → **Automatically log in as: Hermes**.
   macOS allows this only with FileVault off.
3. Reboot. Its agents (gateway, uzu, fsearch, caffeinate, brightness) start at
   login. Check with `sudo launchctl print gui/550 | grep org.nix-community`.

Keep the lid **open**: the backlight is off, but a closed lid turns the display
off and computer use then sees a black screen. The Mac never sleeps either way.

## 3. Permissions (TCC)

macOS asks a person for these. Turn on Screen Sharing for the time it takes
(System Settings → General → Sharing), connect to the Hermes session, then:

- **Accessibility** and **Screen Recording** for **CuaDriver**
  (`com.trycua.driver`). `sudo -u hermes -H hermes computer-use doctor` prints
  the app to add. Its signature is stable, so the grants survive updates.
- **Full Disk Access**, optional, only if Hermes must read your Desktop,
  Documents or Downloads (other folders work without it). macOS ties it to the
  binary, which is a new Nix store path at every Hermes update, so it has to be
  granted again after one.

Turn Screen Sharing off afterwards.

## 4. WhatsApp

Use a separate number for the bot (a prepaid SIM in WhatsApp Business works).
Pair it once, as the Hermes account, and scan the QR code from that number's
WhatsApp (Settings → Linked Devices):

```sh
sudo -u hermes -H env HERMES_HOME=/Users/hermes/.hermes hermes whatsapp
sudo launchctl kickstart -k gui/550/org.nix-community.home.hermes-agent
```

Then message the bot from your own number: that DM is the main chat. Create a
group with the bot for each sub-chat (`/sub` there).

## 5. GitHub, so Hermes can change the server

Create a fine-grained token limited to this repository, with **Contents: read
and write**, then:

```sh
sudo -u hermes -H gh auth login --git-protocol https --with-token <<< 'github_pat_...'
```

Whoever can push to the repository can change the whole machine through
`sudo server-rebuild`, Hermes included: keep the token to this one repository.

## 6. First starts

- uzu downloads its model (Qwen 3.5 9B, about 5 GB) the first time it starts:
  `tail -f /Users/hermes/Library/Logs/uzu.log`.
- DigUp downloads its embedding model at the first `digup index`.
