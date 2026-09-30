#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
apt-get update && apt-get install -y curl
if ! command -v badvpn-udpgw >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64|amd64) badvpn_url='https://www.dropbox.com/s/jo6qznzwbsf1xhi/badvpn-udpgw64' ;;
    i386|i486|i586|i686) badvpn_url='https://www.dropbox.com/s/8gemt9c6k1fph26/badvpn-udpgw' ;;
    *) echo 'GF-compatible BadVPN binary is unavailable for this architecture' >&2; exit 1 ;;
  esac
  curl -fL --retry 3 -o /usr/local/bin/badvpn-udpgw "$badvpn_url"
  chmod 755 /usr/local/bin/badvpn-udpgw
fi
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
# Match the GF BadVPN profile: it is only a local UDP-Custom upstream, so a
# modest per-client limit prevents malformed traffic from consuming memory.
ExecStart=/usr/local/bin/badvpn-udpgw --loglevel none --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10
Restart=always
RestartSec=2
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
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
Restart=always
RestartSec=2
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo 'UDP Custom backend configured on UDP 36717; Frimps routes only non-reserved UDP ports to it.'
