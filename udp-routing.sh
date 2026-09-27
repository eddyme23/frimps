#!/usr/bin/env bash
# Managed UDP ingress policy for the non-Xray v6 services.
# This deliberately uses iptables because the legacy deployment already uses it.
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
chain="V6_UDP_INGRESS"
action="${1:-apply}"
public_if="${V6_PUBLIC_INTERFACE:-}"

die() { echo "v6 UDP routing: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die 'run as root'
command -v iptables >/dev/null 2>&1 || die 'iptables is required'

if [[ -z "$public_if" ]]; then
  public_if="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
fi
[[ -n "$public_if" ]] || die 'could not determine public interface; set V6_PUBLIC_INTERFACE'

add() { iptables -t nat -C "$@" 2>/dev/null || iptables -t nat -A "$@"; }
remove_jump() { while iptables -t nat -C PREROUTING -i "$public_if" -p udp -j "$chain" 2>/dev/null; do iptables -t nat -D PREROUTING -i "$public_if" -p udp -j "$chain"; done; }

apply() {
  # A separate chain gives this project one predictable ordering point and never
  # rewrites unrelated firewall rules.
  iptables -t nat -N "$chain" 2>/dev/null || true
  iptables -t nat -F "$chain"
  remove_jump
  iptables -t nat -I PREROUTING 1 -i "$public_if" -p udp -j "$chain"

  # Direct listeners: RETURN means packets keep their original destination.
  add "$chain" --dport 53 -j RETURN
  add "$chain" --dport 5300 -j RETURN
  add "$chain" --dport 443 -j RETURN
  add "$chain" --dport 1194 -j RETURN
  add "$chain" --dport 4000 -j RETURN
  add "$chain" --dport 6000:19999 -j DNAT --to-destination :5667
  add "$chain" --dport 20000:50000 -j DNAT --to-destination :36712

  # UDP Custom is strictly the complement of the dedicated routes above.
  for range in 1:52 54:442 444:1193 1195:3999 4001:5299 5301:5999 50001:65535; do
    add "$chain" --dport "$range" -j DNAT --to-destination :36717
  done
  install -d -m 700 "$state_dir"
  printf 'interface=%s\nchain=%s\n' "$public_if" "$chain" > "$state_dir/udp-routing.env"
  chmod 600 "$state_dir/udp-routing.env"
  echo "Applied managed UDP routing on $public_if."
}

remove() {
  remove_jump
  iptables -t nat -F "$chain" 2>/dev/null || true
  iptables -t nat -X "$chain" 2>/dev/null || true
  rm -f "$state_dir/udp-routing.env"
  echo 'Removed managed UDP routing chain.'
}

case "$action" in apply) apply ;; remove) remove ;; *) die 'usage: udp-routing.sh {apply|remove}' ;; esac
