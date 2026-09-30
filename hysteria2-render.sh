#!/usr/bin/env bash
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
store="$state_dir/hysteria2-users.json"
config=/etc/hysteria2/config.yaml
cert_file="${V6_CERT_FILE:-/etc/certificates/main.crt}"
key_file="${V6_KEY_FILE:-/etc/certificates/main.key}"
[[ -r "$state_dir/service-options.env" ]] && source "$state_dir/service-options.env"
obfs="${V6_HYSTERIA2_OBFS:-}"
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
[[ -f "$store" ]] || { echo 'Hysteria 2 is not installed' >&2; exit 1; }
install -d -m 700 /etc/hysteria2
{
  printf 'listen: :443\ntls:\n  cert: %s\n  key: %s\nauth:\n  type: userpass\n  userpass:\n' "$cert_file" "$key_file"
  jq -r '.[] | "    \(.name): \(.password)"' "$store"
  if [[ -n "$obfs" ]]; then printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$obfs"; fi
  printf 'masquerade:\n  type: proxy\n  proxy:\n    url: https://www.cloudflare.com/\n    rewriteHost: true\n'
} > "$config"
chmod 600 "$config"
systemctl try-restart hysteria2-server.service
