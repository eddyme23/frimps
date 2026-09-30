#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output="${V6_PAYLOADGATE_OUTPUT:-/usr/local/libexec/ssh-xray-websocket-v6-payloadgate}"
[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
command -v go >/dev/null 2>&1 || { echo "Go is required to build the payload gateway." >&2; exit 1; }
install -d -m 755 "$(dirname "$output")"
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$output" "$script_dir/payloadgate/main.go"
chmod 755 "$output"
echo "Built $output"
