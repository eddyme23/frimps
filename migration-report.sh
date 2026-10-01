#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"

[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }

echo '===== ssh-xray-websocket v6 migration report ====='
echo
echo '[TCP listeners of interest]'
ss -ltnp 2>/dev/null | awk 'NR == 1 || /:(22|80|443|143|2082|2086|8080|8880|9443|9080|3102|3103)[[:space:]]/' || true
echo
echo '[legacy service state]'
for unit in nginx haproxy vltls vlntls xtransport websocket dropbear ssh; do
  printf '%-40s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
done
echo
echo '[existing Xray account files]'
for file in /usr/local/etc/xray/vltls.json /usr/local/etc/xray/vlntls.json; do
  [[ -e "$file" ]] && printf '%s: present\n' "$file"
done
echo
echo '[v6 staging state]'
if [[ -d "$state_dir" ]]; then
  find "$state_dir" -maxdepth 1 -type f -printf '%f\n' | sort
else
  echo 'v6 has not been bootstrapped on this host.'
fi
echo
echo '[cutover rule]'
echo 'Do not start v6 HAProxy while a legacy listener owns TCP 443.'
echo 'Do not remove legacy routes or accounts until fresh v6 clients pass tests.'
