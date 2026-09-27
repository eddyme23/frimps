#!/usr/bin/env bash
set -euo pipefail
[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
systemctl stop ssh-xray-websocket-v6-payloadgate ssh-xray-websocket-v6-tlsmux ssh-xray-websocket-v6-xray
echo 'v6 loopback backends stopped.'
