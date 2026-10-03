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
command -v iptables >/dev/null 2>&1 || command -v nft >/dev/null 2>&1 || die 'install iptables or nftables'

sync_routes_metadata() {
  local routes="$state_dir/routes.json" tmp
  [[ -s "$routes" ]] && command -v jq >/dev/null 2>&1 || return 0
  tmp="$(mktemp "$state_dir/.routes.json.XXXXXX")"
  jq '.udpCustomRanges = ["1-52", "54-442", "444-1193", "1195-3999", "4001-5299", "5300-5999", "50001-65535"]' "$routes" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$routes"
}

if [[ -z "$public_if" ]]; then
  public_if="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
fi
[[ -n "$public_if" ]] || die 'could not determine public interface; set V6_PUBLIC_INTERFACE'

nft_apply() {
  # Native nftables policy. The table is dedicated to v6 and is recreated
  # atomically, so unrelated firewall state is never rewritten.
  nft delete table ip frimps_v6_udp 2>/dev/null || true
  nft -f - <<EOF
table ip frimps_v6_udp {
 chain prerouting {
  type nat hook prerouting priority dstnat; policy accept;
  iifname "$public_if" udp dport { 53, 443, 1194, 4000 } accept
  iifname "$public_if" udp dport 6000-19999 dnat to :5667
  iifname "$public_if" udp dport 20000-50000 dnat to :36712
  iifname "$public_if" udp dport 1-52 dnat to :36717
  iifname "$public_if" udp dport 54-442 dnat to :36717
  iifname "$public_if" udp dport 444-1193 dnat to :36717
  iifname "$public_if" udp dport 1195-3999 dnat to :36717
  iifname "$public_if" udp dport 4001-5299 dnat to :36717
  iifname "$public_if" udp dport 5300-5999 dnat to :36717
  iifname "$public_if" udp dport 50001-65535 dnat to :36717
 }
}
EOF
  install -d -m 700 "$state_dir"
  printf 'interface=%s\nbackend=nftables\n' "$public_if" > "$state_dir/udp-routing.env"
  chmod 600 "$state_dir/udp-routing.env"
  sync_routes_metadata
  echo "Applied managed nftables UDP routing on $public_if."
}
add() { iptables -t nat -C "$@" 2>/dev/null || iptables -t nat -A "$@"; }
remove_jump() { while iptables -t nat -C PREROUTING -i "$public_if" -p udp -j "$chain" 2>/dev/null; do iptables -t nat -D PREROUTING -i "$public_if" -p udp -j "$chain"; done; }

apply() {
  if command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then nft_apply; return; fi
  # A separate chain gives this project one predictable ordering point and never
  # rewrites unrelated firewall rules.
  iptables -t nat -N "$chain" 2>/dev/null || true
  iptables -t nat -F "$chain"
  remove_jump
  iptables -t nat -I PREROUTING 1 -i "$public_if" -p udp -j "$chain"

  # Direct listeners must ACCEPT in nat/PREROUTING, not RETURN: a RETURN would
  # continue into a legacy catch-all DNAT rule after this chain.
  add "$chain" -p udp --dport 53 -j ACCEPT
  add "$chain" -p udp --dport 443 -j ACCEPT
  add "$chain" -p udp --dport 1194 -j ACCEPT
  add "$chain" -p udp --dport 4000 -j ACCEPT
  add "$chain" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
  add "$chain" -p udp --dport 20000:50000 -j DNAT --to-destination :36712

  # UDP Custom is strictly the complement of the dedicated routes above.
  for range in 1:52 54:442 444:1193 1195:3999 4001:5299 5300:5999 50001:65535; do
    add "$chain" -p udp --dport "$range" -j DNAT --to-destination :36717
  done
  install -d -m 700 "$state_dir"
  printf 'interface=%s\nchain=%s\n' "$public_if" "$chain" > "$state_dir/udp-routing.env"
  chmod 600 "$state_dir/udp-routing.env"
  sync_routes_metadata
  echo "Applied managed UDP routing on $public_if."
}

remove() {
  if command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then nft delete table ip frimps_v6_udp 2>/dev/null || true; rm -f "$state_dir/udp-routing.env"; echo 'Removed managed nftables UDP table.'; return; fi
  remove_jump
  iptables -t nat -F "$chain" 2>/dev/null || true
  iptables -t nat -X "$chain" 2>/dev/null || true
  rm -f "$state_dir/udp-routing.env"
  echo 'Removed managed UDP routing chain.'
}

case "$action" in apply) apply ;; remove) remove ;; *) die 'usage: udp-routing.sh {apply|remove}' ;; esac
