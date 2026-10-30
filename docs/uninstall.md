# Disabling and uninstalling

`scripts/uninstall-macos.sh`, run from the clone on the server, does each of
these with a menu:

```sh
~/personal-server-nixconfig/scripts/uninstall-macos.sh
```

Below is what it does, to do it by hand or to know what it touches.

## Disable Hermes, keep everything

Hermes stops and nothing of it runs any more, but its account, its memory, its
bot token and its GitHub login stay, so enabling it again brings it back
as it was.

1. Under your host in `hosts/local.nix`, set `server.hermes.enable = false;`,
   then `sudo server-rebuild`. The gateway, uzu, fsearch, the freeze daemon,
   Hermes' sudo rights and the auto-login are gone from the configuration, and
   its account is no longer managed, so nix-darwin leaves it as it is.
2. Clean what the configuration no longer manages:
   - its agents: `sudo launchctl bootout gui/550/<label>` and delete
     `/Users/hermes/Library/LaunchAgents/org.nix-community.home.*.plist`;
   - the auto-login: `sudo defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser`
     and `sudo rm /etc/kcpassword`;
   - if it is logged in: `sudo launchctl bootout gui/550` logs it out.

To enable it again, set `server.hermes.enable = true;` (or remove the line),
`sudo server-rebuild`, then run `scripts/bootstrap-macos.sh`, which recreates
the auto-login and skips everything else that is still in place.

## Remove Hermes

Disable it as above, then:

1. Remove the ACL entries naming it, while its account still exists:
   `sudo chmod -R -a "user:hermes allow read,execute,readattr,readextattr,readsecurity,file_inherit,directory_inherit" ~`
   (the read grant), and the freeze entries on the files it made
   (`deny write,delete,…` and `deny delete,…` / `allow list,search,add_file,…`,
   see `modules/hermes/system/access/freeze.py`) in your home, `/Users/Shared`
   and `/private/tmp`. Removing an entry by its text also removes the copies
   files inherited, and leaves other entries alone.
2. Delete the account and its home (memory, sessions):
   `sudo sysadminctl -deleteUser hermes`, then `sudo dscl . -delete /Groups/hermes`.
3. Delete the rest: `/etc/hermes` (the secrets), `/Library/Hermes` (the
   launcher), `/var/db/hermes-freeze`, `/var/db/hermes-read-acl`,
   `/var/log/hermes-freeze.log`.
4. Revoke what it held elsewhere: its GitHub token, the OpenCode Zen and RunPod
   API keys, and the bot (send @BotFather `/revoke` for a new token, or
   `/deletebot`).

Files Hermes made that froze belong to you and stay. Keep
`server.hermes.enable = false;`, or the next rebuild creates an empty Hermes
account again.

## Remove everything

Remove Hermes as above, then:

1. Put macOS' own settings back: `sudo pmset -a restoredefaults`,
   `sudo mdutil -a -i on` (Spotlight), `blueutil --power 1`,
   `sudo nvram -d StartupMute`,
   `sudo defaults delete com.apple.network.local-network` (the local network
   open to every program, which takes a restart).
2. Uninstall nix-darwin, which also restores the `/etc` files it managed:
   `sudo nix --extra-experimental-features "nix-command flakes" run nix-darwin#darwin-uninstaller`
   ([nix-darwin's README](https://github.com/nix-darwin/nix-darwin#uninstalling)).
3. Uninstall Nix, following
   [the Nix manual's macOS steps](https://github.com/NixOS/nix/blob/master/doc/manual/source/installation/uninstall.md):
   restore `/etc/zshrc`, `/etc/bashrc` and `/etc/bash.bashrc` from their
   `.backup-before-nix` copies; unload and delete
   `/Library/LaunchDaemons/org.nixos.nix-daemon.plist` and
   `org.nixos.darwin-store.plist`; delete the `nixbld` group and the `_nixbld*`
   users; remove the `/nix` lines from `/etc/fstab` (`sudo vifs`) and
   `/etc/synthetic.conf`; delete `/etc/nix` and the `.nix-profile`,
   `.nix-defexpr` and `.nix-channels` of root and of your user; then
   `sudo diskutil apfs deleteVolume /nix` (reboot first if it is in use).
4. Delete the clone, `~/personal-server-nixconfig`.
5. Close the terminal and open a new one: the old one still exports
   nix-darwin's variables, and `NIX_SSL_CERT_FILE` names a certificate file
   that is gone, so Nix there cannot download anything (installing again
   fails on `/etc/ssl/certs/ca-certificates.crt`).
