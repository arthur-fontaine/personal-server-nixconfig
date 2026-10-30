#!/usr/bin/env bash
# The setup at Hermes' login: the bootstrap's steps that need its desktop on
# the Mac's screen (permissions, Apple apps, WhatsApp, Instagram, Discord,
# HomeKit), run as Hermes in its own session, so they need neither SSH nor a
# run of the whole bootstrap. launchd starts it at each login
# (modules/hermes/agent/session/setup.nix); it checks every step without
# asking or doing anything, and only when one is not done opens Terminal with
# the steps to do, which ends after 24 hours unanswered.
#
#   hermes-setup.sh check    the check, then Terminal when a step is not done
#   hermes-setup.sh window   the steps, in that Terminal
#
# The Nix wrapper sets what the bootstrap would read from the flake: REPO_DIR
# (a copy of scripts/), HERMES_SETUP_SETTINGS (the settings the steps read, as
# JSON), GUM, JQ, BRIGHTNESS_TOOL, MAS_TOOL and HERMES_SETUP_WINDOW (what
# Terminal opens).
set -euo pipefail

mode="${1:?check or window}"
in_session=1
[ "$mode" = check ] && checking=1

state="$HOME/.local/state/hermes-setup"
mkdir -p "$state"
# The window's pid while it is open: the check leaves an open window alone.
lock="$state/window.pid"
window_open() { [ -s "$lock" ] && kill -0 "$(cat "$lock")" 2>/dev/null; }

if [ -n "${checking:-}" ]; then
  # Nothing to show: what would be asked is only counted (lib.sh: needs).
  step() { :; }
  ok() { :; }
  note() { :; }
  warn() { :; }
  gum() { to_do+=("a question (${1:-gum})"); return 1; }
  ask() { gum confirm; }
else
  gum() {
    if [ "$1" = input ]; then
      shift
      "$GUM" input --char-limit 0 "$@"
    else
      "$GUM" "$@"
    fi
  }
  step() { echo; gum style --bold --foreground 212 "▶ $1"; }
  ask() { echo; gum confirm "$@"; }
  ok() { gum style --foreground 42 "✓ $1"; }
  note() { gum style --faint "  $1"; }
  warn() { gum style --foreground 214 "! $1"; }
fi

source "$REPO_DIR/scripts/bootstrap/lib.sh"
# After lib.sh, whose setting() evaluates the flake: Hermes' account has the
# values already, and nix eval would write to its home at each login.
setting() { "$JQ" -er --arg k "$1" '.[$k]' "$HERMES_SETUP_SETTINGS"; }
# Changing a step stays with the bootstrap: here, done is done.
keep() { ok "$1"; }

agent="$(id -un)"
agent_uid="$(id -u)"
agent_home="$HOME"
secrets="$(setting server.hermes.secretsFile)"
launcher="$(setting server.hermes.access.launcher)"
gateway_path="$(setting "home-manager.users.$agent.launchd.agents.hermes-agent.config.EnvironmentVariables.PATH")"

if [ -n "${checking:-}" ]; then
  window_open && { echo "The setup window is open already."; exit 0; }
  # The login is still on its way when launchd starts this: wait for the Dock.
  for _ in $(seq 120); do
    pgrep -xu "$agent_uid" Dock >/dev/null && break
    sleep 1
  done
else
  window_open && { echo "The setup window is open already."; exit 0; }
  echo "$$" > "$lock"
  # Unanswered, it ends in 24 hours, and the next login asks again. With KILL,
  # since bash runs a TERM trap only once the question is answered, and its
  # descendants too: that question may be a gum in a $(…).
  descendants() { local pid; for pid in $(pgrep -P "$1"); do echo "$pid"; descendants "$pid"; done; }
  ( sleep 86400; self=$BASHPID; kids="$(descendants $$ | grep -vx "$self" || true)"; kill -KILL $$ $kids ) &
  watchdog=$!
  trap 'rm -f "$lock"; kill "$watchdog" 2>/dev/null || true' EXIT
  trap 'exit 1' HUP INT TERM
  hermes_lit 1
  # Left lit between steps: display.nix dims the screen once nobody touches it.
  hermes_lit() { :; }
  "$GUM" style --border rounded --padding "0 2" --bold "Hermes' setup" \
    "$("$GUM" style --faint 'What needs this screen. Unanswered, it ends after 24 hours.')"
fi

for section in permissions apple accounts; do
  source "$REPO_DIR/scripts/bootstrap/$section.sh"
done

if [ -n "${checking:-}" ]; then
  if [ "${#to_do[@]}" = 0 ]; then
    echo "$(date '+%F %T') Everything is set up."
  else
    echo "$(date '+%F %T') To do: $(IFS=,; echo "${to_do[*]}"); opening the setup window."
    # Terminal types the .command into Hermes' login shell. Without any startup
    # file, zsh first runs zsh-newuser-install, which takes the command's first
    # character as its answer.
    [ -e "$HOME/.zshrc" ] || echo "# Read by the Terminal of scripts/hermes-setup.sh." > "$HOME/.zshrc"
    /usr/bin/open -a Terminal "$HERMES_SETUP_WINDOW"
  fi
else
  echo
  ok "Done. Close this window; it opens again at the next login if a step is left."
fi
