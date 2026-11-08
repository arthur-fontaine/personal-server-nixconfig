# server-rebuild: pull the repository, check Hermes' local overlay, apply.
# Run as root (sudo). Its paths and tools come from the environment
# (../rebuild.nix sets them; the test stubs them):
#   DIR ADMIN HOST HERMES_USER OVERLAY LOCAL_SECRETS STATE SECRETS ENV_OUT
#   POLICY CHECK (the checker's command) GIT DARWIN_REBUILD CURL AS_ADMIN AS_HERMES
# Hermes' own files are written as Hermes: a link it planted there must not
# send a root write elsewhere.
#
#   server-rebuild                           pull, check the overlay, apply
#   server-rebuild --no-overrides            apply without the overlay, this once
#   server-rebuild --overrides-rollback [T]  apply version T of the history (default: the one before)
set -euo pipefail

mode=apply rollback=""
case "${1:-}" in
  "") ;;
  --no-overrides) mode=none ;;
  --overrides-rollback) mode=rollback; rollback="${2:-}" ;;
  *) echo "usage: server-rebuild [--no-overrides | --overrides-rollback [<timestamp>]]" >&2; exit 2 ;;
esac

applied="$DIR/hosts/hermes-overrides.json"
history="$STATE/history"
mkdir -p "$history"
chmod 700 "$STATE"

$AS_ADMIN $GIT -C "$DIR" pull --ff-only

before="$(mktemp)"; next="$(mktemp)"; mine="$(mktemp)"; keys="$(mktemp)"
trap 'rm -f "$before" "$next" "$mine" "$keys"' EXIT
# Hermes' files, read as Hermes: a link there must not make root read for it.
have_overlay=0
$AS_HERMES /bin/sh -c '[ -f "$1" ] && cat "$1"' _ "$OVERLAY" > "$mine" 2>/dev/null && have_overlay=1
$AS_HERMES /bin/sh -c '[ -f "$1" ] && cat "$1"' _ "$LOCAL_SECRETS" > "$keys" 2>/dev/null || : > "$keys"
if [ -f "$applied" ]; then cp "$applied" "$before"; else echo '{}' > "$before"; fi

refused=""
case "$mode" in
  none) echo '{}' > "$next" ;;
  rollback)
    if [ -z "$rollback" ]; then
      # The version before the one applied now.
      rollback="$(ls "$history" | sed 's/\.json$//' | sort | tail -n 2 | head -n 1)"
    fi
    rollback="${rollback%.json}"
    case "$rollback" in *[!0-9-]*) rollback="invalid:$rollback" ;; esac
    if [ -z "$rollback" ] || [ ! -f "$history/$rollback.json" ]; then
      echo "server-rebuild: no overlay version ${rollback:-to roll back to} (have: $(ls "$history" | sed 's/\.json$//' | tr '\n' ' '))" >&2
      exit 1
    fi
    cp "$history/$rollback.json" "$next"
    # Hermes' own file follows, or the next rebuild would apply it again.
    $AS_HERMES /bin/sh -c 'cat > "$1"' _ "$OVERLAY" < "$next"
    ;;
  apply)
    if [ "$have_overlay" = 0 ]; then
      echo '{}' > "$next"
    elif ! $CHECK check "$mine" "$POLICY" > "$next" 2> "$next.err"; then
      # Fail closed: the whole overlay is refused, the one applied before stays.
      refused="$(cat "$next.err")"
      echo "server-rebuild: Hermes' local overlay refused, the previous one stays: $refused" >&2
      cp "$before" "$next"
    fi
    rm -f "$next.err"
    ;;
esac

# The keys the overlay's MCP servers name, from Hermes' own file, never one
# the system's secrets file sets.
if [ "$mode" != none ]; then
  $CHECK secrets "$next" "$keys" "$SECRETS" > "$ENV_OUT.tmp"
else
  : > "$ENV_OUT.tmp"
fi
chown "$HERMES_USER" "$ENV_OUT.tmp"
chmod 400 "$ENV_OUT.tmp"
mv "$ENV_OUT.tmp" "$ENV_OUT"

if [ "$(cat "$next")" = '{}' ]; then rm -f "$applied"; else install -m 644 "$next" "$applied"; fi

if ! cmp -s "$before" "$next"; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp "$next" "$history/$stamp.json"
  $AS_HERMES /bin/sh -c 'mkdir -p "$1" && cat > "$1/$2.json"' _ "$(dirname "$OVERLAY")/history" "$stamp" < "$next" \
    || echo "server-rebuild: could not keep Hermes' copy of the history" >&2
  message="$($CHECK describe "$before" "$next")"
  [ "$mode" = rollback ] && message="$message (rolled back to $rollback)"
  [ "$mode" = none ] && message="$message (server-rebuild --no-overrides)"
else
  message=""
fi
[ -n "$refused" ] && message="Local config refused, nothing changed: $refused"

if [ -n "$message" ]; then
  echo "$message"
  token="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$SECRETS" 2>/dev/null | head -n 1 || true)"
  owner="$(sed -n 's/^TELEGRAM_ALLOWED_USERS=//p' "$SECRETS" 2>/dev/null | head -n 1 | cut -d, -f1 || true)"
  if [ -n "$token" ] && [ -n "$owner" ]; then
    $CURL -fsS --max-time 15 -o /dev/null "https://api.telegram.org/bot$token/sendMessage" \
      --data-urlencode "chat_id=$owner" --data-urlencode "text=$message" \
      || echo "server-rebuild: could not tell the owner on Telegram" >&2
  fi
fi

exec $DARWIN_REBUILD switch --flake "path:$DIR#$HOST"
