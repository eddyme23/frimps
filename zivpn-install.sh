#!/usr/bin/env bash
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"; opts="$state_dir/service-options.env"
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
[[ -r "$opts" ]] && source "$opts"
cert="${V6_CERT_FILE:-/etc/certificates/main.crt}"; key="${V6_KEY_FILE:-/etc/certificates/main.key}"
[[ -s "$cert" && -s "$key" ]] || { echo 'set V6_CERT_FILE and V6_KEY_FILE' >&2; exit 1; }
obfs="${V6_ZIVPN_OBFS:-GuruzScript}"; initial="${V6_ZIVPN_PASSWORD:-GuruzScript}"
case "$(uname -m)" in x86_64|amd64) asset=udp-zivpn-linux-amd64;; aarch64|arm64) asset=udp-zivpn-linux-arm64;; armv7l|armv6l|arm) asset=udp-zivpn-linux-arm;; *) echo 'unsupported ZiVPN architecture' >&2; exit 1;; esac
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -fL --retry 3 -o "$tmp" "https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/$asset"
install -Dm755 "$tmp" /usr/local/bin/zivpn
install -d -m 700 /etc/zivpn
[[ -f "$state_dir/zivpn-users.json" ]] || printf '[{"password":"%s","expiresAt":"%s"}]\n' "$initial" "$(date -u -d '+365 days' +%F)" > "$state_dir/zivpn-users.json"
chmod 600 "$state_dir/zivpn-users.json"
users="$(jq -r '[.[].password] | @json' "$state_dir/zivpn-users.json")"
jq -n --arg cert "$cert" --arg key "$key" --arg obfs "$obfs" --argjson users "$users" '{listen:":5667",cert:$cert,key:$key,obfs:$obfs,auth:{mode:"passwords",config:$users}}' >/etc/zivpn/config.json
chmod 600 /etc/zivpn/config.json
cat >/etc/systemd/system/zivpn.service <<'EOF'
[Unit]
Description=frimps ZiVPN backend
After=network-online.target ssh-xray-websocket-v6-udp-routing.service
Requires=ssh-xray-websocket-v6-udp-routing.service
[Service]
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo 'ZiVPN backend configured on UDP 5667; public range 6000-19999 is managed by Frimps UDP routing.'
