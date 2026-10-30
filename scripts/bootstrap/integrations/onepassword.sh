# 1Password: a service account that reads one vault, whose logins
# browser_vault fills into web pages (Instagram) without the model seeing
# them. Its token is checked against the vault, again on every run.
integration_on onepassword || return 0
step "Integration · 1Password"

op_vault="$(setting server.hermes.onepassword.vault)"
op="$(nix build --no-link --print-out-paths "$flake.pkgs._1password-cli")/bin/op"
op_reads_vault() {
  OP_SERVICE_ACCOUNT_TOKEN="$1" "$op" vault list --format json 2>/dev/null \
    | "$JQ" -e --arg v "$op_vault" 'any(.[]; .name == $v)' >/dev/null
}

op_token="$(secret_value OP_SERVICE_ACCOUNT_TOKEN)"
if [ -n "$op_token" ] && op_reads_vault "$op_token" && keep "Hermes reads 1Password's \"$op_vault\" vault"; then
  unset op_token
  return 0
fi
[ -n "$op_token" ] && ! op_reads_vault "$op_token" && warn "The saved token cannot read a vault named \"$op_vault\"."
note "In 1Password: create a vault named \"$op_vault\", then Developer → Service Accounts → New,"
note "with read access to \"$op_vault\" only. Put there the logins Hermes may use."
while :; do
  op_token="$(gum input --password --header "Service account token (ops_…, empty to skip)" | tr -d '[:space:]')"
  [ -n "$op_token" ] || break
  if op_reads_vault "$op_token"; then
    set_secret OP_SERVICE_ACCOUNT_TOKEN "$op_token"
    ok "Hermes reads 1Password's \"$op_vault\" vault"
    break
  fi
  warn "That token cannot read a vault named \"$op_vault\" (${#op_token} characters read)."
  gum confirm --affirmative "Try again" --negative "Skip" "Retry?" || break
done
unset op_token
