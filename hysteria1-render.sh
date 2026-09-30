#!/usr/bin/env bash
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
store="$state_dir/hysteria1-users.json"
config=/etc/hysteria1/config.json
cert_file="${V6_CERT_FILE:-/etc/certificates/main.crt}"
key_file="${V6_KEY_FILE:-/etc/certificates/main.key}"
[[ -r "$state_dir/service-options.env" ]] && source "$state_dir/service-options.env"
obfs="${V6_HYSTERIA1_OBFS:-frEddxx}"
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
users="$(jq '[.[] | {name:.name, auth_str:.password}]' "$store")"
jq -n --arg cert "$cert_file" --arg key "$key_file" --arg obfs "$obfs" --argjson users "$users" '{log:{level:"info"},inbounds:[{type:"hysteria",tag:"hysteria1-in",listen:"0.0.0.0",listen_port:36712,up_mbps:100,down_mbps:100,obfs:$obfs,users:$users,tls:{enabled:true,certificate_path:$cert,key_path:$key}}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' > "$config"
chmod 600 "$config"
sing-box check -c "$config"
systemctl try-restart hysteria1-server.service
