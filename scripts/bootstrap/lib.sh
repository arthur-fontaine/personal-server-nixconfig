# Helpers every section uses. Sourced by scripts/bootstrap-macos.sh.

JQ="${JQ:-$(nix build --no-link --print-out-paths nixpkgs#jq.bin)/bin/jq}"

# A Nix string literal for a shell value.
nix_string() {
  local s="$1" bs='\' q='"' interp='${'
  s="${s//"$bs"/"$bs$bs"}"
  s="${s//"$q"/"$bs$q"}"
  s="${s//"$interp"/"$bs$interp"}"
  printf '"%s"' "$s"
}

# This host's configuration ($flake: host.sh), and one of its values.
setting() { nix eval --raw "$flake.config.$1" --apply toString; }

# ── Hermes' account and session ────────────────────────────────────────────
# From SSH or your own session, through sudo. In Hermes' session itself
# (scripts/hermes-setup.sh sets in_session), as Hermes, which needs no sudo
# for its own files and its own launchd domain. ($agent, $agent_uid,
# $launcher and $gateway_path: host.sh, or hermes-setup.sh.)
if [ -n "${in_session:-}" ]; then
  as_root() { "$@"; }
  hermes_gui() { "$@"; }
else
  as_root() { sudo "$@"; }
  # Hermes' desktop, even when yours is open too.
  hermes_gui() { sudo launchctl asuser "$agent_uid" sudo -u "$agent" -H "$@"; }
fi
as_agent() {
  if [ -n "${in_session:-}" ]; then
    env PATH="/etc/profiles/per-user/$agent/bin:$PATH" "$@"
  else
    sudo -u "$agent" -H env PATH="/etc/profiles/per-user/$agent/bin:$PATH" "$@"
  fi
}
gui_session() { as_root launchctl print "gui/$agent_uid" >/dev/null 2>&1; }
# Hermes' desktop on the Mac's screen: after a reboot, macOS logs it in there.
on_hermes_screen() { gui_session && [ "$(stat -f %Su /dev/console)" = "$agent" ]; }

# Built from this repository, unless the caller has them already (hermes-setup.sh).
brightness_tool() {
  echo "${BRIGHTNESS_TOOL:-$(nix build --no-link --print-out-paths "path:$REPO_DIR#display-brightness")/bin/display-brightness}"
}
mas_tool() { echo "${MAS_TOOL:-$(nix build --no-link --print-out-paths "$flake.pkgs.mas")/bin/mas}"; }
# Hermes' session keeps the backlight off: light it while you click.
hermes_lit() { hermes_gui "$(brightness_tool)" "$1" || true; }

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<< "$1"; }

# Runs a shell command the way the gateway runs (under the launcher, which
# holds the macOS permissions); prints its output, returns its status. It
# waits up to 5 minutes, for a dialog to be answered.
as_gateway() {
  local cmd="$1" label=org.personal-server.bootstrap-check dir code=""
  dir="$(as_agent mktemp -d /tmp/hermes-check.XXXXXX)"
  as_agent tee "$dir/job.plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>$(xml "$launcher")</string><string>/bin/sh</string><string>-c</string><string>$(xml "$cmd")</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(xml "$gateway_path")</string></dict>
  <key>StandardOutPath</key><string>$dir/out</string>
  <key>StandardErrorPath</key><string>$dir/out</string>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
  as_root launchctl bootout "gui/$agent_uid/$label" 2>/dev/null || true
  if as_root launchctl bootstrap "gui/$agent_uid" "$dir/job.plist"; then
    for _ in $(seq 300); do
      sleep 1
      code="$(as_root launchctl print "gui/$agent_uid/$label" 2>/dev/null \
        | sed -n 's/^[[:space:]]*last exit code = \([0-9][0-9]*\).*/\1/p')"
      [ -n "$code" ] && break
    done
    as_root launchctl bootout "gui/$agent_uid/$label" 2>/dev/null || true
  fi
  as_root cat "$dir/out" 2>/dev/null || true
  as_root rm -rf "$dir"
  return "${code:-1}"
}

# Merge a JSON patch into this host in hosts/local.nix (scripts/lib/set-host.nix);
# the configuration is then applied again (system.sh) without asking.
host_changed=0
set_host() {
  local text
  text="$(REPO="$REPO_DIR" HOST="$HOST" PATCH="$1" nix eval --impure --raw --file "$REPO_DIR/scripts/lib/set-host.nix")"
  printf '%s' "$text" > "$local_nix"
  host_changed=1
}

# Write stdin to a root-owned file that is never readable by anyone else, even briefly.
write_secret() { sudo sh -c 'umask 077 && cat > "$1"' _ "$1"; }
# A value of the secrets file ($secrets: host.sh), and setting one: rewritten
# in place, so a new value replaces the old one.
# (No secrets file yet, on a first run: no value.)
secret_value() { { sudo sed -n "s/^$1=//p" "$secrets" 2>/dev/null || true; } | head -n 1; }
set_secret() {
  local others
  others="$(sudo grep -v "^$1=" "$secrets" 2>/dev/null || true)"
  printf '%s\n%s=%s\n' "$others" "$1" "$2" | sed '/^$/d' | write_secret "$secrets"
}

# A part already set up: says so, and offers to change it. True when it stays.
keep() {
  ok "$1"
  ! gum confirm --default=false "Change it?"
}

integration_on() { [ "$(setting "server.hermes.integrations.$1.enable")" = 1 ]; }

# Opened in a browser when this session has a screen, always printed.
show_link() {
  note "$1"
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 && /usr/bin/open "$1" 2>/dev/null || true
}
