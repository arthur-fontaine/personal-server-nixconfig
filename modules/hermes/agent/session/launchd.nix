# The account's launchd agents run in its GUI session, which exists only once
# macOS has logged it in. home-manager's own step bootstraps them into
# gui/<uid> and fails when there is no such session yet (a first install, or a
# rebuild before the auto-login), and nix-darwin's activation, under `set -e`,
# then stops before switching the system. This replaces that step: the plists
# are always installed, so launchd starts them at the next login, and they are
# (re)started now only when the session is there.
{ lib, ... }:
{
  home.activation.setupLaunchAgents = lib.mkForce (
    # After hermesAgentSetup, so a restarted gateway reads the new config.
    lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" "hermesAgentSetup" ] ''
      src="$newGenPath/LaunchAgents"
      dst="$HOME/Library/LaunchAgents"
      domain="gui/$UID"
      run mkdir -p "$dst"

      live=0
      if /bin/launchctl print "$domain" >/dev/null 2>&1; then
        live=1
      else
        noteEcho "No GUI session for $USER yet: its agents start at its next login."
      fi

      for plist in "$src"/*.plist; do
        [ -e "$plist" ] || continue
        name="$(basename "$plist" .plist)"
        target="$dst/$name.plist"
        cmp -s "$plist" "$target" && continue
        if [ "$live" = 1 ]; then
          run /bin/launchctl bootout "$domain/$name" 2>/dev/null || true
        fi
        run install -m 0644 "$plist" "$target"
        if [ "$live" = 1 ]; then
          run /bin/launchctl bootstrap "$domain" "$target" || warnEcho "Could not start $name"
        fi
      done

      # Agents this configuration no longer declares.
      for target in "$dst"/org.nix-community.home.*.plist; do
        [ -e "$target" ] || continue
        name="$(basename "$target" .plist)"
        [ -e "$src/$name.plist" ] && continue
        if [ "$live" = 1 ]; then
          run /bin/launchctl bootout "$domain/$name" 2>/dev/null || true
        fi
        run rm -f "$target"
      done
    ''
  );
}
