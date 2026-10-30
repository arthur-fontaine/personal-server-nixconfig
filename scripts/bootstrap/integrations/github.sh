# GitHub notifications, as Hermes' events (docs/events.md): fine-grained
# tokens cannot read them, so a classic token with that one scope, from a
# pre-filled page (the classic form's scopes parameter).
integration_on github || return 0
step "Integration · GitHub notifications"

github_reads() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" https://api.github.com/notifications || true)" = 200 ]
}

token="$(secret_value GITHUB_NOTIFICATIONS_TOKEN)"
if [ -n "$token" ] && github_reads "$token" && keep "Hermes reads your GitHub notifications"; then
  unset token
  return 0
fi
note "A classic token with only the notifications scope, pre-filled on this page:"
show_link "https://github.com/settings/tokens/new?description=Hermes%20notifications%20(personal%20server)&scopes=notifications"
while :; do
  token="$(gum input --password --header "Notifications token (ghp_…, empty to skip)" | tr -d '[:space:]')"
  [ -n "$token" ] || break
  if github_reads "$token"; then
    set_secret GITHUB_NOTIFICATIONS_TOKEN "$token"
    ok "Hermes reads your GitHub notifications"
    break
  fi
  warn "GitHub refused that token for notifications."
  gum confirm --affirmative "Try again" --negative "Skip" "Retry?" || break
done
unset token
