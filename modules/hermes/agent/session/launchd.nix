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

      # bootout returns before the service is gone, and a bootstrap right
      # after fails (5: Input/output error), leaving the agent unloaded until
      # the next login: wait for it to go, and try again.
      restart() {
        local name="$1" target="$2" try
        run /bin/launchctl bootout "$domain/$name" 2>/dev/null || true
        for try in $(seq 20); do
          /bin/launchctl print "$domain/$name" >/dev/null 2>&1 || break
          sleep 0.5
        done
        run install -m 0644 "$3" "$target"
        for try in 1 2 3 4 5; do
          run /bin/launchctl bootstrap "$domain" "$target" 2>/dev/null && return 0
          sleep 1
        done
        warnEcho "Could not start $name: it starts at the next login."
      }

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
          restart "$name" "$target" "$plist"
        else
          run install -m 0644 "$plist" "$target"
        fi
      done

      # One left unloaded by an earlier failed start, its plist unchanged since.
      if [ "$live" = 1 ]; then
        for target in "$dst"/org.nix-community.home.*.plist; do
          [ -e "$target" ] || continue
          name="$(basename "$target" .plist)"
          /bin/launchctl print "$domain/$name" >/dev/null 2>&1 \
            || run /bin/launchctl bootstrap "$domain" "$target" 2>/dev/null \
            || warnEcho "Could not start $name: it starts at the next login."
        done
      fi

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
