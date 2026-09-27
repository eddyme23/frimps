#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
routes="$state_dir/routes.json"
keys="$state_dir/vless-encryption.env"
backends="$state_dir/xray-backends.json"
backend_map="$state_dir/backends.json"
routing_haproxy="$state_dir/haproxy-443.cfg"
routing_nginx="$state_dir/nginx-main-tls.conf"
ntls_nginx="$state_dir/nginx-encrypted-ntls.conf"
ssh_only_nginx="$state_dir/nginx-ssh-only.conf"
tlsmux_unit="$state_dir/tlsmux.service"
payloadgate_unit="$state_dir/payloadgate.service"
reality_client_info="$state_dir/reality-client-info.json"

fail=0
check() {
  if "$@"; then
    printf '[ok] %s\n' "$*"
  else
    printf '[fail] %s\n' "$*" >&2
    fail=1
  fi
}

check test -s "$routes"
check test -s "$keys"
check jq -e '.removedProtocols | index("vmess") != null' "$routes"
check jq -e '.trojan.path == "/trojan" and (.legacyTrojanPaths | length == 0)' "$routes"
check jq -e '.vless.encryptedNtls | index("ws") != null' "$routes"
check jq -e '.udpPriority == ["slowdns", "hysteria2", "openvpn", "wireguard", "zivpn", "hysteria1", "udp-custom"]' "$routes"
check jq -e '.udpCustomRanges == ["1-52", "54-442", "444-1193", "1195-3999", "4001-5299", "5301-5999", "50001-65535"]' "$routes"
domain="$(jq -r '.primaryDomain' "$routes")"

if [[ -s "$keys" ]]; then
  # shellcheck disable=SC1090
  source "$keys"
  [[ "${VLESS_NTLS_DECRYPTION:-}" == mlkem768x25519plus.* ]] || fail=1
  [[ "${VLESS_NTLS_ENCRYPTION:-}" == mlkem768x25519plus.* ]] || fail=1
fi

if [[ -e "$reality_client_info" ]]; then
  check jq -e '.publicKey != "" and .shortId != "" and .serverName != ""' "$reality_client_info"
  check test -s "$state_dir/reality.env"
  if [[ -e "$backends" ]]; then
    check jq -e '[.inbounds[].tag] | index("vless-reality-vision") != null' "$backends"
  fi
fi

if [[ -e "$routing_haproxy" || -e "$routing_nginx" ]]; then
  check test -s "$routing_haproxy"
  check test -s "$routing_nginx"
  check test -s "$ntls_nginx"
  check test -s "$ssh_only_nginx"
  check grep -q 'bind :443' "$routing_haproxy"
  check grep -q 'location = /trojan' "$routing_nginx"
  check grep -q 'location = /trntls { return 410; }' "$routing_nginx"
  check grep -q 'bind :80' "$routing_haproxy"
  check grep -q 'bind :8080' "$routing_haproxy"
  check grep -q 'bind :8880' "$routing_haproxy"
  check grep -q 'bind :2082' "$routing_haproxy"
  check grep -q 'bind :2086' "$routing_haproxy"
  check grep -q 'default_backend ssh_payload_gateway' "$routing_haproxy"
  check test -s "$tlsmux_unit"
  check test -s "$payloadgate_unit"
  check grep -q -- '-ssh-target 127.0.0.1:143' "$tlsmux_unit"
  check grep -q -- '-ws-target 127.0.0.1:3103' "$payloadgate_unit"
fi

if [[ -e "$backends" || -e "$backend_map" ]]; then
  check test -s "$backends"
  check test -s "$backend_map"
  check jq -e '[.inbounds[].tag] | index("trojan-ws-tls") != null and index("vless-ws-encrypted-ntls") != null' "$backends"
  check jq -e '[.inbounds[].tag] | index("vless-tls-vision") != null' "$backends"
  check jq -e '.forbiddenPaths == ["/trtls", "/trntls"]' "$backend_map"
fi

if [[ "$fail" -ne 0 ]]; then
  echo 'v6 validation failed.' >&2
  exit 1
fi

echo 'v6 foundation validation passed.'
