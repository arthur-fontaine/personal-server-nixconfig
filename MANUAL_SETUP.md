# Setup

`scripts/bootstrap-macos.sh` does all of it. Run it on the server, at its own
screen and keyboard the first time, reboot when it asks, then run it again:
every step checks whether it is done, so a second run picks up where the first
stopped.

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
| Reboot | reboots, so macOS logs Hermes in | |
| Permissions | lights the screen, runs `cua-driver permissions grant` in Hermes' session, dims it again | click Allow for Accessibility and Screen Recording |
| Full Disk Access (optional) | opens the list in Hermes' session | add the `hermes` binary, again after each Hermes update |

macOS reserves those last clicks for a person: no script can grant them.

## After the setup

- uzu downloads its model (Qwen 3.5 9B, about 5 GB) when it first starts:
  `tail -f /Users/hermes/Library/Logs/uzu.log`.
- DigUp downloads its embedding model at the first `digup index`.
- Keep the lid open: the backlight is off, but a closed lid turns the display
  off and computer use sees a black screen. The Mac never sleeps either way.
- Whoever can push to the repository can change the whole Mac through
  `sudo server-rebuild`, Hermes included: keep its GitHub token to this
  repository.
