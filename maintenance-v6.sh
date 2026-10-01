#!/usr/bin/env bash
# GF-inspired operational helpers.  Each mutation is explicit; this script
# never overwrites service configuration or restores a backup automatically.
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "Frimps maintenance: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'

monitor() {
  echo '═══ ACTIVE FRIMPS CONNECTIONS ═══'
  echo
  ss -Hntup 2>/dev/null | awk '$5 !~ /127\.0\.0\.1|\[::1\]/ {print}' || true
  echo
  echo 'WireGuard peers:'
  wg show 2>/dev/null || echo 'WireGuard is not installed or active.'
}
restart() {
  case "${1:-}" in
    ssh) units='ssh-xray-websocket-v6-dropbear ssh-xray-websocket-v6-sshws ssh-xray-websocket-v6-payloadgate ssh-xray-websocket-v6-tlsmux ssh-xray-websocket-v6-gfraw' ;;
    xray) units='ssh-xray-websocket-v6-xray nginx haproxy' ;;
    udp) units='ssh-xray-websocket-v6-udp-routing frimps-slowdns hysteria1-server hysteria2-server zivpn frimps-badvpn frimps-udp-custom' ;;
    openvpn) units='frimps-openvpn-nat frimps-openvpn-udp frimps-openvpn-tcp frimps-openvpn-gateway frimps-openvpn-stunnel frimps-openvpn-bshield' ;;
    wireguard) units='ssh-xray-websocket-v6-wireguard-nat wg-quick@wg0' ;;
    all) units='ssh-xray-websocket-v6-dropbear ssh-xray-websocket-v6-sshws ssh-xray-websocket-v6-payloadgate ssh-xray-websocket-v6-tlsmux ssh-xray-websocket-v6-gfraw ssh-xray-websocket-v6-xray ssh-xray-websocket-v6-udp-routing ssh-xray-websocket-v6-wireguard-nat frimps-slowdns hysteria1-server hysteria2-server zivpn frimps-badvpn frimps-udp-custom frimps-openvpn-nat frimps-openvpn-udp frimps-openvpn-tcp frimps-openvpn-gateway frimps-openvpn-stunnel frimps-openvpn-bshield wg-quick@wg0 nginx haproxy' ;;
    *) die 'usage: maintenance-v6.sh restart {ssh|xray|udp|openvpn|wireguard|all}' ;;
  esac
  for unit in $units; do
    systemctl cat "$unit" >/dev/null 2>&1 || { printf '%-45s not installed\n' "$unit"; continue; }
    systemctl try-restart "$unit" || printf '%-45s restart failed\n' "$unit"
  done
}
backup() {
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"; out="/root/frimps-backup-$stamp.tgz"
  tar -czf "$out" --ignore-failed-read /etc/ssh-xray-websocket-v6 /etc/hysteria1 /etc/hysteria2 /etc/zivpn /etc/openvpn /etc/wireguard /etc/systemd/system 2>/dev/null
  chmod 600 "$out"; echo "Backup created: $out"
}
cleanup_json() {
  local file="$1" key="$2" script="$3" today value
  [[ -f "$file" ]] || return 0
  today="$(date -u +%F)"
  while IFS= read -r value; do
    [[ -n "$value" ]] && bash "$script_dir/$script" delete "$value"
  done < <(jq -r --arg today "$today" ".[] | select(.expiresAt < \$today) | .$key" "$file")
}
cleanup() {
  bash "$script_dir/ssh-accounts.sh" cleanup || true
  bash "$script_dir/accounts.sh" vless cleanup || true
  bash "$script_dir/accounts.sh" trojan cleanup || true
  bash "$script_dir/wireguard-accounts.sh" cleanup || true
  cleanup_json "$state_dir/hysteria1-users.json" name hysteria1-accounts.sh
  cleanup_json "$state_dir/hysteria2-users.json" name hysteria2-accounts.sh
  cleanup_json "$state_dir/zivpn-users.json" password zivpn-accounts.sh
  cleanup_json "$state_dir/openvpn-users.json" name openvpn-accounts.sh
  echo 'Expired Frimps-managed accounts were cleaned where configured.'
}
logs() {
  local unit item
  local -a journal_units=()
  case "${1:-}" in
    ssh) unit='ssh-xray-websocket-v6-sshws.service' ;;
    xray) unit='ssh-xray-websocket-v6-xray.service' ;;
    openvpn) unit='frimps-openvpn-gateway.service frimps-openvpn-stunnel.service frimps-openvpn-bshield.service' ;;
    hysteria1) unit='hysteria1-server.service' ;;
    hysteria2) unit='hysteria2-server.service' ;;
    wireguard) unit='wg-quick@wg0.service' ;;
    zivpn) unit='zivpn.service' ;;
    slowdns) unit='frimps-slowdns.service' ;;
    udpcustom) unit='frimps-udp-custom.service frimps-badvpn.service' ;;
    *) die 'usage: maintenance-v6.sh logs {ssh|xray|openvpn|hysteria1|hysteria2|wireguard|zivpn|slowdns|udpcustom}' ;;
  esac
  for item in $unit; do journal_units+=(-u "$item"); done
  journalctl --no-pager -n 100 "${journal_units[@]}"
}
case "${1:-}" in
  monitor) monitor ;;
  restart) restart "${2:-}" ;;
  backup) backup ;;
  cleanup) cleanup ;;
  logs) logs "${2:-}" ;;
  *) die 'usage: maintenance-v6.sh {monitor|restart GROUP|backup|cleanup|logs GROUP}' ;;
esac
