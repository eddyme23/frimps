#!/usr/bin/env bash
# Verify service state and the listeners that make Frimps usable. This is
# intentionally read-only, except that it prints the relevant diagnostics.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }

failed=0
service_check() {
  if systemctl is-active --quiet "$1"; then printf '[ok] service %s\n' "$1"
  else printf '[fail] service %s\n' "$1" >&2; systemctl --no-pager -l status "$1" 2>&1 | tail -n 12 >&2 || true; failed=1
  fi
}
listener_check() {
  local proto="$1" port="$2"
  if { [[ "$proto" == tcp ]] && ss -H -ltn "( sport = :$port )" | grep -q .; } || { [[ "$proto" == udp ]] && ss -H -lun "( sport = :$port )" | grep -q .; }; then
    printf '[ok] %s listener %s\n' "$proto" "$port"
  else printf '[fail] %s listener %s\n' "$proto" "$port" >&2; failed=1
  fi
}
config_check() {
  if "$@"; then printf '[ok] %s\n' "$*"
  else printf '[fail] %s\n' "$*" >&2; failed=1
  fi
}

for unit in \
  ssh-xray-websocket-v6-dropbear ssh-xray-websocket-v6-sshws \
  ssh-xray-websocket-v6-payloadgate ssh-xray-websocket-v6-tlsmux \
  ssh-xray-websocket-v6-xray ssh-xray-websocket-v6-udp-routing \
  ssh-xray-websocket-v6-wireguard-nat frimps-openvpn-nat \
  frimps-openvpn-udp frimps-openvpn-tcp frimps-openvpn-gateway \
  frimps-openvpn-stunnel frimps-openvpn-bshield hysteria1-server \
  hysteria2-server wg-quick@wg0 frimps-slowdns zivpn frimps-badvpn \
  frimps-udp-custom nginx haproxy; do
  service_check "$unit"
done
for port in 80 443 8080 8880 2082 2086 1194 8433 10081; do listener_check tcp "$port"; done
for port in 53 443 1194 4000 5667 36712 36717; do listener_check udp "$port"; done
config_check grep -qx 'dev tun-ovpn-tcp' /etc/openvpn/server/frimps-tcp.conf
config_check grep -qx 'server 10.8.0.0 255.255.255.0' /etc/openvpn/server/frimps-tcp.conf
config_check grep -qx 'dev tun-ovpn-udp' /etc/openvpn/server/frimps-udp.conf
config_check grep -qx 'server 10.9.0.0 255.255.255.0' /etc/openvpn/server/frimps-udp.conf
config_check grep -qx 'push "dhcp-option DNS 1.1.1.1"' /etc/openvpn/server/frimps-tcp.conf
config_check grep -qx 'push "dhcp-option DNS 1.0.0.1"' /etc/openvpn/server/frimps-tcp.conf
config_check grep -qx 'TIMEOUTclose = 0' /etc/openvpn/frimps-stunnel.conf
config_check test "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" = 1
config_check nft list table ip frimps_v6_ovpn
systemctl is-active --quiet certbot.timer && printf '[ok] service certbot.timer\n' || { printf '[fail] service certbot.timer\n' >&2; failed=1; }
[[ $failed -eq 0 ]] || exit 1
printf 'Frimps post-install verification passed.\n'
