#!/usr/bin/env bash
# Apply resource/restart policy as systemd drop-ins. This lets an existing VPS
# receive the policy without re-running an installer or replacing any config.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }

units='hysteria1-server.service hysteria2-server.service zivpn.service frimps-badvpn.service frimps-udp-custom.service frimps-openvpn-udp.service frimps-openvpn-tcp.service frimps-openvpn-gateway.service frimps-openvpn-bshield.service frimps-openvpn-stunnel.service'
changed=0
for unit in $units; do
  systemctl cat "$unit" >/dev/null 2>&1 || continue
  dropin="/etc/systemd/system/$unit.d/frimps-resilience.conf"
  install -d -m 755 "$(dirname "$dropin")"
  cat >"$dropin" <<'EOF'
[Service]
RestartSec=2
LimitNOFILE=1048576
EOF
  changed=1
done

if (( changed )); then
  systemctl daemon-reload
  echo 'Applied Frimps service restart and file-descriptor limits.'
else
  echo 'No optional Frimps service units are installed yet.'
fi
