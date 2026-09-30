#!/usr/bin/env bash
# ZiVPN has a password-only authentication model.  The password is therefore
# also the account identifier presented by compatible mobile clients.
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui-v6.sh"
store="$state_dir/zivpn-users.json"
config=/etc/zivpn/config.json
opts="$state_dir/service-options.env"
[[ -r "$opts" ]] && source "$opts"

die() { echo "v6 ZiVPN: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'
command -v jq >/dev/null 2>&1 || die 'install jq'
[[ -f "$store" ]] || die 'run ZiVPN Install / reconfigure first'
jq -e 'type == "array"' "$store" >/dev/null || die 'invalid account store'

valid_password() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
valid_days() { [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]]; }
commit() {
  local tmp="$1"
  chmod 600 "$tmp"
  mv -f "$tmp" "$store"
}
render() {
  [[ -x /usr/local/bin/zivpn ]] || die 'ZiVPN binary is not installed'
  local runtime cert key users tmp
  runtime="$state_dir/runtime.env"
  [[ -r "$runtime" ]] && source "$runtime"
  cert="${V6_CERT_FILE:-${V6_STORED_CERT_FILE:-}}"
  key="${V6_KEY_FILE:-${V6_STORED_KEY_FILE:-}}"
  [[ -s "$cert" && -s "$key" ]] || die 'saved certificate paths are missing; run install-v6.sh with V6_CERT_FILE and V6_KEY_FILE'
  users="$(jq -r '[.[].password] | @json' "$store")"
  tmp="$(mktemp /etc/zivpn/config.json.XXXXXX)"
  jq -n --arg cert "$cert" --arg key "$key" --arg obfs "${V6_ZIVPN_OBFS:-frimps-zivpn}" --argjson users "$users" '{listen:":5667",cert:$cert,key:$key,obfs:$obfs,auth:{mode:"passwords",config:$users}}' > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$config"
  systemctl enable --now zivpn.service
  systemctl restart zivpn.service
}

action="${1:-}"; password="${2:-}"; days="${3:-}"
case "$action" in
  create)
    valid_password "$password" || die 'password/username must be 1-64 letters, digits, dot, underscore, or hyphen'
    valid_days "$days" || die 'validity must be a positive number of days'
    jq -e --arg p "$password" '.[] | select(.password == $p)' "$store" >/dev/null && die 'account already exists'
    expiry="$(date -u -d "+$days days" +%F)"
    tmp="$(mktemp "$state_dir/.zivpn-users.XXXXXX")"
    jq --arg p "$password" --arg e "$expiry" '. + [{password:$p,expiresAt:$e}]' "$store" > "$tmp"; commit "$tmp"; render
    ui_success_title 'ZIVPN ACCOUNT CREATED'; ui_kv 'Host' "${V6_DOMAIN:-$(jq -r '.primaryDomain' "$state_dir/routes.json")}"; ui_kv 'Port Range' '6000-19999 UDP'; ui_kv 'User (Pass)' "$password"; ui_kv 'Obfs' "${V6_ZIVPN_OBFS:-frimps-zivpn}"; ui_kv 'Expiry Date' "$expiry"; ui_rule
    ;;
  renew)
    valid_password "$password" || die 'invalid password/username'; valid_days "$days" || die 'validity must be a positive number of days'
    jq -e --arg p "$password" '.[] | select(.password == $p)' "$store" >/dev/null || die 'account does not exist'
    today="$(date -u +%F)"; current="$(jq -r --arg p "$password" '.[] | select(.password == $p) | .expiresAt' "$store")"; base="$today"; [[ "$current" > "$today" ]] && base="$current"; expiry="$(date -u -d "$base +$days days" +%F)"
    tmp="$(mktemp "$state_dir/.zivpn-users.XXXXXX")"; jq --arg p "$password" --arg e "$expiry" 'map(if .password == $p then .expiresAt = $e else . end)' "$store" > "$tmp"; commit "$tmp"; render; echo "ZiVPN account renewed through $expiry"
    ;;
  delete)
    valid_password "$password" || die 'invalid password/username'; jq -e --arg p "$password" '.[] | select(.password == $p)' "$store" >/dev/null || die 'account does not exist'
    tmp="$(mktemp "$state_dir/.zivpn-users.XXXXXX")"; jq --arg p "$password" 'map(select(.password != $p))' "$store" > "$tmp"; commit "$tmp"; render; echo 'ZiVPN account deleted'
    ;;
  list) jq -r '.[] | [.password,.expiresAt] | @tsv' "$store" | column -t -N PASSWORD,EXPIRES ;;
  *) die 'usage: zivpn-accounts.sh {create PASSWORD DAYS|renew PASSWORD DAYS|delete PASSWORD|list}' ;;
esac
