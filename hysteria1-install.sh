#!/usr/bin/env bash
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
die(){ echo "v6 Hysteria 1: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'
command -v sing-box >/dev/null || die 'install a QUIC-capable sing-box binary first'
command -v jq >/dev/null || die 'install jq'
[[ -s "${V6_CERT_FILE:-/etc/certificates/main.crt}" && -s "${V6_KEY_FILE:-/etc/certificates/main.key}" ]] || die 'set V6_CERT_FILE and V6_KEY_FILE'
sing_box_bin="$(command -v sing-box)"
install -d -m 700 "$state_dir" /etc/hysteria1 /etc/hysteria1/clients
[[ -f "$state_dir/hysteria1-users.json" ]] || printf '[]\n' > "$state_dir/hysteria1-users.json"
chmod 600 "$state_dir/hysteria1-users.json"
# Keep an explicit, durable per-client server ceiling.  Do not overwrite an
# administrator's existing speed choice during a reconfigure or update.
if [[ ! -s "$state_dir/hysteria1-speeds.env" ]]; then
  printf 'V6_HYSTERIA1_UP_MBPS=1000\nV6_HYSTERIA1_DOWN_MBPS=1000\n' > "$state_dir/hysteria1-speeds.env"
  chmod 600 "$state_dir/hysteria1-speeds.env"
fi
install -m 700 "$(dirname "$0")/hysteria1-render.sh" /usr/local/libexec/ssh-xray-websocket-v6-hysteria1-render
cat > /etc/systemd/system/hysteria1-server.service <<EOF
[Unit]
Description=frimps Hysteria 1 sing-box backend
After=network-online.target ssh-xray-websocket-v6-udp-routing.service
Requires=ssh-xray-websocket-v6-udp-routing.service
[Service]
ExecStart=$sing_box_bin run -c /etc/hysteria1/config.json
Restart=on-failure
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
/usr/local/libexec/ssh-xray-websocket-v6-hysteria1-render
echo 'Hysteria 1 backend UDP 36712 is configured, but not enabled.'
