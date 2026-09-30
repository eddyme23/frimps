#!/usr/bin/env bash
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
die(){ echo "v6 Hysteria 2: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'
command -v hysteria >/dev/null || die 'install the verified official hysteria binary first'
command -v jq >/dev/null || die 'install jq'
[[ -r "$state_dir/runtime.env" ]] && source "$state_dir/runtime.env"
cert_file="${V6_CERT_FILE:-${V6_STORED_CERT_FILE:-/etc/certificates/main.crt}}"
key_file="${V6_KEY_FILE:-${V6_STORED_KEY_FILE:-/etc/certificates/main.key}}"
[[ -s "$cert_file" && -s "$key_file" ]] || die 'saved certificate paths are missing; run install-v6.sh with V6_CERT_FILE and V6_KEY_FILE'
install -d -m 700 "$state_dir" /etc/hysteria2 /etc/hysteria2/clients
[[ -f "$state_dir/hysteria2-users.json" ]] || printf '[]\n' > "$state_dir/hysteria2-users.json"
chmod 600 "$state_dir/hysteria2-users.json"
install -m 700 "$(dirname "$0")/hysteria2-render.sh" /usr/local/libexec/ssh-xray-websocket-v6-hysteria2-render
cat > /etc/systemd/system/hysteria2-server.service <<'EOF'
[Unit]
Description=frimps Hysteria 2 server
After=network-online.target
[Service]
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria2/config.yaml
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
/usr/local/libexec/ssh-xray-websocket-v6-hysteria2-render
echo 'Hysteria 2 UDP 443 is configured but not enabled.'
