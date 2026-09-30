#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
routes="$state_dir/routes.json"
keys="$state_dir/vless-encryption.env"
runtime="$state_dir/runtime.env"
users_dir="$state_dir/users"

die() { echo "v6 accounts: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -s "$routes" && -s "$keys" ]] || die "run install-v6.sh first"
install -d -m 700 "$users_dir"

protocol="${1:-}"
action="${2:-}"
user="${3:-}"
days="${4:-}"
case "$protocol" in vless|trojan) ;; *) die "protocol must be vless or trojan" ;; esac
case "$action" in create|renew|delete|list|links|cleanup) ;; *) die "action must be create, renew, delete, list, links, or cleanup" ;; esac

store="$users_dir/$protocol.json"
[[ -s "$store" ]] || printf '[]\n' > "$store"
jq -e 'type == "array"' "$store" >/dev/null || die "invalid account store"
domain="$(jq -r '.primaryDomain' "$routes")"
if [[ -s "$runtime" ]]; then
  # shellcheck disable=SC1090
  source "$runtime"
fi

valid_user() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
valid_days() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
commit() {
  local next="$1" temp
  temp="$(mktemp "$users_dir/.${protocol}.XXXXXX")"
  printf '%s\n' "$next" > "$temp"
  chmod 600 "$temp"
  mv -f "$temp" "$store"
}

if [[ "$action" == "list" ]]; then
  jq -r '.[] | [.name, (.expiresAt // "never")] | @tsv' "$store"
  exit 0
fi

if [[ "$action" == "cleanup" ]]; then
  today="$(date -u +%F)"
  commit "$(jq --arg today "$today" '[.[] | select(.expiresAt >= $today)]' "$store")"
  exit 0
fi

valid_user "$user" || die "username may contain letters, numbers, dot, underscore, and hyphen"

case "$action" in
  create)
    valid_days "$days" || die "days must be a positive integer"
    jq -e --arg name "$user" '.[] | select(.name == $name)' "$store" >/dev/null && die "account already exists"
    expiry="$(date -u -d "+$days days" +%F)"
    if [[ "$protocol" == "vless" ]]; then secret="$(cat /proc/sys/kernel/random/uuid)"; field="uuid"; else secret="$(openssl rand -hex 24)"; field="password"; fi
    commit "$(jq --arg name "$user" --arg expiresAt "$expiry" --arg field "$field" --arg secret "$secret" '. + [{name:$name, expiresAt:$expiresAt} + {($field):$secret}]' "$store")"
    ;;
  renew)
    valid_days "$days" || die "days must be a positive integer"
    jq -e --arg name "$user" '.[] | select(.name == $name)' "$store" >/dev/null || die "account does not exist"
    today="$(date -u +%F)"
    current="$(jq -r --arg name "$user" '.[] | select(.name == $name) | .expiresAt' "$store")"
    base="$today"; [[ "$current" > "$today" ]] && base="$current"
    expiry="$(date -u -d "$base +$days days" +%F)"
    commit "$(jq --arg name "$user" --arg expiry "$expiry" 'map(if .name == $name then .expiresAt = $expiry else . end)' "$store")"
    ;;
  delete)
    jq -e --arg name "$user" '.[] | select(.name == $name)' "$store" >/dev/null || die "account does not exist"
    commit "$(jq --arg name "$user" '[.[] | select(.name != $name)]' "$store")"
    ;;
  links)
    entry="$(jq -c --arg name "$user" '.[] | select(.name == $name)' "$store")"
    [[ -n "$entry" ]] || die "account does not exist"
    if [[ "$protocol" == "trojan" ]]; then
      password="$(jq -r '.password' <<<"$entry")"
      printf 'trojan://%s@%s:443?type=ws&security=tls&sni=%s&host=%s&path=%%2Ftrojan#%s-Trojan\n' "$password" "$domain" "$domain" "$domain" "$user"
    else
      # shellcheck disable=SC1090
      source "$keys"
      uuid="$(jq -r '.uuid' <<<"$entry")"
      printf 'vless://%s@%s:443?type=tcp&headerType=http&security=tls&encryption=none&host=%s&path=%%2Fvless-tcp&sni=%s#%s-VLESS-TCP-HTTP-TLS\n' "$uuid" "$domain" "$domain" "$domain" "$user"
      printf 'vless://%s@%s:443?type=ws&security=tls&encryption=none&sni=%s&host=%s&path=%%2Fvltls#%s-VLESS-WS-TLS\n' "$uuid" "$domain" "$domain" "$domain" "$user"
      printf 'vless://%s@%s:443?type=xhttp&security=tls&encryption=none&sni=%s&host=%s&path=%%2Fvlxhttp&mode=auto&alpn=h2%%2Chttp%%2F1.1#%s-VLESS-XHTTP-TLS\n' "$uuid" "$domain" "$domain" "$domain" "$user"
      printf 'vless://%s@%s:443?type=httpupgrade&security=tls&encryption=none&sni=%s&host=%s&path=%%2Fvlhu&alpn=http%%2F1.1#%s-VLESS-HTTPUpgrade-TLS\n' "$uuid" "$domain" "$domain" "$domain" "$user"
      printf 'vless://%s@%s:443?type=grpc&security=tls&encryption=none&sni=%s&serviceName=vlgrpc&alpn=h2#%s-VLESS-gRPC-TLS\n' "$uuid" "$domain" "$domain" "$user"
      for port in 80 8080 8880; do
        printf 'vless://%s@%s:%s?type=tcp&headerType=http&security=none&encryption=%s&host=%s&path=%%2Fvless-tcp#%s-VLESS-Encrypted-NTLS-TCP-%s\n' "$uuid" "$domain" "$port" "$VLESS_NTLS_ENCRYPTION" "$domain" "$user" "$port"
        printf 'vless://%s@%s:%s?type=ws&security=none&encryption=%s&host=%s&path=%%2Fvlntls#%s-VLESS-Encrypted-NTLS-%s\n' "$uuid" "$domain" "$port" "$VLESS_NTLS_ENCRYPTION" "$domain" "$user" "$port"
        printf 'vless://%s@%s:%s?type=httpupgrade&security=none&encryption=%s&host=%s&path=%%2Fvlhu#%s-VLESS-Encrypted-NTLS-HTTPUpgrade-%s\n' "$uuid" "$domain" "$port" "$VLESS_NTLS_ENCRYPTION" "$domain" "$user" "$port"
      done
      vision_domain="${V6_VISION_DOMAIN:-${V6_STORED_VISION_DOMAIN:-vision.$domain}}"
      printf 'vless://%s@%s:443?type=tcp&security=tls&encryption=none&flow=xtls-rprx-vision&sni=%s#%s-VLESS-TLS-Vision\n' "$uuid" "$vision_domain" "$vision_domain" "$user"
      if [[ -s "$state_dir/reality.env" ]]; then
        # shellcheck disable=SC1090
        source "$state_dir/reality.env"
        printf 'vless://%s@%s:443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=%s&pbk=%s&sid=%s&fp=chrome#%s-VLESS-REALITY-Vision\n' "$uuid" "$domain" "$REALITY_SERVER_NAME" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$user"
      fi
    fi
    exit 0
    ;;
esac

"$(dirname "$0")/render-backends.sh"
if systemctl is-active --quiet ssh-xray-websocket-v6-xray; then
  xray run -test -config "$state_dir/xray-backends.json" >/dev/null
  systemctl restart ssh-xray-websocket-v6-xray
fi
echo "$protocol account $action completed: $user"
