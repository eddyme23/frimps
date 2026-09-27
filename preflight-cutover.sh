#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"

[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -s "$state_dir/STAGED.md" ]] || { echo "v6 has not been staged." >&2; exit 1; }

owners="$(ss -ltnp '( sport = :443 )' 2>/dev/null || true)"
if [[ -n "$owners" ]]; then
  echo "TCP 443 is currently owned. A reviewed migration plan is required before cutover:" >&2
  echo "$owners" >&2
  exit 2
fi

echo "No TCP 443 owner detected. This only confirms cutover eligibility; it does not start services."
