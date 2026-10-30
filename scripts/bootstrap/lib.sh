# Helpers every section uses. Sourced by scripts/bootstrap-macos.sh.

JQ="$(nix build --no-link --print-out-paths nixpkgs#jq.bin)/bin/jq"

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
