#!/usr/bin/env bash
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"; opts="$state_dir/service-options.env"
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }; [[ -r "$opts" ]] && source "$opts"
ns="${V6_SLOWDNS_NS:-}"; [[ "$ns" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'configure a SlowDNS nameserver first' >&2; exit 1; }
install -d -m 700 /etc/slowdns
cat >/etc/slowdns/server.key <<'EOF'
819d82813183e4be3ca1ad74387e47c0c993b81c601b2d1473a3f47731c404ae
EOF
chmod 600 /etc/slowdns/server.key
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
url='https://raw.githubusercontent.com/fisabiliyusri/SLDNS/b667b0d15be0589cd89cd2f997873296ceb07ce2/slowdns/sldns-server'
hash='ffb4d459fe9a028f7ff4b49c4c88f2f3c5f1f78ac964fb8ca57e2dfaeb457add'
curl -fL --retry 3 -o "$tmp" "$url"; printf '%s  %s\n' "$hash" "$tmp" | sha256sum -c -
install -m 700 "$tmp" /etc/slowdns/sldns-server
cat >/etc/systemd/system/frimps-slowdns.service <<EOF
[Unit]
Description=frimps SlowDNS to Dropbear bridge
After=network-online.target ssh-xray-websocket-v6-dropbear.service ssh-xray-websocket-v6-udp-routing.service
Requires=ssh-xray-websocket-v6-dropbear.service ssh-xray-websocket-v6-udp-routing.service
[Service]
ExecStart=/etc/slowdns/sldns-server -udp :53 -privkey-file /etc/slowdns/server.key $ns 127.0.0.1:143
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo 'SlowDNS configured on UDP 53 to Dropbear TCP 143.'
