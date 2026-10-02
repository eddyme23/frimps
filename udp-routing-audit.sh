#!/usr/bin/env bash
set -euo pipefail

[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }

echo '===== v6 UDP routing audit (read-only) ====='
echo
echo '[expected dedicated public UDP routes]'
cat <<'EOF'
53                SlowDNS
443               Hysteria 2
1194              OpenVPN
4000              WireGuard
6000-19999        ZiVPN public range
20000-50000       Hysteria 1 public range
remaining UDP     UDP Custom only after all dedicated rules
EOF
echo
echo '[UDP listeners]'
ss -lunp || true
echo
echo '[nftables rules mentioning UDP, DNAT, or redirect]'
if command -v nft >/dev/null 2>&1; then
  nft list ruleset 2>/dev/null | grep -Ei 'udp|dnat|redirect' || true
else
  echo 'nft is not installed.'
fi
echo
echo '[iptables NAT rules mentioning UDP]'
if command -v iptables-save >/dev/null 2>&1; then
  iptables-save -t nat 2>/dev/null | grep -Ei 'udp|DNAT|REDIRECT' || true
else
  echo 'iptables-save is not installed.'
fi
echo
echo '[review rule]'
echo 'The managed policy uses only complement ranges for UDP Custom:'
echo '1-52, 54-442, 444-1193, 1195-3999, 4001-5299, 5300-5999, 50001-65535.'
echo 'Dedicated direct listeners must have an earlier nat ACCEPT exception so a legacy catch-all DNAT cannot capture them.'
echo 'This audit does not alter OpenVPN, Hysteria 1, Hysteria 2, or any firewall rule.'
