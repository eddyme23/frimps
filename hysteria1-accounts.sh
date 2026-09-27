#!/usr/bin/env bash
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
store="$state_dir/hysteria1-users.json"
clients=/etc/hysteria1/clients
die(){ echo "v6 Hysteria 1: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'; command -v jq >/dev/null || die 'install jq'
action="${1:-}"; name="${2:-}"; valid(){ [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }; commit(){ local t; t=$(mktemp "$state_dir/.hy1.XXXXXX"); printf '%s\n' "$1" > "$t"; chmod 600 "$t"; mv "$t" "$store"; }
[[ -f "$store" ]] || die 'run hysteria1-install.sh first'; install -d -m 700 "$clients"
case "$action" in
 create) days="${3:-}"; pass="${4:-$name}"; valid "$name" || die 'invalid username'; [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || die 'invalid days'; [[ "$pass" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || die 'invalid password'; jq -e --arg n "$name" '.[]|select(.name==$n)' "$store" >/dev/null && die 'account exists'; exp=$(date -u -d "+$days days" +%F); commit "$(jq --arg n "$name" --arg p "$pass" --arg e "$exp" '.+[{name:$n,password:$p,expiresAt:$e}]' "$store")"; /usr/local/libexec/ssh-xray-websocket-v6-hysteria1-render; systemctl reset-failed hysteria1-server.service || true; systemctl enable --now hysteria1-server.service; printf 'hysteria://%s:20000-50000?protocol=udp&auth=%s&peer=%s&insecure=1&upmbps=100&downmbps=100&alpn=hysteria&obfs=xplus&obfsParam=%s#HY1-%s\n' "${V6_DOMAIN:?set V6_DOMAIN}" "$pass" "$V6_DOMAIN" "${V6_HYSTERIA1_OBFS:-frEddxx}" "$name" > "$clients/$name.uri"; chmod 600 "$clients/$name.uri"; cat "$clients/$name.uri" ;;
 renew) days="${3:-}"; [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || die 'invalid days'; exp=$(date -u -d "+$days days" +%F); commit "$(jq --arg n "$name" --arg e "$exp" 'map(if .name==$n then .expiresAt=$e else . end)' "$store")"; /usr/local/libexec/ssh-xray-websocket-v6-hysteria1-render ;;
 delete) commit "$(jq --arg n "$name" 'map(select(.name!=$n))' "$store")"; rm -f "$clients/$name.uri"; /usr/local/libexec/ssh-xray-websocket-v6-hysteria1-render ;;
 list) jq -r '.[]|[.name,.expiresAt]|@tsv' "$store" | column -t -N NAME,EXPIRES ;;
 uri) cat "$clients/$name.uri" ;;
 *) die 'usage: hysteria1-accounts.sh {create NAME DAYS [PASSWORD]|renew NAME DAYS|delete NAME|list|uri NAME}' ;;
esac
