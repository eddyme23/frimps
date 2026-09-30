#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
apt-get update && apt-get install -y badvpn curl
install -d -m 700 /etc/frimps-udp-custom
curl -fL --retry 3 -o /etc/frimps-udp-custom/udp-custom 'https://raw.githubusercontent.com/mahpud896/UDP-Custom/d7bb82abb6b36f1320bc349f36c0746b335a9ff9/bin/udp-custom-linux-amd64'
chmod 700 /etc/frimps-udp-custom/udp-custom
curl -fL --retry 3 -o /etc/frimps-udp-custom/config.json 'https://raw.githubusercontent.com/mahpud896/UDP-Custom/d7bb82abb6b36f1320bc349f36c0746b335a9ff9/config/config.json'
sed -i 's/":36712"/":36717"/' /etc/frimps-udp-custom/config.json
cat >/etc/systemd/system/frimps-badvpn.service <<'EOF'
[Unit]
Description=frimps BadVPN UDP gateway
After=network-online.target
[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 1000
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/frimps-udp-custom.service <<'EOF'
[Unit]
Description=frimps UDP Custom backend
After=network-online.target ssh-xray-websocket-v6-udp-routing.service frimps-badvpn.service
Requires=ssh-xray-websocket-v6-udp-routing.service
[Service]
ExecStart=/etc/frimps-udp-custom/udp-custom server -c /etc/frimps-udp-custom/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo 'UDP Custom backend configured on UDP 36717; Frimps routes only non-reserved UDP ports to it.'
