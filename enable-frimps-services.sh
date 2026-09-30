#!/usr/bin/env bash
# Enable every Frimps-managed unit that is installed on this VPS.  Existing
# running units are left running; inactive installed units are started.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
units='ssh-xray-websocket-v6-dropbear ssh-xray-websocket-v6-sshws ssh-xray-websocket-v6-payloadgate ssh-xray-websocket-v6-tlsmux ssh-xray-websocket-v6-xray ssh-xray-websocket-v6-gfraw ssh-xray-websocket-v6-udp-routing ssh-xray-websocket-v6-wireguard-nat frimps-openvpn-nat frimps-openvpn-udp frimps-openvpn-tcp frimps-openvpn-gateway frimps-openvpn-stunnel frimps-openvpn-bshield hysteria1-server hysteria2-server wg-quick@wg0 frimps-slowdns zivpn frimps-badvpn frimps-udp-custom nginx haproxy'
for unit in $units; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    systemctl enable --now "$unit" || printf 'Could not enable/start: %s\n' "$unit" >&2
  fi
done
echo 'Installed Frimps services are enabled for boot.'
