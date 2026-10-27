# Setup

`scripts/bootstrap-macos.sh` does all of it, in one run: run it on the server,
at its own screen and keyboard (the permission dialogs show there), and let it
reboot. Nothing is left to run afterwards. Every step checks whether it is done,
so running it again from the clone
(`~/personal-server-nixconfig/scripts/bootstrap-macos.sh`) only redoes what is
missing, for example a WhatsApp pairing that expired.

| Step | What the script does | What only you can do |
| --- | --- | --- |
| Nix | installs it (multi-user) | |
| Repository | clones it to `~/personal-server-nixconfig` | |
| This host | writes the git-ignored `hosts/local.nix`: host name, your user, the SSH keys allowed to log in (from your GitHub account, pasted, or this Mac's `~/.ssh/*.pub`) | choose the keys |
| Secrets | writes `/etc/hermes/secrets.env` (root, then Hermes only, mode 0400): the OpenCode Zen and RunPod API keys, your WhatsApp number | paste the keys |
| System | runs `darwin-rebuild switch` | |
| Auto-login | gives the `hermes` account a random password and writes `/etc/kcpassword`, so macOS logs it in at boot (the login user itself is in Nix) | confirm turning FileVault off, which auto-login needs |
| GitHub | `gh auth login` for Hermes, with a token you create for this repository only (Contents: read and write) | create the token |
| WhatsApp | runs `hermes whatsapp` as Hermes and restarts the gateway | scan the QR code with the bot number's phone |
| Permissions | runs `cua-driver permissions grant`; macOS keeps them system-wide, so they cover the Hermes account | click Allow for Accessibility and Screen Recording |
| Full Disk Access | opens the list and shows `/Library/Hermes/hermes-launcher` in Finder | add it, once: Hermes updates keep it |
| Reboot | reboots, so macOS logs Hermes in and starts it | |

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
- Whoever can push to the repository can change the whole Mac through
  `sudo server-rebuild`, Hermes included: keep its GitHub token to this
  repository.
