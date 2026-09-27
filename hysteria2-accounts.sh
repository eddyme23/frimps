#!/usr/bin/env bash
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
store="$state_dir/hysteria2-users.json"
clients=/etc/hysteria2/clients
die(){ echo "v6 Hysteria 2: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'; command -v jq >/dev/null || die 'install jq'
action="${1:-}"; name="${2:-}"; valid(){ [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }; commit(){ local t; t=$(mktemp "$state_dir/.hy2.XXXXXX"); printf '%s\n' "$1" > "$t"; chmod 600 "$t"; mv "$t" "$store"; }
[[ -f "$store" ]] || die 'run hysteria2-install.sh first'; install -d -m 700 "$clients"
case "$action" in
 create) days="${3:-}"; valid "$name" || die 'invalid username'; [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || die 'invalid days'; jq -e --arg n "$name" '.[]|select(.name==$n)' "$store" >/dev/null && die 'account exists'; exp=$(date -u -d "+$days days" +%F); pass=$(openssl rand -hex 18); commit "$(jq --arg n "$name" --arg p "$pass" --arg e "$exp" '.+[{name:$n,password:$p,expiresAt:$e}]' "$store")"; /usr/local/libexec/ssh-xray-websocket-v6-hysteria2-render; systemctl reset-failed hysteria2-server.service || true; systemctl enable --now hysteria2-server.service; printf 'hysteria2://%s:%s@%s:443/?sni=%s#HY2-%s\n' "$name" "$pass" "${V6_DOMAIN:?set V6_DOMAIN}" "${V6_DOMAIN}" "$name" > "$clients/$name.uri"; chmod 600 "$clients/$name.uri"; cat "$clients/$name.uri" ;;
 renew) days="${3:-}"; [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || die 'invalid days'; exp=$(date -u -d "+$days days" +%F); commit "$(jq --arg n "$name" --arg e "$exp" 'map(if .name==$n then .expiresAt=$e else . end)' "$store")"; /usr/local/libexec/ssh-xray-websocket-v6-hysteria2-render ;;
 delete) commit "$(jq --arg n "$name" 'map(select(.name!=$n))' "$store")"; rm -f "$clients/$name.uri"; /usr/local/libexec/ssh-xray-websocket-v6-hysteria2-render ;;
 list) jq -r '.[]|[.name,.expiresAt]|@tsv' "$store" | column -t -N NAME,EXPIRES ;;
 uri) cat "$clients/$name.uri" ;;
 *) die 'usage: hysteria2-accounts.sh {create NAME DAYS|renew NAME DAYS|delete NAME|list|uri NAME}' ;;
esac
