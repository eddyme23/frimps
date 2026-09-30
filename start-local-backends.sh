#!/usr/bin/env bash
set -euo pipefail

ports=(143 3102 3103 3104 3106 3107 3108 3112 3113 3114 3115 3116 3117 8443 8444 9443)
units=(ssh-xray-websocket-v6-dropbear ssh-xray-websocket-v6-gfraw ssh-xray-websocket-v6-sshws ssh-xray-websocket-v6-xray ssh-xray-websocket-v6-tlsmux ssh-xray-websocket-v6-payloadgate)

[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
for unit in "${units[@]}"; do systemctl cat "$unit" >/dev/null 2>&1 || { echo "Missing staged unit: $unit" >&2; exit 1; }; done

for port in "${ports[@]}"; do
  if ss -ltn "( sport = :$port )" | tail -n +2 | grep -q .; then
    echo "Refusing to start: TCP $port is already in use." >&2
    exit 2
  fi
done

systemctl start ssh-xray-websocket-v6-dropbear
systemctl start ssh-xray-websocket-v6-gfraw
systemctl start ssh-xray-websocket-v6-sshws
systemctl start ssh-xray-websocket-v6-xray
systemctl start ssh-xray-websocket-v6-tlsmux
systemctl start ssh-xray-websocket-v6-payloadgate

for unit in "${units[@]}"; do
  systemctl is-active --quiet "$unit" || { echo "Failed unit: $unit" >&2; exit 3; }
done
echo 'v6 loopback backends are active. No public TCP listener was started.'
