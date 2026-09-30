#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
action="${1:-status}"

bbr_status() {
  printf 'Kernel: %s\n' "$(uname -r)"
  printf 'Available congestion controls: %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unavailable)"
  printf 'Active congestion control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable)"
  printf 'Default qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)"
}

enable_bbr() {
  modprobe tcp_bbr 2>/dev/null || true
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || { echo 'This kernel does not provide BBR.' >&2; exit 1; }
  install -d -m 755 /etc/sysctl.d
  cat >/etc/sysctl.d/99-frimps-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || { echo 'BBR was not activated.' >&2; exit 1; }
  echo 'BBR is enabled and will persist after reboot: /etc/sysctl.d/99-frimps-bbr.conf'
  bbr_status
}

netflix_check() {
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  curl -fsSL --retry 3 -o "$tmp" 'https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh'
  echo "Downloaded RegionRestrictionCheck SHA-256: $(sha256sum "$tmp" | awk '{print $1}')"
  bash "$tmp" -E en
}

case "$action" in
  status) bbr_status ;;
  enable-bbr) enable_bbr ;;
  netflix) netflix_check ;;
  *) echo 'usage: utilities-v6.sh {status|enable-bbr|netflix}' >&2; exit 2 ;;
esac
